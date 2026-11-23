#!/usr/bin/env bash
# ==============================================================================
# aic8800-kinoite.sh - AIC8800D80 Wi-Fi and Bluetooth on Fedora Kinoite, via akmods.
#
# Layered on the system: the firmware package and a source-only akmod package
# (no scripts). akmods builds and signs the kernel module on the host for each
# kernel; a boot service applies the built kmod with rpm-ostree.
#
# Signing key: your key is imported into ~/.aic8800-keys/db (KEY_DIR, once) and
# installed into /etc/pki/akmods, where akmods and the build read it.
#
# Usage: bash aic8800-kinoite.sh {all|keys|build|install|status|remove}
# Environment: KEY_DIR, REPO, BRANCH, COMMIT, AIC_NO_REBOOT, TB
# ==============================================================================
set -euo pipefail

# Driver source. Defaults to the fork, branch main, at the current branch head.
# Pin a commit with COMMIT=<hash>. Use BRANCH=legacy-mcu1 when chip_mcu_id=1.
REPO="${REPO:-codebyallan/aic8800d80}"
BRANCH="${BRANCH:-main}"
COMMIT="${COMMIT:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC_KMOD="$SCRIPT_DIR/aic8800d80-kmod.spec"
SPEC_SRC="$SCRIPT_DIR/akmod-aic8800d80.spec"
SPEC_FW="$SCRIPT_DIR/aic8800d80-firmware.spec"
RPMBUILD="$HOME/rpmbuild"
TB="${TB:-aic8800-build}"
KEY_DB="$HOME/.aic8800-keys/db"

AKMODS_DIR=/etc/pki/akmods
AKMODS_CERT="$AKMODS_DIR/certs/public_key.der"
AKMODS_PRIV="$AKMODS_DIR/private/private_key.priv"

SYNC_BIN=/usr/local/sbin/aic8800-kmod-sync
SYNC_UNIT=aic8800-kmod-sync.service
RELOAD_BIN=/usr/local/sbin/aic8800-reload
RELOAD_UNIT=aic8800-reload.service
RELOAD_RULE=/etc/udev/rules.d/98-aic8800-reload.rules
RELOAD_STAMP=/run/aic8800-reload.stamp

# Packages from earlier versions of this project. Removed on install.
OLD_PKGS=(aic8800d80 akmod-aic8800 aic8800-kmod-common akmods-keys-local akmod-aic8800d80-src)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run as a regular user, not with sudo."

# Print the newest file in a directory that matches a pattern.
latest_file() {
  find "$1" -maxdepth 1 -name "$2" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-
}

# ------------------------------------------------------------------------------
# Keys
# ------------------------------------------------------------------------------

do_keys() {
  local src="${KEY_DIR:-}"

  if [ -n "$src" ] && [ -r "$src/db.key" ] && [ -r "$src/db.pem" ]; then
    say "Importing keys from $src into $KEY_DB"
    mkdir -p "$KEY_DB"
    chmod 700 "$HOME/.aic8800-keys" "$KEY_DB"
    cp -f "$src/db.key" "$src/db.pem" "$KEY_DB/"
    chmod 600 "$KEY_DB/db.key"
    chmod 644 "$KEY_DB/db.pem"
    say "Keys imported. The source folder was not changed; remove it yourself after backing it up."
  elif [ -r "$KEY_DB/db.key" ] && [ -r "$KEY_DB/db.pem" ]; then
    say "Using existing keys in $KEY_DB"
  else
    say "No key found. Generating a new key pair in $KEY_DB."
    mkdir -p "$KEY_DB"
    chmod 700 "$HOME/.aic8800-keys" "$KEY_DB"
    openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
      -subj "/CN=AIC8800 local module signing/" \
      -keyout "$KEY_DB/db.key" -out "$KEY_DB/db.pem" >/dev/null 2>&1
    chmod 600 "$KEY_DB/db.key"
  fi

  openssl x509 -in "$KEY_DB/db.pem" -outform DER -out "$KEY_DB/db.der"
  chmod 644 "$KEY_DB/db.der"

  # akmods and the build read the key from /etc/pki/akmods. Install it there.
  getent group akmods >/dev/null \
    || die "The 'akmods' group does not exist. Make sure the akmods package is layered."
  sudo systemctl mask akmods-keygen@akmods.service >/dev/null 2>&1 || true
  sudo install -d -m 0755 -o root -g root "$AKMODS_DIR" "$AKMODS_DIR/certs"
  sudo install -d -m 0750 -o root -g akmods "$AKMODS_DIR/private"
  sudo install -m 0644 -o root -g root "$KEY_DB/db.der" "$AKMODS_CERT"
  sudo install -m 0640 -o root -g akmods "$KEY_DB/db.key" "$AKMODS_PRIV"
  say "Key installed in $AKMODS_DIR (private key: root:akmods, mode 0640)."

  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    if sudo mokutil --test-key "$AKMODS_CERT" 2>&1 | grep -q 'is not enrolled'; then
      say "The key is not enrolled in UEFI. Choose a one-time password now; you will enter it on the blue MOK screen at next boot."
      sudo mokutil --import "$AKMODS_CERT"
      warn "Reboot and choose 'Enroll MOK' on the blue screen."
    else
      say "Key is already enrolled in UEFI."
    fi
  else
    say "Secure Boot is disabled: signing is not required, but modules are still signed."
  fi
}

# ------------------------------------------------------------------------------
# Build: source tarball, SRPM for akmods, source package, firmware package
# ------------------------------------------------------------------------------

do_build() {
  command -v toolbox >/dev/null || die "toolbox not found (it ships with Kinoite)."
  local s
  for s in "$SPEC_KMOD" "$SPEC_SRC" "$SPEC_FW"; do
    [ -r "$s" ] || die "Spec file not found: $s"
  done

  if [ -z "$COMMIT" ]; then
    command -v git >/dev/null || die "git not found (it ships with Kinoite)."
    COMMIT="$(git ls-remote "https://github.com/$REPO" "refs/heads/$BRANCH" | cut -f1)"
    [ -n "$COMMIT" ] || die "Branch '$BRANCH' not found in $REPO."
  fi
  say "Source: $REPO @ ${COMMIT:0:7} (branch $BRANCH)"

  mkdir -p "$RPMBUILD"/{SOURCES,SPECS,RPMS,SRPMS,BUILD,BUILDROOT}

  # Point the specs at the chosen repository and commit. The firmware snapdate
  # includes the time, so each build is a newer package version.
  local snap; snap="$(date +%Y%m%d%H%M)"
  sed -e "s|^%global commit .*|%global commit $COMMIT|" \
      -e "s|shenmintao/aic8800d80|$REPO|" \
      "$SPEC_KMOD" > "$RPMBUILD/SPECS/aic8800d80-kmod.spec"
  sed -e "s|shenmintao/aic8800d80|$REPO|" \
      "$SPEC_SRC" > "$RPMBUILD/SPECS/akmod-aic8800d80.spec"
  sed -e "s|^%global commit .*|%global commit $COMMIT|" \
      -e "s|^%global snapdate .*|%global snapdate $snap|" \
      -e "s|shenmintao/aic8800d80|$REPO|" \
      "$SPEC_FW" > "$RPMBUILD/SPECS/aic8800d80-firmware.spec"

  local tarball="$RPMBUILD/SOURCES/aic8800d80-$COMMIT.tar.gz"
  if [ ! -s "$tarball" ]; then
    say "Downloading source ${COMMIT:0:7} (internet access required)..."
    curl -fL --retry 3 -o "$tarball" \
      "https://github.com/$REPO/archive/$COMMIT/aic8800d80-$COMMIT.tar.gz" \
      || die "Download failed. Check your network connection."
  fi

  cat > "$RPMBUILD/build-in-toolbox.sh" <<'INTB'
#!/usr/bin/env bash
set -euo pipefail
RPMBUILD="$1"
sudo dnf install -y rpm-build rpmdevtools kmodtool
# SRPM of the kmod spec, which akmods builds on the host.
rpmbuild -bs "$RPMBUILD/SPECS/aic8800d80-kmod.spec"
cp -f "$(ls -t "$RPMBUILD"/SRPMS/aic8800d80-kmod-*.src.rpm | head -1)" \
      "$RPMBUILD/SOURCES/aic8800d80-kmod.src.rpm"
# Source-only package that ships the SRPM to /usr/src/akmods.
rpmbuild -bb "$RPMBUILD/SPECS/akmod-aic8800d80.spec"
# Firmware, udev rules and usb_modeswitch.
rpmbuild -bb "$RPMBUILD/SPECS/aic8800d80-firmware.spec"
INTB

  say "Packaging inside toolbox '$TB'..."
  if ! podman container exists "$TB" 2>/dev/null; then
    toolbox create --container "$TB"
  fi
  toolbox run --container "$TB" bash "$RPMBUILD/build-in-toolbox.sh" "$RPMBUILD"
  say "Packages written to $RPMBUILD/RPMS/"
}

# ------------------------------------------------------------------------------
# Install: layer the packages, write the boot service and the hot-plug helper
# ------------------------------------------------------------------------------

write_services() {
  say "Installing the kmod apply service and the hot-plug helper..."

  # Runs as root at boot and from the hot-plug helper. If the kmod for the running
  # kernel is missing, akmods builds and signs it on the host, and rpm-ostree applies it.
  sudo tee "$SYNC_BIN" >/dev/null <<'SYNC'
#!/usr/bin/env bash
# Runs as root. Ensures the aic8800d80 kmod for the running kernel is installed.
set -u
kver="$(uname -r)"
say() { echo "[aic8800-kmod-sync] $*"; }

if find "/usr/lib/modules/${kver}" -name 'aic8800_fdrv.ko*' 2>/dev/null | grep -q .; then
  say "kmod already installed for ${kver}."
  lsmod | grep -q '^aic8800_fdrv' || modprobe aic8800_fdrv 2>/dev/null || true
  exit 0
fi

[ -f /usr/src/akmods/aic8800d80-kmod.src.rpm ] \
  || { say "ERROR: source RPM missing. Reinstall akmod-aic8800d80."; exit 1; }
[ -r /etc/pki/akmods/private/private_key.priv ] \
  || { say "ERROR: signing key missing from /etc/pki/akmods."; exit 1; }
[ -d "/usr/src/kernels/${kver}" ] \
  || { say "ERROR: kernel-devel-${kver} is missing from the layered packages."; exit 1; }

say "Building and signing with akmods for ${kver}..."
# akmods also tries to install the RPM with yum, which does not exist on Kinoite.
# That failure is expected: the built RPM stays in the cache and is applied below.
akmods --force --kernels "${kver}" >/dev/null 2>&1 || true

rpm_file=""
for f in $(ls -t /var/cache/akmods/aic8800d80/kmod-aic8800d80-*.rpm 2>/dev/null); do
  if rpm -qlp "$f" 2>/dev/null | grep -q "/modules/${kver}/"; then
    rpm_file="$f"
    break
  fi
done
if [ -z "$rpm_file" ]; then
  say "ERROR: no kmod built for ${kver}. See /var/cache/akmods/aic8800d80/*.failed.log"
  exit 1
fi

for _ in $(seq 1 30); do
  rpm-ostree status 2>/dev/null | grep -q 'State: busy' || break
  sleep 2
done

new_name="$(rpm -qp --qf '%{NAME}' "$rpm_file")"
uninstall_args=()
while read -r p; do
  [ -n "$p" ] && [ "$p" != "$new_name" ] && uninstall_args+=(--uninstall "$p")
done < <(rpm -qa --qf '%{NAME}\n' | grep '^kmod-aic8800d80' || true)

say "Applying $(basename "$rpm_file") with rpm-ostree..."
if rpm-ostree install --idempotent --apply-live "${uninstall_args[@]}" "$rpm_file"; then
  depmod -a "${kver}" || true
  modprobe aic8800_fdrv || true
  udevadm trigger --subsystem-match=usb --action=add || true
  say "Driver is active on ${kver}."
else
  say "apply-live is not available; the driver will activate at the next boot."
  rpm-ostree install --idempotent "${uninstall_args[@]}" "$rpm_file" || true
fi
exit 0
SYNC
  sudo chmod 755 "$SYNC_BIN"

  sudo tee "/etc/systemd/system/$SYNC_UNIT" >/dev/null <<UNIT
[Unit]
Description=AIC8800 build (akmods) and apply the kmod for the running kernel
After=akmods.service systemd-udev-settle.service
Wants=akmods.service

[Service]
Type=oneshot
ExecStart=$SYNC_BIN

[Install]
WantedBy=multi-user.target
UNIT

  # Hot-plug helper: reload the driver when the dongle is re-plugged and Wi-Fi is unusable.
  sudo tee "$RELOAD_BIN" >/dev/null <<'RELOAD'
#!/usr/bin/env bash
# Reload the AIC8800 driver after a re-plug if Wi-Fi is not usable.
set -u
STAMP=/run/aic8800-reload.stamp

# Guard: ignore events within 60 seconds of the previous run.
now="$(date +%s)"
last="$(cat "$STAMP" 2>/dev/null || echo 0)"
[ $((now - last)) -lt 60 ] && exit 0
echo "$now" > "$STAMP"

wifi_dev() { ls /sys/class/net 2>/dev/null | grep '^wl' | head -1; }
wifi_ok() {
  local dev; dev="$(wifi_dev)"
  [ -n "$dev" ] || return 1
  ip link set "$dev" up 2>/dev/null || true
  if command -v iw >/dev/null; then
    iw dev "$dev" scan 2>/dev/null | grep -q '^BSS '
  else
    return 0
  fi
}

wifi_ok && exit 0

sleep 3
rmmod aic8800_fdrv aic_load_fw 2>/dev/null || true
/usr/local/sbin/aic8800-kmod-sync || true

for _ in $(seq 1 16); do [ -n "$(wifi_dev)" ] && break; sleep 1; done
systemctl restart wpa_supplicant || true
sleep 3
systemctl restart NetworkManager || true
sleep 8

if wifi_ok; then
  echo "[aic8800-reload] Wi-Fi is usable"
else
  echo "[aic8800-reload] Wi-Fi is still not usable. Check: journalctl -k -b 0 | grep -i aic"
fi
exit 0
RELOAD
  sudo chmod 755 "$RELOAD_BIN"

  sudo tee "/etc/systemd/system/$RELOAD_UNIT" >/dev/null <<UNIT
[Unit]
Description=AIC8800 reload driver after hot-plug

[Service]
Type=oneshot
ExecStart=$RELOAD_BIN
UNIT

  sudo tee "$RELOAD_RULE" >/dev/null <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="a69c", ATTR{idProduct}=="8d80", RUN+="/usr/bin/systemctl --no-block start aic8800-reload.service"
RULE

  sudo systemctl daemon-reload
  sudo systemctl enable "$SYNC_UNIT" >/dev/null 2>&1
  sudo udevadm control --reload
}

do_install() {
  local fw src p
  fw="$(latest_file "$RPMBUILD/RPMS/noarch" 'aic8800d80-firmware-*.rpm')"
  src="$(latest_file "$RPMBUILD/RPMS/noarch" 'akmod-aic8800d80-*.rpm')"
  [ -n "$fw" ] && [ -n "$src" ] || die "Packages not found. Run: bash $0 build"
  sudo test -r "$AKMODS_PRIV" || die "Signing key is not in $AKMODS_DIR. Run: bash $0 keys"

  # Remove older versions in the same transaction as the new packages.
  # Each package must appear once: a duplicate --uninstall makes rpm-ostree abort.
  local unin=() seen=" " 
  for p in "${OLD_PKGS[@]}" akmod-aic8800d80 aic8800d80-firmware; do
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    rpm -q "$p" >/dev/null 2>&1 && unin+=(--uninstall "$p")
  done
  while read -r p; do
    [ -n "$p" ] && unin+=(--uninstall "$p")
  done < <(rpm -qa --qf '%{NAME}\n' | grep '^kmod-aic8800d80' || true)

  say "Layering $(basename "$fw") and $(basename "$src")..."
  sudo rpm-ostree install --idempotent "${unin[@]}" "$fw" "$src"

  write_services

  say "Starting the apply service now (builds for the running kernel with akmods)..."
  sudo systemctl start "$SYNC_UNIT" || warn "Service failed; see: journalctl -u $SYNC_UNIT -b"

  if [ "${AIC_NO_REBOOT:-0}" = "1" ]; then
    warn "AIC_NO_REBOOT=1: reboot to finish the layer update."
    return
  fi
  say "Rebooting in 15 seconds (Ctrl+C to cancel)."
  local i
  for i in $(seq 15 -1 1); do printf '\r  %2d ' "$i"; sleep 1; done; echo
  sudo systemctl reboot
}

# ------------------------------------------------------------------------------
# Status and removal
# ------------------------------------------------------------------------------

do_status() {
  local kv; kv="$(uname -r)"
  echo "Kernel: $kv"
  printf '%-26s %s\n' "firmware package:" \
    "$(rpm -q aic8800d80-firmware >/dev/null 2>&1 && rpm -q aic8800d80-firmware || echo 'not installed')"
  printf '%-26s %s\n' "source package:" \
    "$(rpm -q akmod-aic8800d80 >/dev/null 2>&1 && rpm -q akmod-aic8800d80 || echo 'not installed')"
  printf '%-26s %s\n' "kmod for this kernel:" \
    "$(find "/usr/lib/modules/$kv" -name 'aic8800_fdrv.ko*' 2>/dev/null | grep -q . && echo installed || echo 'not installed')"
  printf '%-26s %s\n' "signing key (akmods):" \
    "$(sudo test -r "$AKMODS_PRIV" && echo present || echo MISSING)"
  printf '%-26s %s\n' "module loaded:" "$(lsmod | awk '{print $1}' | grep -c '^aic8800_fdrv$' || true)"
  printf '%-26s %s\n' "module signed by:" "$(modinfo -F signer aic8800_fdrv 2>/dev/null || echo '-')"
  echo "Wi-Fi interfaces: $(ls /sys/class/net | grep '^wl' || echo none)"
  printf '%-26s %s\n' "apply service:" "$(systemctl is-enabled "$SYNC_UNIT" 2>/dev/null || true)"
}

do_remove() {
  sudo systemctl disable "$SYNC_UNIT" "$RELOAD_UNIT" >/dev/null 2>&1 || true
  sudo rmmod aic8800_fdrv aic_zlp_quirk aic_load_fw 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$SYNC_UNIT" "/etc/systemd/system/$RELOAD_UNIT" \
    "$SYNC_BIN" "$RELOAD_BIN" "$RELOAD_RULE" "$RELOAD_STAMP"
  sudo systemctl daemon-reload
  sudo udevadm control --reload

  local rm_pkgs=() p
  for p in aic8800d80-firmware akmod-aic8800d80; do
    rpm -q "$p" >/dev/null 2>&1 && rm_pkgs+=("$p")
  done
  while read -r p; do
    [ -n "$p" ] && rm_pkgs+=("$p")
  done < <(rpm -qa --qf '%{NAME}\n' | grep '^kmod-aic8800d80' || true)
  if [ "${#rm_pkgs[@]}" -gt 0 ]; then
    sudo rpm-ostree uninstall "${rm_pkgs[@]}"
  fi

  sudo rm -rf /var/cache/akmods/aic8800d80
  say "Removal scheduled. Your keys in ~/.aic8800-keys were kept. Reboot to finish."
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------

case "${1:-all}" in
  all)     do_keys; do_build; do_install ;;
  keys)    do_keys ;;
  build)   do_build ;;
  install) do_install ;;
  status)  do_status ;;
  remove)  do_remove ;;
  *)       echo "Usage: $0 {all|keys|build|install|status|remove}"; exit 1 ;;
esac

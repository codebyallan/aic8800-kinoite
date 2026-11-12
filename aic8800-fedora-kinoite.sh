#!/usr/bin/env bash
# ==============================================================================
# aic8800-fedora-kinoite.sh - AIC8800D80 driver RPM for Fedora Kinoite, built from
# the upstream spec (commit 2c2e670). Signs the modules when a Secure Boot key is
# present, and builds unsigned modules otherwise. Also installs boot and hot-plug
# helpers. Requires aic8800d80.spec in the same folder as this script.
# Usage: bash aic8800-fedora-kinoite.sh [all|build|install|status|remove]
# ==============================================================================
set -euo pipefail

REPO="shenmintao/aic8800d80"
COMMIT="2c2e67097016521f21c8916d1b914e21eb24e306"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC_SRC="$SCRIPT_DIR/aic8800d80.spec"
RPMBUILD="$HOME/rpmbuild"
KEY_DIR="${KEY_DIR:-$HOME/.aic8800-keys/db}"
TB="${TB:-aic8800-build}"

# Boot check (runs once per boot while the pending marker exists)
POST_BIN=/usr/local/sbin/aic8800-postcheck
POST_UNIT=aic8800-postcheck.service
STATE_DIR=/var/lib/aic8800
PENDING="$STATE_DIR/pending"

# Hot-plug reload (reloads the modules when the dongle is re-plugged)
RELOAD_BIN=/usr/local/sbin/aic8800-reload
RELOAD_UNIT=aic8800-reload.service
RELOAD_RULE=/etc/udev/rules.d/98-aic8800-reload.rules
RELOAD_STAMP=/run/aic8800-reload.stamp

# Packages from earlier flows that conflict with this RPM.
OLD_PKGS=(akmod-aic8800 aic8800-kmod-common akmods-keys-local)
FW_CHECK=/usr/lib/firmware/aic8800D80/fw_patch_table_8800d80_u02.bin

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAVISO:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Rode como usuário normal, sem sudo."

check_keys() {
  [ -r "$KEY_DIR/db.key" ] && [ -r "$KEY_DIR/db.pem" ] \
    || die "Chave não encontrada em $KEY_DIR (precisa de db.key e db.pem)."
}

do_build() {
  local kver; kver="$(uname -r)"
  command -v toolbox >/dev/null || die "toolbox não encontrado (incluído no Kinoite)."
  [ -r "$SPEC_SRC" ] || die "Spec não encontrado: $SPEC_SRC"

  # Signing is optional: with a key, modules are signed; without one, they are
  # unsigned, which only works when Secure Boot is disabled.
  local signdef=()
  if [ -r "$KEY_DIR/db.key" ] && [ -r "$KEY_DIR/db.pem" ]; then
    signdef=(--define "signdir $KEY_DIR")
  elif [ "$(mokutil --sb-state 2>/dev/null | grep -c 'enabled')" -gt 0 ]; then
    die "Secure Boot is enabled but no signing key was found in $KEY_DIR. See README.md."
  else
    warn "No signing key found; building unsigned modules (only works with Secure Boot disabled)."
  fi

  # Create the build toolbox once; it reuses the host's home directory.
  if ! podman container exists "$TB" 2>/dev/null; then
    say "Criando toolbox de build '$TB'..."
    toolbox create --container "$TB"
  fi

  mkdir -p "$RPMBUILD"/{SOURCES,SPECS,RPMS,SRPMS,BUILD,BUILDROOT}
  cp -f "$SPEC_SRC" "$RPMBUILD/SPECS/aic8800d80.spec"

  local tarball="$RPMBUILD/SOURCES/aic8800d80-$COMMIT.tar.gz"
  say "Baixando fonte do commit ${COMMIT:0:7}..."
  curl -fL --retry 3 -o "$tarball" \
    "https://github.com/$REPO/archive/$COMMIT/aic8800d80-$COMMIT.tar.gz" \
    || die "Falha ao baixar o commit $COMMIT. Confira o hash."

  # Build script that runs inside the toolbox.
  cat > "$RPMBUILD/build-in-toolbox.sh" <<'INTB'
#!/usr/bin/env bash
set -euo pipefail
KVER="$1"; RPMBUILD="$2"; shift 2
sudo dnf install -y rpm-build rpmdevtools gcc make curl "kernel-devel-$KVER"
rpmbuild --define "kver $KVER" "$@" -bb "$RPMBUILD/SPECS/aic8800d80.spec"
INTB

  say "Compilando e assinando dentro do toolbox '$TB' (kernel $kver)..."
  toolbox run --container "$TB" bash "$RPMBUILD/build-in-toolbox.sh" "$kver" "$RPMBUILD" "${signdef[@]}"
  say "RPM gerado em $RPMBUILD/RPMS/$(uname -m)/"
}

latest_rpm() {
  find "$RPMBUILD/RPMS/$(uname -m)" -maxdepth 1 -name 'aic8800d80-*.rpm' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-
}

# Remove packages from earlier flows, so the new modules are the only copy.
remove_old() {
  local p installed=()
  for p in aic8800d80 "${OLD_PKGS[@]}"; do
    if rpm -q "$p" >/dev/null 2>&1; then installed+=("$p"); fi
  done
  if [ "${#installed[@]}" -gt 0 ]; then
    say "Removendo pacotes anteriores: ${installed[*]}"
    sudo rpm-ostree uninstall "${installed[@]}"
  fi
  sudo rm -f /etc/modprobe.d/aic8800-fw.conf
}

install_helpers() {
  say "Instalando verificação no boot e recarga ao reconectar..."
  sudo mkdir -p "$STATE_DIR"
  sudo touch "$PENDING"

  # Boot check: loads the module, re-triggers USB, checks Wi-Fi and Bluetooth.
  sudo tee "$POST_BIN" >/dev/null <<'POST'
#!/usr/bin/env bash
# Runs at boot while the pending marker exists.
set -u
PENDING=/var/lib/aic8800/pending
ok=1
say() { echo "[aic8800] $*"; }

[ -f "$PENDING" ] || exit 0

modprobe aic8800_fdrv || { say "modprobe aic8800_fdrv falhou"; ok=0; }

udevadm trigger --subsystem-match=usb --action=add || true
udevadm settle --timeout=30 || true
sleep 5

if ls /sys/class/net 2>/dev/null | grep -q '^wl'; then
  say "Wi-Fi OK"
else
  say "Wi-Fi: interface não apareceu"; ok=0
fi

if compgen -G '/sys/class/bluetooth/hci*' >/dev/null; then
  say "Bluetooth OK"
else
  say "Bluetooth: sem controlador hci"; ok=0
fi

if [ "$ok" -eq 1 ]; then
  rm -f "$PENDING"
  say "Concluído."
else
  say "Pendências; tentará de novo no próximo boot. Log: journalctl -u aic8800-postcheck.service"
fi
exit 0
POST
  sudo chmod 755 "$POST_BIN"

  sudo tee "/etc/systemd/system/$POST_UNIT" >/dev/null <<UNIT
[Unit]
Description=AIC8800 post-install check (module, Wi-Fi and Bluetooth)
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=$PENDING

[Service]
Type=oneshot
ExecStart=$POST_BIN

[Install]
WantedBy=multi-user.target
UNIT

  # Hot-plug reload: when the dongle is re-plugged and Wi-Fi is not usable,
  # reload the modules, restart wpa_supplicant and NetworkManager, and check
  # the result with a real scan. A 60 s guard stops the reload's own USB
  # events from looping.
  sudo tee "$RELOAD_BIN" >/dev/null <<'RELOAD'
#!/usr/bin/env bash
# Reload the AIC8800 modules after a re-plug if Wi-Fi is not usable.
set -u
PENDING=/var/lib/aic8800/pending
STAMP=/run/aic8800-reload.stamp

[ -f "$PENDING" ] && exit 0

now="$(date +%s)"
last="$(cat "$STAMP" 2>/dev/null || echo 0)"
if [ $((now - last)) -lt 60 ]; then
  exit 0
fi
echo "$now" > "$STAMP"

# Usable means: the interface exists, is up, and a scan returns networks.
# If iw is missing, fall back to the interface existence check.
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
modprobe -r aic8800_fdrv aic_load_fw || echo "[aic8800-reload] modprobe -r failed"
modprobe aic8800_fdrv || echo "[aic8800-reload] modprobe aic8800_fdrv failed"

# Wait for the interface to appear.
for _ in $(seq 1 16); do
  [ -n "$(wifi_dev)" ] && break
  sleep 1
done

# The supplicant keeps a stale handle to the old interface after a reload,
# so restart it before NetworkManager, which depends on it.
systemctl restart wpa_supplicant || true
sleep 3
systemctl restart NetworkManager || true
sleep 8

if wifi_ok; then
  echo "[aic8800-reload] Wi-Fi usable"
else
  echo "[aic8800-reload] Wi-Fi still not usable; check: journalctl -k -b 0 | grep -i aic"
fi
exit 0
RELOAD
  sudo chmod 755 "$RELOAD_BIN"

  sudo tee "/etc/systemd/system/$RELOAD_UNIT" >/dev/null <<UNIT
[Unit]
Description=AIC8800 reload modules after hot-plug

[Service]
Type=oneshot
ExecStart=$RELOAD_BIN
UNIT

  sudo tee "$RELOAD_RULE" >/dev/null <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="a69c", ATTR{idProduct}=="8d80", RUN+="/usr/bin/systemctl --no-block start aic8800-reload.service"
RULE

  sudo systemctl daemon-reload
  sudo systemctl enable "$POST_UNIT" >/dev/null 2>&1
  sudo udevadm control --reload
}

do_install() {
  local rpm
  rpm="$(latest_rpm)"
  [ -n "$rpm" ] || die "RPM não encontrado. Rode: bash $0 build"
  say "Instalando $(basename "$rpm")..."

  remove_old
  sudo rpm-ostree install --idempotent "$rpm"
  install_helpers

  if [ "${AIC_NO_REBOOT:-0}" = "1" ]; then
    warn "AIC_NO_REBOOT=1: reinicie o sistema para concluir."
    return
  fi
  say "Reiniciando em 15 s para aplicar (Ctrl+C cancela)."
  local i
  for i in $(seq 15 -1 1); do printf '\r  %2d ' "$i"; sleep 1; done; echo
  sudo systemctl reboot
}

do_status() {
  echo "Kernel: $(uname -r)"
  printf '%-22s %s\n' "aic8800d80:" "$(rpm -q aic8800d80 2>/dev/null || echo 'não instalado')"
  printf '%-22s %s\n' "Firmware D80:" "$([ -f "$FW_CHECK" ] && echo OK || echo AUSENTE)"
  printf '%-22s %s\n' "Pós-boot pendente:" "$([ -f "$PENDING" ] && echo sim || echo não)"
  printf '%-22s %s\n' "Módulo carregado:" "$(lsmod | awk '{print $1}' | grep -c '^aic8800_fdrv$' || true)"
  echo "Interfaces Wi-Fi: $(ls /sys/class/net | grep '^wl' || echo nenhuma)"
  echo "Controladores BT: $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ' || true)"
  printf '%-22s %s\n' "Recarga ao replug:" "$([ -f "$RELOAD_RULE" ] && echo instalada || echo não)"
}

do_remove() {
  sudo systemctl disable "$POST_UNIT" "$RELOAD_UNIT" >/dev/null 2>&1 || true
  sudo rm -f "/etc/systemd/system/$POST_UNIT" "/etc/systemd/system/$RELOAD_UNIT" \
    "$POST_BIN" "$PENDING" "$RELOAD_BIN" "$RELOAD_RULE" "$RELOAD_STAMP"
  sudo udevadm control --reload
  sudo systemctl daemon-reload
  sudo rpm-ostree uninstall aic8800d80 || true
  say "Remoção agendada. Reinicie para concluir."
}

case "${1:-all}" in
  all)     do_build; do_install ;;
  build)   do_build ;;
  install) do_install ;;
  status)  do_status ;;
  remove)  do_remove ;;
  *)       echo "Uso: $0 {all|build|install|status|remove}"; exit 1 ;;
esac
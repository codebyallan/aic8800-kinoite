# AIC8800D80 Wi-Fi and Bluetooth on Fedora Kinoite

This repository builds and installs the out-of-tree **AIC8800D80** driver as a
single RPM on Fedora Kinoite. The RPM is built from a pinned commit of the
upstream driver, and it works with Secure Boot enabled or disabled.

The helper script also installs two small systemd services. They work around a
hot-plug problem that is still open upstream (see [Known limitations](#known-limitations)).

## Contents

- `aic8800-fedora-kinoite.sh`: build, install, status and remove commands.
- `aic8800d80.spec`: RPM spec, based on the upstream `bazzite/aic8800d80.spec`.
- `.gitignore`: keeps signing keys and build artifacts out of Git.

## Supported hardware

USB device `a69c:8d80` (`AIC Wlan`), a combined Wi-Fi and Bluetooth adapter.
Bluetooth uses the standard `btusb` driver once the firmware is loaded.

Other AIC8800 variants are not tested here. The spec includes all firmware
variants from upstream, but only the `8d80` device is covered by the hot-plug
helper.

## Requirements

- Fedora Kinoite (tested on Fedora 45, kernel 7.3).
- `toolbox`, included in Kinoite.
- Internet access for the **first** build, to download the source tarball from
  GitHub. After that, the cached tarball is reused.
- `kernel-devel` for the running kernel, installed on the host:

  ```bash
  sudo rpm-ostree install kernel-devel-$(uname -r)
  sudo systemctl reboot
  ```

- Secure Boot is **optional**. See [Secure Boot](#secure-boot).

## Secure Boot

Secure Boot rejects kernel modules that are not signed by a key the firmware
trusts. There are two cases.

### Secure Boot disabled

No key is needed. The script builds unsigned modules and prints a notice.

### Secure Boot enabled

You must create a signing key and enroll its certificate in the Machine Owner
Key (MOK) list once. The build stops with an error if Secure Boot is enabled
and no key is found.

Create the key pair (keep the private key secret):

```bash
mkdir -p ~/.aic8800-keys/db && cd ~/.aic8800-keys/db
openssl req -new -x509 -newkey rsa:2048 -keyout db.key -out db.pem \
  -nodes -days 36500 -subj "/CN=AIC8800 local module signing/"
openssl x509 -in db.pem -outform DER -out db.der
```

Enroll the certificate:

```bash
sudo mokutil --import ~/.aic8800-keys/db/db.der
# Choose a one-time password when asked. Then reboot:
sudo systemctl reboot
```

On the blue **MOK Manager** screen during boot, choose **Enroll MOK**, then
**Continue**, confirm, and enter the password you set.

After enrollment, verify it:

```bash
mokutil --test-key ~/.aic8800-keys/db/db.der
```

The expected answer is `is already enrolled`.

## Usage

Run all commands from the folder that contains the script and the spec:

```bash
cd ~/path/to/this/repository
chmod +x aic8800-fedora-kinoite.sh
```

| Command   | What it does |
|-----------|--------------|
| `build`   | Downloads the pinned source (first time only), builds the RPM inside the `aic8800-build` toolbox, and signs it if a key is present. |
| `install` | Removes older versions, installs the newest RPM with `rpm-ostree`, installs the boot check and hot-plug helper, then reboots after 15 seconds. |
| `all`     | `build` followed by `install`. |
| `status`  | Shows the installed package, firmware, module, interfaces and helper state. |
| `remove`  | Removes the package, the helpers and their services. Reboot afterwards. |

Set `AIC_NO_REBOOT=1` before `install` to skip the automatic reboot.

### First installation

```bash
bash aic8800-fedora-kinoite.sh build
bash aic8800-fedora-kinoite.sh install
```

Plug the dongle in **before** you boot if you want Wi-Fi and Bluetooth to work
right away. See [Hot-plug behavior](#hot-plug-behavior).

### After a kernel update

The RPM is built for one exact kernel version. After a kernel update, rebuild
and reinstall once the system has rebooted into the new kernel, so `uname -r`
reports the new version:

```bash
bash aic8800-fedora-kinoite.sh build
bash aic8800-fedora-kinoite.sh install
```

## Verifying the installation

```bash
bash aic8800-fedora-kinoite.sh status
ls /sys/class/net | grep '^wl'
sudo dmesg | grep -iE 'key was rejected|module verification'
```

A working system shows `Módulo carregado: 1`, a `wlan*` interface, a `hci*`
controller, and no `Key was rejected` or `module verification` lines.

Messages that start with `Lockdown: systemd-logind: hibernation is restricted`
are harmless. They come from systemd and do not affect the driver.

## Hot-plug behavior

The helper `/usr/local/sbin/aic8800-reload` runs when the dongle is connected.
If Wi-Fi is not usable, it:

1. Reloads `aic8800_fdrv` and `aic_load_fw`.
2. Restarts `wpa_supplicant`, then `NetworkManager`.
3. Checks the result with a real scan (`iw dev wlan0 scan`).

A 60-second guard prevents the helper from triggering itself through the USB
events it causes.

Check what happened:

```bash
journalctl -u aic8800-reload.service -b --no-pager | tail -10
nmcli device status
```

## Known limitations

- **Hot-plug is not reliable on its own.** After a re-plug, the firmware can fail
  to open with `ENOENT` (`errno=-2`). The helper recovers from this in most
  cases, but not always. If it does not recover, reboot with the dongle connected.
- **The helper depends on `wpa_supplicant` and NetworkManager.** If they are not
  running, Wi-Fi stays unavailable even though the driver is loaded.
- **Stripping is disabled for the modules.** The spec sets `%global __strip /bin/true`
  so that the signature appended to each `.ko` is preserved. The modules are
  therefore not stripped.
- **Upstream bug.** The hot-plug failure is in the driver's firmware loading. The
  logs and the commit used are the information needed to report it upstream.

## Troubleshooting

**`Key was rejected by service` when loading the module.**
Secure Boot does not trust the module signature. Check that the key is enrolled:

```bash
mokutil --test-key ~/.aic8800-keys/db/db.der
```

If it is not enrolled, follow [Secure Boot](#secure-boot). If it is enrolled,
confirm that the installed module is signed:

```bash
rm -rf /tmp/rpmcheck && mkdir -p /tmp/rpmcheck
rpm2cpio ~/rpmbuild/RPMS/x86_64/aic8800d80-*.rpm | (cd /tmp/rpmcheck && cpio -idm 2>/dev/null)
tail -c 28 /tmp/rpmcheck/usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/aic8800/aic8800_fdrv.ko | strings
```

The output must contain `~Module signature appended~`.

**`wpa_supplicant couldn't grab this interface`.**
Restart the supplicant and NetworkManager:

```bash
sudo systemctl restart wpa_supplicant
sudo systemctl restart NetworkManager
```

**`file failed to open` or `errno=-2` after a re-plug.**
This is the upstream hot-plug issue. Reboot with the dongle connected, or wait
for the helper to recover it.

**The build stops with a signing error or a missing `kernel-devel`.**
Make sure `kernel-devel-$(uname -r)` is installed on the host, and that
`~/.aic8800-keys/db/db.key` and `db.pem` are readable if Secure Boot is enabled.

## Uninstall

```bash
bash aic8800-fedora-kinoite.sh remove
sudo systemctl reboot
```

To delete the signing keys as well, remove `~/.aic8800-keys/`. If you enrolled
the certificate in MOK, remove it with `sudo mokutil --delete ~/.aic8800-keys/db/db.der`
and reboot.

## Contributing

Issues and pull requests are welcome. Please include:

- `uname -r`
- `rpm -q aic8800d80`
- `bash aic8800-fedora-kinoite.sh status`
- The relevant lines from `journalctl -k -b 0`

## License

The driver source is licensed under GPL-2.0-only, as in the upstream project.
The helper script and documentation are provided as-is, without warranty.
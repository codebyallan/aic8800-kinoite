%global commit 2c2e67097016521f21c8916d1b914e21eb24e306
%global shortcommit %(echo %{commit} | cut -c1-7)
%global snapdate 20261112
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_strip %{nil}
%{!?kver:%global kver %(uname -r)}

Name:           aic8800d80
# Versions before 2026-09-24 were bare commit hashes, which rpm does not
# order by commit history. Epoch 1 sorts every snapshot version after them.
Epoch:          1
Version:        1.0.0^%{snapdate}git%{shortcommit}
Release:        1%{?dist}
Summary:        AIC8800 USB Wi-Fi, Bluetooth firmware, and ZLP quirk driver

License:        GPL-2.0-only
URL:            https://github.com/shenmintao/aic8800d80
Source0:        %{url}/archive/%{commit}/%{name}-%{commit}.tar.gz

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  kernel-devel-uname-r = %{kver}

Requires:       kernel-uname-r = %{kver}
Requires:       /usr/bin/eject
Requires:       usb_modeswitch
Requires(post): /usr/sbin/depmod
Requires(postun): /usr/sbin/depmod

%description
Out-of-tree AIC8800 USB driver with Wi-Fi support, Bluetooth firmware loading,
udev mode-switch rules, and all firmware variants shipped by the upstream
repository. Combo adapters use the standard Linux btusb transport driver. A
device-scoped companion module supplies the required ACL bulk TX ZLP behavior
for USB device 368b:8d81 without replacing the distribution btusb module.

Modules are signed with the local Secure Boot db key given as the signdir
macro at build time.

%prep
%autosetup -n %{name}-%{commit}

%build
# Signing is optional. With --define 'signdir /path/to/keys/db' the modules are
# signed with that key (required when Secure Boot is enabled). Without it, the
# modules are built unsigned and only load with Secure Boot disabled.
%if 0%{?signdir:1}
[ -r "%{signdir}/db.key" ] && [ -r "%{signdir}/db.pem" ] \
  || { echo "ERROR: db.key and db.pem not readable in %{signdir}" >&2; exit 1; }
SIGN=/usr/src/kernels/%{kver}/scripts/sign-file
[ -x "$SIGN" ] || { echo "ERROR: $SIGN not found; install kernel-devel-%{kver}" >&2; exit 1; }
%endif

# Switch the driver to the request_firmware() loader (default is off upstream).
sed -i 's/^export CONFIG_USE_FW_REQUEST = n/export CONFIG_USE_FW_REQUEST = y/' drivers/aic8800/Makefile
grep -q '^export CONFIG_USE_FW_REQUEST = y' drivers/aic8800/Makefile \
  || { echo "ERROR: could not enable CONFIG_USE_FW_REQUEST" >&2; exit 1; }

make -C drivers/aic8800 KVER=%{kver} KDIR=/usr/src/kernels/%{kver} clean
make -C drivers/aic8800 KVER=%{kver} KDIR=/usr/src/kernels/%{kver}

%if 0%{?signdir:1}
# Sign every module with the db key so the Secure Boot kernel accepts it.
for ko in \
  drivers/aic8800/aic_load_fw/aic_load_fw.ko \
  drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko \
  drivers/aic8800/aic_zlp_quirk/aic_zlp_quirk.ko; do
  "$SIGN" sha256 %{signdir}/db.key %{signdir}/db.pem "$ko" || { echo "ERROR: signing $ko failed" >&2; exit 1; }
done
%else
echo "NOTICE: building unsigned modules (no signdir). They load only with Secure Boot disabled." >&2
%endif

%install
rm -rf %{buildroot}

install -Dpm0644 \
  drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko \
  %{buildroot}/usr/lib/modules/%{kver}/kernel/drivers/net/wireless/aic8800/aic8800_fdrv.ko

install -Dpm0644 \
  drivers/aic8800/aic_load_fw/aic_load_fw.ko \
  %{buildroot}/usr/lib/modules/%{kver}/kernel/drivers/net/wireless/aic8800/aic_load_fw.ko

install -Dpm0644 \
  drivers/aic8800/aic_zlp_quirk/aic_zlp_quirk.ko \
  %{buildroot}/usr/lib/modules/%{kver}/kernel/drivers/bluetooth/aic8800/aic_zlp_quirk.ko

install -Dpm0644 \
  aic.rules \
  %{buildroot}/usr/lib/udev/rules.d/90-aic8800-mode-switch.rules

install -Dpm0644 \
  usb_modeswitch/1111_1111 \
  %{buildroot}/etc/usb_modeswitch.d/1111:1111

install -d -m 0755 %{buildroot}/usr/lib/firmware
cp -a fw/aic8800* %{buildroot}/usr/lib/firmware/

%post
/usr/sbin/depmod -a %{kver} || :

%postun
/usr/sbin/depmod -a %{kver} || :

%files
%dir /usr/lib/modules/%{kver}/kernel/drivers/net/wireless/aic8800
/usr/lib/modules/%{kver}/kernel/drivers/net/wireless/aic8800/aic8800_fdrv.ko
/usr/lib/modules/%{kver}/kernel/drivers/net/wireless/aic8800/aic_load_fw.ko
/usr/lib/modules/%{kver}/kernel/drivers/bluetooth/aic8800/aic_zlp_quirk.ko
/usr/lib/udev/rules.d/90-aic8800-mode-switch.rules
%config(noreplace) /etc/usb_modeswitch.d/1111:1111
/usr/lib/firmware/aic8800*

%changelog
* Thu Nov 12 2026 local <local@localhost> - 1:1.0.0^20261112git2c2e670-2
- Make module signing optional: sign only when signdir is given.

* Thu Nov 12 2026 local <local@localhost> - 1:1.0.0^20261112git2c2e670-1
- Pin commit 2c2e67097016521f21c8916d1b914e21eb24e306.
- Sign all modules with the local Secure Boot db key (signdir macro).

* Thu Sep 24 2026 Shen Mintao <shenmintao@gmail.com> - 1:1.0.0^20260924git3e9a025-1
- Version snapshots as 1.0.0^<date>git<commit> with Epoch 1. The previous
  commit-hash versions do not sort in commit order, so rpm could treat a
  newer snapshot as an older package.
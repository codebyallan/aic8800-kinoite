%global commit 2c2e67097016521f21c8916d1b914e21eb24e306
%global shortcommit %(echo %{commit} | cut -c1-7)
%global snapdate 20261112
%global kmodname aic8800d80
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_strip %{nil}
%global buildforkernels akmod

Name:           %{kmodname}-kmod
Epoch:          1
Version:        1.0.0^%{snapdate}git%{shortcommit}
Release:        1%{?dist}
Summary:        AIC8800D80 Wi-Fi and Bluetooth kernel modules, built by akmods
License:        GPL-2.0-only
URL:            https://github.com/shenmintao/aic8800d80
Source0:        %{url}/archive/%{commit}/%{kmodname}-%{commit}.tar.gz

BuildRequires:  kmodtool
BuildRequires:  gcc
BuildRequires:  make

%{expand:%(kmodtool --target %{_target_cpu} --kmodname %{kmodname} --%{buildforkernels} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null) }

%description
Out-of-tree AIC8800D80 modules (aic8800_fdrv, aic_load_fw, aic_zlp_quirk).
akmods compiles them for each kernel and they are signed with the key in /etc/pki/akmods.

%prep
%{?kmodtool_check}
kmodtool --target %{_target_cpu} --kmodname %{kmodname} --%{buildforkernels} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null

%setup -q -c -T -a 0
cd %{kmodname}-%{commit}
# Use the request_firmware() loader, as the upstream spec does.
sed -i 's/^export CONFIG_USE_FW_REQUEST = n/export CONFIG_USE_FW_REQUEST = y/' drivers/aic8800/Makefile
grep -q '^export CONFIG_USE_FW_REQUEST = y' drivers/aic8800/Makefile \
  || { echo "ERROR: could not enable CONFIG_USE_FW_REQUEST" >&2; exit 1; }
cd ..

for kernel_version in %{?kernel_versions} ; do
  cp -a %{kmodname}-%{commit} _kmod_build_${kernel_version%%___*}
done

%build
for kernel_version in %{?kernel_versions} ; do
  kver="${kernel_version%%___*}"
  kdir="${kernel_version##*___}"
  make -C _kmod_build_${kver}/drivers/aic8800 KVER=${kver} KDIR=${kdir} %{?_smp_mflags}

  # Sign every module with the key in /etc/pki/akmods. Secure Boot rejects unsigned modules.
  for ko in aic8800_fdrv/aic8800_fdrv aic_load_fw/aic_load_fw aic_zlp_quirk/aic_zlp_quirk; do
    "${kdir}/scripts/sign-file" sha256 /etc/pki/akmods/private/private_key.priv \
      /etc/pki/akmods/certs/public_key.der "_kmod_build_${kver}/drivers/aic8800/${ko}.ko" \
      || { echo "ERROR: signing ${ko}.ko failed" >&2; exit 1; }
  done
done

%install
for kernel_version in %{?kernel_versions} ; do
  kver="${kernel_version%%___*}"
  for m in aic8800_fdrv/aic8800_fdrv aic_load_fw/aic_load_fw aic_zlp_quirk/aic_zlp_quirk; do
    install -Dpm0644 _kmod_build_${kver}/drivers/aic8800/${m}.ko \
      %{buildroot}%{kmodinstdir_prefix}/${kver}/%{kmodinstdir_postfix}/aic8800/$(basename ${m}).ko
  done
done
%{?akmod_install}

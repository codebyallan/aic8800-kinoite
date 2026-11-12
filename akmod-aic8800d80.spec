# Ships the kmod source RPM where akmods expects it. Nothing is built or run at
# install time, so there is no %post and no sandboxed build inside rpm-ostree.
Name:           akmod-aic8800d80
Version:        1.0.0
Release:        %(date +%%Y%%m%%d%%H%%M)%{?dist}
Summary:        AIC8800D80 kmod source for akmods (no build at install time)
License:        GPL-2.0-only
URL:            https://github.com/shenmintao/aic8800d80
BuildArch:      noarch
Source0:        aic8800d80-kmod.src.rpm

%description
Installs the source RPM that akmods uses to build the AIC8800D80 kernel modules
on the host. Installing this package compiles nothing and runs no scripts.

%install
install -Dpm0644 %{SOURCE0} %{buildroot}/usr/src/akmods/aic8800d80-kmod.src.rpm
# akmods finds the kmod through this .latest link, as the kmodtool template creates it.
ln -s aic8800d80-kmod.src.rpm %{buildroot}/usr/src/akmods/aic8800d80-kmod.latest

%files
%dir /usr/src/akmods
/usr/src/akmods/aic8800d80-kmod.src.rpm
/usr/src/akmods/aic8800d80-kmod.latest

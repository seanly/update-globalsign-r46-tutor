Name:           globalsign-root-r46
Version:        2019.03.20
Release:        1%{?dist}
Summary:        GlobalSign Root R46 for the system CA trust store

License:        Distributable
URL:            https://support.globalsign.com/ca-certificates/globalsign-root-certificates
Source0:        globalsign-root-r46.crt
BuildArch:      noarch

Requires:       ca-certificates
Requires:       p11-kit-trust

%description
Adds the GlobalSign Root R46 certificate to the system trust store.
This package does not replace ca-certificates.

The certificate is valid from 2019-03-20 through 2046-03-20.
SHA-256: 4FA3126D8D3A11D1C4855A4F807CBAD6CF919D3A5A88B03BEA2C6372D93C40C9

%prep
fp=$(openssl x509 -in %{SOURCE0} -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')
test "$fp" = "4FA3126D8D3A11D1C4855A4F807CBAD6CF919D3A5A88B03BEA2C6372D93C40C9"

%build

%install
mkdir -p %{buildroot}%{_sysconfdir}/pki/ca-trust/source/anchors
install -p -m 644 %{SOURCE0} %{buildroot}%{_sysconfdir}/pki/ca-trust/source/anchors/globalsign-root-r46.crt

%post
set -e
/usr/bin/update-ca-trust enable
/usr/bin/update-ca-trust extract

%postun
if [ "$1" -eq 0 ] && [ -x /usr/bin/update-ca-trust ]; then
  /usr/bin/update-ca-trust extract
fi

%files
%{_sysconfdir}/pki/ca-trust/source/anchors/globalsign-root-r46.crt

%changelog
* Mon Oct 26 2026 cacert-update <cacert-update@localhost> - 2019.03.20-1
- Add GlobalSign Root R46 to the system trust store.

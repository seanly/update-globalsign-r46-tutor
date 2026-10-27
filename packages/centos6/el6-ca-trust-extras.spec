Name:           el6-ca-trust-extras
Version:        2023.2.60
Release:        1%{?dist}
Summary:        Public TLS roots from ca-certificates 2023.2.60 missing on CentOS 6

License:        Distributable
URL:            https://wiki.mozilla.org/CA/Included_Certificates
Source0:        el6-ca-trust-extras-certs.tar.gz
Source1:        fingerprints.txt
BuildArch:      noarch

Requires:       ca-certificates
Requires:       p11-kit-trust
Obsoletes:      globalsign-root-r46

%description
Adds seven public TLS roots from CentOS 7 ca-certificates-2023.2.60_v7.0.306
that are not in CentOS 6 ca-certificates-2020.2.41: GlobalSign Root R46 and
E46, both DigiCert TLS G5 roots, ISRG Root X2, and the Microsoft 2017 RSA
and ECC roots. This package does not replace ca-certificates.

Same-key re-signs are omitted. CentOS 6 already trusts the previous GTS
Root R1-R4 and GlobalSign ECC Root CA - R4 certificates. Regional roots
are omitted, including TunTrust Root CA.

Roots Mozilla removed after NSS 2.60 are not included: E-Tugra Global Root
CA RSA v3, E-Tugra Global Root CA ECC v3, GLOBALTRUST 2020, Security
Communication RootCA3, and the three Trustwave Global roots.

Certificates are installed as trust anchors. update-ca-trust treats an
anchor as a full CA. Mozilla serverAuth limits, name constraints, and
distrust-after dates are not preserved.

%prep
set -e
rm -rf %{name}-%{version}
mkdir -p %{name}-%{version}
tar -xzf %{SOURCE0} -C %{name}-%{version}
cd %{name}-%{version}
count=0
while read -r fp file; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  test -f "$file"
  got=$(openssl x509 -in "$file" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')
  if [ "$got" != "$fp" ]; then
    echo "fingerprint mismatch for $file: $got" >&2
    exit 1
  fi
  count=$((count + 1))
done < %{SOURCE1}
test "$count" -eq 7
test "$(ls -1 ./*.crt | wc -l)" -eq 7

%build

%install
set -e
cd %{_builddir}/%{name}-%{version}
mkdir -p %{buildroot}%{_sysconfdir}/pki/ca-trust/source/anchors
install -p -m 644 ./*.crt %{buildroot}%{_sysconfdir}/pki/ca-trust/source/anchors/

%post
set -e
/usr/bin/update-ca-trust enable
/usr/bin/update-ca-trust extract

%postun
if [ "$1" -eq 0 ] && [ -x /usr/bin/update-ca-trust ]; then
  /usr/bin/update-ca-trust extract
fi

%files
%{_sysconfdir}/pki/ca-trust/source/anchors/*.crt

%changelog
* Tue Oct 27 2026 cacert-update <cacert-update@localhost> - 2023.2.60-1
- Add seven public TLS roots missing from CentOS 6 ca-certificates-2020.2.41.

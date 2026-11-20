# FERRIC Official Signed RPM Repository

Self-signed `dnf` / `yum` RPM repository for [FERRIC](https://github.com/debsahu/ferric), hosted on GitHub Pages at <https://debsahu.github.io/ferric-rpm/>.

Both every `.rpm` package (`gpgcheck=1`) and the repository metadata `repodata/repomd.xml` (`repo_gpgcheck=1`) are signed with an RSA-4096 SHA-256 GPG key compliant with RHEL 9+ crypto-policies.

## Supported Linux Distributions

- **x86_64 Desktop + CLI** (`ferric-gui` + `ferric`): RHEL 9 / 10, AlmaLinux 9 / 10, Rocky Linux 9 / 10, Fedora (`glibc >= 2.34`)
- **i386 / i686 Static CLI** (`ferric`, `musl` zero-dependency): legacy 32-bit x86 spectrometer workstations

## Quick Install (RHEL 9, AlmaLinux 9, Rocky 9, Fedora)

```bash
sudo curl -fsSL https://debsahu.github.io/ferric-rpm/ferric.repo -o /etc/yum.repos.d/ferric.repo
sudo dnf install ferric
```

Upgrade later with:

```bash
sudo dnf upgrade ferric
```

### Legacy `yum` / manual GPG import (if preferred)

```bash
sudo rpm --import https://debsahu.github.io/ferric-rpm/RPM-GPG-KEY-ferric
sudo curl -fsSL https://debsahu.github.io/ferric-rpm/ferric.repo -o /etc/yum.repos.d/ferric.repo
sudo yum install ferric
```

## Signing Key Details

- **Public Key URL:** <https://debsahu.github.io/ferric-rpm/RPM-GPG-KEY-ferric>
- **User ID:** `FERRIC RPM Repository Signing Key <debashish.sahu@gmail.com>`
- **Algorithm:** RSA-4096 (SHA-256 signatures)
- **Fingerprint:** `A484 B4E4 D0D7 6A41 91DD 6228 8E1B 8E3E EAF5 655B`

Verify after importing:

```bash
rpm -qa gpg-pubkey* --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n' | grep -i FERRIC
```

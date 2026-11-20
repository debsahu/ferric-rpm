#!/usr/bin/env bash
set -euo pipefail

# Build, GPG-sign, index, and verify the FERRIC DNF/YUM RPM repository into _site/.
# Intended to run inside AlmaLinux 9 / RHEL 9 (rpm-sign, createrepo_c, gnupg2, python3, curl).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/_site}"
SOURCE_REPO="${FERRIC_SOURCE_REPO:-debsahu/ferric}"
MAX_RELEASES="${MAX_RELEASES:-5}"

: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY must be provided in environment}"
: "${GPG_PASSPHRASE:?GPG_PASSPHRASE must be provided in environment}"

for cmd in rpm rpmsign createrepo_c gpg python3 curl sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d)"
ORIG_HOME="${HOME}"
cleanup() {
  local rc=$?
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  export HOME="${ORIG_HOME}"
  rm -rf "${WORK_DIR}"
  if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" && -d "${OUT_DIR}" ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${OUT_DIR}" || true
  fi
  exit "$rc"
}
trap cleanup EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -p "${GNUPGHOME}" "${WORK_DIR}/home" "${WORK_DIR}/downloads"
chmod 700 "${GNUPGHOME}" "${WORK_DIR}/home"
printf "allow-loopback-pinentry\n" > "${GNUPGHOME}/gpg-agent.conf"
chmod 600 "${GNUPGHOME}/gpg-agent.conf"

PASS_FILE="${WORK_DIR}/passphrase"
umask 077
printf '%s\n' "${GPG_PASSPHRASE}" > "${PASS_FILE}"
chmod 600 "${PASS_FILE}"

# Import private key without exposing key material on stdout.
printf '%s\n' "${GPG_PRIVATE_KEY}" | gpg --batch --quiet --import

EXPECTED_FPR="$(gpg --show-keys --with-colons "${REPO_ROOT}/RPM-GPG-KEY-ferric" | awk -F: '/^fpr:/ {print $10; exit}')"
SIGNING_FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ -z "${EXPECTED_FPR}" || "${EXPECTED_FPR}" != "${SIGNING_FPR}" ]]; then
  echo "ERROR: Imported secret key fingerprint (${SIGNING_FPR:-none}) does not match committed RPM-GPG-KEY-ferric (${EXPECTED_FPR:-none})" >&2
  exit 1
fi
echo "Verified signing key fingerprint: ${SIGNING_FPR}"

export HOME="${WORK_DIR}/home"
cat > "${HOME}/.rpmmacros" <<EOF
%_signature gpg
%_gpg_path ${GNUPGHOME}
%_gpg_name ${SIGNING_FPR}
%_gpg_digest_algo sha256
%_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${PASS_FILE}
EOF

rm -rf "${OUT_DIR}"
for arch in x86_64 i386 i686; do
  mkdir -p "${OUT_DIR}/rpm/${arch}/Packages"
done

export WORK_DIR OUT_DIR SOURCE_REPO MAX_RELEASES SIGNING_FPR REPO_ROOT
python3 - <<'PY'
import hashlib
import html
import json
import os
import pathlib
import shutil
import subprocess
import sys
import urllib.request

source_repo = os.environ["SOURCE_REPO"]
max_releases = int(os.environ["MAX_RELEASES"])
dl_dir = pathlib.Path(os.environ["WORK_DIR"]) / "downloads"
out_dir = pathlib.Path(os.environ["OUT_DIR"])
token = os.environ.get("GITHUB_TOKEN", "").strip()

api_url = f"https://api.github.com/repos/{source_repo}/releases?per_page=20"
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "ferric-rpm-repo-builder",
}
if token:
    headers["Authorization"] = f"Bearer {token}"

req = urllib.request.Request(api_url, headers=headers)
with urllib.request.urlopen(req, timeout=30) as resp:
    releases = json.loads(resp.read().decode("utf-8"))

selected = []
for rel in releases:
    if rel.get("draft") or rel.get("prerelease"):
        continue
    assets = rel.get("assets", [])
    rpm_assets = [a for a in assets if a.get("name", "").endswith(".rpm")]
    if not rpm_assets:
        continue
    selected.append((rel, assets, rpm_assets))
    if len(selected) >= max_releases:
        break

if not selected:
    print(f"ERROR: No published releases with .rpm assets found in {source_repo}", file=sys.stderr)
    sys.exit(1)

manifest = []

def download_file(url: str, dest: pathlib.Path) -> None:
    subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--retry-delay", "2", "-o", str(dest), url],
        check=True,
    )

def parse_sha256sums(path: pathlib.Path) -> dict[str, str]:
    sums: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        digest, raw_name = parts
        name = pathlib.Path(raw_name.lstrip("*").strip()).name
        sums[name] = digest.lower()
    return sums

for rel, assets, rpm_assets in selected:
    tag = rel["tag_name"]
    rel_dir = dl_dir / tag
    rel_dir.mkdir(parents=True, exist_ok=True)
    sums_asset = next((a for a in assets if a.get("name") == "SHA256SUMS.txt"), None)
    if sums_asset is None:
        print(f"ERROR: Release {tag} is missing SHA256SUMS.txt", file=sys.stderr)
        sys.exit(1)
    sums_path = rel_dir / "SHA256SUMS.txt"
    download_file(sums_asset["browser_download_url"], sums_path)
    sums = parse_sha256sums(sums_path)

    for asset in rpm_assets:
        name = asset["name"]
        rpm_path = rel_dir / name
        download_file(asset["browser_download_url"], rpm_path)
        actual = hashlib.sha256(rpm_path.read_bytes()).hexdigest().lower()
        expected = sums.get(name)
        if not expected:
            print(f"ERROR: {name} from {tag} missing from SHA256SUMS.txt", file=sys.stderr)
            sys.exit(1)
        if actual != expected:
            print(f"ERROR: SHA256 mismatch for {name}: expected {expected}, got {actual}", file=sys.stderr)
            sys.exit(1)
        print(f"Verified upstream asset checksum: {tag}/{name}")

        if "linux-x86_64" in name:
            target_arches = ["x86_64"]
            flavor = "x86_64 Desktop + CLI (ferric-gui + ferric)"
        elif "linux-i686" in name or "linux-i386" in name:
            target_arches = ["i386", "i686"]
            flavor = "32-bit Static CLI (ferric musl)"
        else:
            print(f"WARNING: Skipping unrecognized RPM asset arch: {name}", file=sys.stderr)
            continue

        for arch in target_arches:
            shutil.copy2(rpm_path, out_dir / "rpm" / arch / "Packages" / name)
        manifest.append({
            "tag": tag,
            "name": name,
            "flavor": flavor,
            "arches": ", ".join(target_arches),
            "published_at": (rel.get("published_at") or "")[:10],
            "upstream_sha256": actual,
        })

(out_dir / ".manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
PY

# Import our own public key into an isolated RPM DB for post-sign verification
VERIFY_RPMDB="${WORK_DIR}/rpmdb"
mkdir -p "${VERIFY_RPMDB}"
rpm --dbpath "${VERIFY_RPMDB}" --initdb
rpm --dbpath "${VERIFY_RPMDB}" --import "${REPO_ROOT}/RPM-GPG-KEY-ferric"

shopt -s nullglob
SIGNED_COUNT=0
for rpm_file in "${OUT_DIR}"/rpm/*/Packages/*.rpm; do
  echo "Signing ${rpm_file#${OUT_DIR}/}..."
  rpmsign --addsign "${rpm_file}"
  VERIFY_OUT="$(rpm --dbpath "${VERIFY_RPMDB}" -K --verbose "${rpm_file}")"
  echo "${VERIFY_OUT}"
  if grep -Eq "NOT OK|NOKEY" <<<"${VERIFY_OUT}"; then
    echo "ERROR: RPM signature verification failed for ${rpm_file}" >&2
    exit 1
  fi
  if ! grep -q "signatures OK" <<<"${VERIFY_OUT}"; then
    echo "ERROR: Expected 'signatures OK' in rpm -K output for ${rpm_file}" >&2
    exit 1
  fi
  SIGNED_COUNT=$((SIGNED_COUNT + 1))
done
shopt -u nullglob

if [[ "${SIGNED_COUNT}" -eq 0 ]]; then
  echo "ERROR: Zero RPM packages were signed" >&2
  exit 1
fi

for arch in x86_64 i386 i686; do
  ARCH_DIR="${OUT_DIR}/rpm/${arch}"
  if ! compgen -G "${ARCH_DIR}/Packages/*.rpm" >/dev/null; then
    echo "ERROR: No RPM packages staged in ${ARCH_DIR}/Packages" >&2
    exit 1
  fi
  echo "Indexing repodata for ${arch}..."
  createrepo_c --general-compress-type=gz "${ARCH_DIR}"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "${PASS_FILE}" \
    --digest-algo sha256 --local-user "${SIGNING_FPR}" \
    --detach-sign --armor \
    --output "${ARCH_DIR}/repodata/repomd.xml.asc" \
    "${ARCH_DIR}/repodata/repomd.xml"
  gpg --batch --verify "${ARCH_DIR}/repodata/repomd.xml.asc" "${ARCH_DIR}/repodata/repomd.xml"
done

cp "${REPO_ROOT}/RPM-GPG-KEY-ferric" "${OUT_DIR}/RPM-GPG-KEY-ferric"
cp "${REPO_ROOT}/ferric.repo" "${OUT_DIR}/ferric.repo"
touch "${OUT_DIR}/.nojekyll"

python3 - <<'PY'
import hashlib
import html
import json
import os
import pathlib
from datetime import datetime, timezone

out_dir = pathlib.Path(os.environ["OUT_DIR"])
fpr = os.environ["SIGNING_FPR"]
fpr_fmt = " ".join(fpr[i:i+4] for i in range(0, len(fpr), 4))
manifest_path = out_dir / ".manifest.json"
entries = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest_path.unlink()

rows_html = []
for item in entries:
    first_arch = item["arches"].split(",")[0].strip()
    pkg_rel = f"rpm/{first_arch}/Packages/{item['name']}"
    pkg_sha = hashlib.sha256((out_dir / pkg_rel).read_bytes()).hexdigest()
    rows_html.append(
        "<tr>"
        f"<td><code>{html.escape(item['tag'])}</code></td>"
        f"<td><a href=\"{html.escape(pkg_rel)}\"><code>{html.escape(item['name'])}</code></a></td>"
        f"<td>{html.escape(item['flavor'])}</td>"
        f"<td><code>{html.escape(item['arches'])}</code></td>"
        f"<td>{html.escape(item['published_at'])}</td>"
        f"<td><code>{html.escape(pkg_sha[:16])}…</code></td>"
        "</tr>"
    )

built_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FERRIC Signed RPM Repository</title>
  <style>
    :root {{ color-scheme: dark light; font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; }}
    body {{ max-width: 960px; margin: 2.5rem auto; padding: 0 1.25rem; line-height: 1.55; }}
    pre, code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    pre {{ background: rgba(127,127,127,0.12); padding: 1rem; border-radius: 8px; overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; font-size: 0.92rem; }}
    th, td {{ border-bottom: 1px solid rgba(127,127,127,0.28); text-align: left; padding: 0.55rem 0.65rem; }}
    .meta {{ opacity: 0.8; font-size: 0.92rem; }}
  </style>
</head>
<body>
  <h1>FERRIC Signed RPM Repository</h1>
  <p>Official GPG-signed <code>dnf</code> / <code>yum</code> repository for <a href="https://github.com/debsahu/ferric">FERRIC</a> (RHEL 9+, AlmaLinux 9+, Rocky Linux 9+, Fedora, and 32-bit <code>i686</code> CLI workstations).</p>

  <h2>Install on RHEL 9 / AlmaLinux 9 / Rocky 9 / Fedora</h2>
  <pre><code>sudo curl -fsSL https://debsahu.github.io/ferric-rpm/ferric.repo -o /etc/yum.repos.d/ferric.repo
sudo dnf install ferric</code></pre>

  <h2>Upgrade</h2>
  <pre><code>sudo dnf upgrade ferric</code></pre>

  <h2>GPG Signing Key</h2>
  <ul>
    <li>Key file: <a href="RPM-GPG-KEY-ferric"><code>RPM-GPG-KEY-ferric</code></a></li>
    <li>Repo file: <a href="ferric.repo"><code>ferric.repo</code></a></li>
    <li>User ID: <code>FERRIC RPM Repository Signing Key &lt;debashish.sahu@gmail.com&gt;</code></li>
    <li>Algorithm: RSA-4096 / SHA-256 (<code>gpgcheck=1</code> and <code>repo_gpgcheck=1</code>)</li>
    <li>Fingerprint: <code>{html.escape(fpr_fmt)}</code></li>
  </ul>

  <h2>Indexed Packages</h2>
  <table>
    <thead>
      <tr>
        <th>Release</th>
        <th>Package</th>
        <th>Variant</th>
        <th>Repo Arches</th>
        <th>Date</th>
        <th>Signed SHA-256</th>
      </tr>
    </thead>
    <tbody>
      {"".join(rows_html)}
    </tbody>
  </table>
  <p class="meta">Updated {html.escape(built_utc)} &middot; <a href="https://debsahu.github.io/ferric/">FERRIC Documentation &amp; Live WebGPU Demo</a></p>
</body>
</html>
"""
(out_dir / "index.html").write_text(page, encoding="utf-8")
PY

chmod -R a+rX "${OUT_DIR}"
echo "Built signed RPM repository at ${OUT_DIR} (${SIGNED_COUNT} signed RPM files)."

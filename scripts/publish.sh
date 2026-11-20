#!/usr/bin/env bash
# Publish the build output as a GitHub release. Needs gh (GH_TOKEN set) and python3.
#   GITHUB_REPOSITORY=owner/archm scripts/publish.sh [distdir]     (default: dist)
# Optional: KEEP_RELEASES=N deletes all but the newest N releases (and their tags).
set -Eeuo pipefail

DIST=${1:-dist}
REPO=${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY=owner/repo}
cd "$DIST"
ls archm-*.tar.gz >/dev/null            # fail early when nothing was built

base=$(date -u +%Y.%m.%d)
tag=$base
n=0
while gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; do
  n=$((n + 1))
  tag=$base.$n
done
echo "release tag: $tag"

sha256sum archm-*.tar.gz >SHA256SUMS

python3 - "$tag" "$REPO" <<'PY'
import datetime, json, os, sys

tag, repo = sys.argv[1:3]
built = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
assets, rows, details = {}, [], []

for abi in ("arm64", "arm"):                      # the ABIs xyzterm knows
    tgz = f"archm-{abi}.tar.gz"
    if not os.path.exists(tgz):
        continue
    info = dict(line.strip().split("=", 1) for line in open(f"archm-{abi}.info") if "=" in line)
    sha = open(tgz + ".sha256").read().split()[0]
    size = os.path.getsize(tgz)
    arch = info.get("alarm_arch", "?")
    assets[abi] = {
        "file": tgz,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{tgz}",
        "sha256": sha,
        "size": size,
        "alarm_arch": arch,
    }
    rows.append(f"| `{abi}` ({arch}) | `{tgz}` | {size / 1e6:.0f} MB | `{sha}` |")
    details.append(f"- `{abi}`: {info.get('packages', '?')} packages, base tarball "
                   f"`ArchLinuxARM-{arch}-latest.tar.gz` (md5 `{info.get('base_md5', '?')}`)")

if not assets:
    sys.exit("no archm-*.tar.gz found")

with open("manifest.json", "w") as f:
    json.dump({"name": "archm", "tag": tag, "built": built, "assets": assets}, f, indent=2)
    f.write("\n")

notes = f"""Arch Linux ARM rootfs for proot on Android, rebuilt weekly with a full `pacman -Syu`.

| ABI | File | Size | SHA-256 |
|---|---|---|---|
{chr(10).join(rows)}

**xyzterm:** use the URL and SHA-256 of your ABI. Always-latest URLs:
`https://github.com/{repo}/releases/latest/download/archm-arm64.tar.gz` and `.../archm-arm.tar.gz`.
`manifest.json` carries the same data (tag, URLs, SHA-256, size) for scripts.

First command in the new system: `pacman -Syu`

{chr(10).join(details)}
- built {built}; signature of the base tarball verified against key `68B3537F39A313B3E574D06777193F152BDBE6A6`
"""
with open("notes.md", "w") as f:
    f.write(notes)
PY

gh release create "$tag" --repo "$REPO" --title "archm $tag" --notes-file notes.md --latest \
  archm-*.tar.gz archm-*.tar.gz.sha256 archm-*.packages.txt SHA256SUMS manifest.json

if [ "${KEEP_RELEASES:-0}" -gt 0 ] 2>/dev/null; then
  gh release list --repo "$REPO" --limit 200 --json tagName --jq ".[${KEEP_RELEASES}:][].tagName" |
    while read -r old; do
      echo "pruning $old"
      gh release delete "$old" --repo "$REPO" --cleanup-tag --yes
    done
fi

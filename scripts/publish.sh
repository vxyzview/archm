#!/usr/bin/env bash
# Publish the build output as a GitHub release. Needs gh (GH_TOKEN set) and python3.
#   GITHUB_REPOSITORY=owner/archm scripts/publish.sh [distdir]     (default: dist)
# Optional: ARCHM_VERSION=<tag> publishes under exactly that tag, the version the images were
#           built as (the workflow passes it). Without it the tag is today's date (+ .N).
# Optional: KEEP_RELEASES=N deletes all but the newest N releases (and their tags).
set -Eeuo pipefail

DIST=${1:-dist}
REPO=${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY=owner/repo}
cd "$DIST"
ls archm-*.tar.gz >/dev/null            # fail early when nothing was built

# The tag is the version stamped into the images (/etc/archm-release): the workflow works it out
# once and hands it to build.sh and to this script as ARCHM_VERSION, so the two cannot drift.
# Run by hand without it, the tag is today's date, plus .N when that tag is already taken.
if [ -n "${ARCHM_VERSION:-}" ]; then
  tag=$ARCHM_VERSION
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: release $tag already exists" >&2
    exit 1
  fi
  for f in archm-*.info; do
    grep -qx "version=$tag" "$f" || { echo "error: $f was not built as version $tag" >&2; exit 1; }
  done
else
  base=$(date -u +%Y.%m.%d)
  tag=$base
  n=0
  while gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; do
    n=$((n + 1))
    tag=$base.$n
  done
fi
echo "release tag: $tag"

sha256sum archm-*.tar.gz >SHA256SUMS

# Package lists of the release users have right now, for the "changes since" part of the notes.
# Best effort: a first release, or an older one without the files, just has no such section.
prev=$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null || true)
mkdir -p prev
if [ -n "$prev" ]; then
  gh release download "$prev" --repo "$REPO" --pattern 'archm-*.packages.txt' --dir prev >/dev/null 2>&1 || true
fi

python3 - "$tag" "$REPO" "$prev" <<'PY'
import datetime, json, os, sys

tag, repo, prev_tag = sys.argv[1:4]
built = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
assets, rows, details, changes = {}, [], [], []


def packages(path):
    """name -> version from `pacman -Q` output; None when there is no such file."""
    try:
        with open(path) as f:
            lines = [line.split() for line in f]
    except OSError:
        return None
    return {p[0]: p[1] for p in lines if len(p) >= 2}


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
    for key in ("files", "uncompressed_bytes"):         # absent from builds that predate them
        if info.get(key, "").isdigit():
            assets[abi][key] = int(info[key])
    rows.append(f"| `{abi}` ({arch}) | `{tgz}` | {size / 1e6:.0f} MB | `{sha}` |")
    unpacked = ""
    if "uncompressed_bytes" in assets[abi]:
        unpacked = (f", {assets[abi]['files']} files, "
                    f"{assets[abi]['uncompressed_bytes'] / 1e6:.0f} MB unpacked")
    details.append(f"- `{abi}`: {info.get('packages', '?')} packages{unpacked}, base tarball "
                   f"`ArchLinuxARM-{arch}-latest.tar.gz` (md5 `{info.get('base_md5', '?')}`)")
    new = packages(f"archm-{abi}.packages.txt")
    old = packages(f"prev/archm-{abi}.packages.txt") if prev_tag else None
    if new is not None and old is not None:
        changes.append((abi, old, new))

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
if changes:                                            # what a `pacman -Syu` would not have told you
    notes += f"\n## Changes since {prev_tag}\n\n"
    blocks = []
    for abi, old, new in changes:
        updated = sorted(n for n in new if n in old and new[n] != old[n])
        added = sorted(set(new) - set(old))
        removed = sorted(set(old) - set(new))
        notes += f"- `{abi}`: {len(updated)} updated, {len(added)} added, {len(removed)} removed\n"
        lines = ([f"~ {n} {old[n]} -> {new[n]}" for n in updated]
                 + [f"+ {n} {new[n]}" for n in added]
                 + [f"- {n} {old[n]}" for n in removed])
        if lines:
            shown = lines[:150]
            if len(lines) > 150:
                shown.append(f"... and {len(lines) - 150} more")
            blocks.append(f"<details><summary>{abi} package changes</summary>\n\n"
                          "```text\n" + "\n".join(shown) + "\n```\n\n</details>\n")
    notes += "\n" + "\n".join(blocks)
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

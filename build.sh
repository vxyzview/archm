#!/usr/bin/env bash
# archm builder: official Arch Linux ARM tarball -> slim rootfs tuned for proot on Android.
#
#   sudo ./build.sh <arm64|arm> [outdir]          (outdir defaults to ./dist)
#
# Needs a real Linux host with root, curl, gpg, tar, gzip (pigz and bsdtar are used when
# present) and, when the host CPU differs from the target, qemu-user-static with binfmt_misc
# registered. It cannot run inside proot/Termux: chroot and mount need genuine root.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
. "$HERE/config.env"

ALARM_URL=${ALARM_URL:-http://os.archlinuxarm.org/os}
# Arch Linux ARM Build System key: signs the rootfs tarballs and the packages.
# Fingerprint as published on https://archlinuxarm.org/about/downloads
ALARM_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6
VERSION=${ARCHM_VERSION:-$(date -u +%Y.%m.%d)}

log() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done; }

# ABI names follow xyzterm (arm64 / arm); Arch Linux ARM calls them aarch64 / armv7.
set_target() {
  case "${1:-}" in
    arm64) ALARM_ARCH=aarch64 QEMU=qemu-aarch64 NATIVE_UNAME="aarch64" ;;
    arm)   ALARM_ARCH=armv7   QEMU=qemu-arm     NATIVE_UNAME="armv7l armv8l" ;;
    *)     die "ABI must be 'arm64' or 'arm' (got '${1:-}')" ;;
  esac
  ABI=$1
}

# ---------------------------------------------------------------- download + verify

fetch() { curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused -o "$2" "$1"; }

verify_md5() {   # integrity only; authenticity comes from verify_sig
  local want got
  want=$(awk '{print $1; exit}' "$1.md5")
  got=$(md5sum "$1" | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$got" ]
}

recv_key() {
  gpg --batch --list-keys "$ALARM_KEY" >/dev/null 2>&1 && return 0
  local ks
  for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
    if timeout 90 gpg --batch --keyserver "$ks" --recv-keys "$ALARM_KEY" >/dev/null 2>&1; then
      return 0
    fi
  done
  die "could not fetch signing key $ALARM_KEY from any keyserver"
}

verify_sig() {   # $1 = file, $1.sig = detached signature; only the pinned key is accepted
  local status
  export GNUPGHOME=${WORK:?}/gnupg
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  recv_key
  status=$(gpg --batch --status-fd 1 --verify "$1.sig" "$1" 2>/dev/null || true)
  # VALIDSIG <signing-fpr> ... <primary-key-fpr>
  if awk -v k="$ALARM_KEY" '$2 == "VALIDSIG" && ($3 == k || $NF == k) { ok = 1 } END { exit !ok }' <<<"$status"; then
    log "Signature OK: $(basename "$1") signed by $ALARM_KEY"
  else
    log "Signature check FAILED for $(basename "$1")"
    return 1
  fi
}

download_base() {
  local name="ArchLinuxARM-${ALARM_ARCH}-latest.tar.gz" try
  BASE_TAR=$DL/$name
  for try in 1 2 3; do
    log "Downloading $name (attempt $try/3)"
    fetch "$ALARM_URL/$name" "$BASE_TAR" \
      && fetch "$ALARM_URL/$name.md5" "$BASE_TAR.md5" \
      && fetch "$ALARM_URL/$name.sig" "$BASE_TAR.sig" \
      || { sleep 10; continue; }
    # The mirrors behind os.archlinuxarm.org can disagree for a moment while syncing: retry.
    if verify_md5 "$BASE_TAR" && verify_sig "$BASE_TAR"; then
      BASE_MD5=$(md5sum "$BASE_TAR" | awk '{print $1}')
      return 0
    fi
    sleep 10
  done
  die "could not download a verified $name"
}

extract_base() {
  log "Extracting $(basename "$BASE_TAR")"
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xpf "$BASE_TAR" -C "$ROOT"
  else
    tar -xpf "$BASE_TAR" -C "$ROOT" --numeric-owner --warning=no-unknown-keyword
  fi
}

# ---------------------------------------------------------------- chroot plumbing

ensure_emulation() {
  local host bin
  host=$(uname -m)
  case " $NATIVE_UNAME " in *" $host "*) return 0 ;; esac
  log "Target $ALARM_ARCH on a $host host: emulating with $QEMU"
  if [ ! -e "/proc/sys/fs/binfmt_misc/$QEMU" ]; then
    mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
    if command -v update-binfmts >/dev/null 2>&1; then update-binfmts --enable "$QEMU" || true; fi
  fi
  [ -e "/proc/sys/fs/binfmt_misc/$QEMU" ] \
    || die "binfmt handler '$QEMU' is not registered (apt install qemu-user-static binfmt-support)"
  bin=$(command -v "$QEMU-static") || die "$QEMU-static not found (apt install qemu-user-static)"
  # Needed when the handler lacks the F flag; harmless otherwise. Removed again in finalize_rootfs.
  install -Dm755 "$bin" "$ROOT/usr/bin/$QEMU-static"
  QEMU_COPIED=$ROOT/usr/bin/$QEMU-static
}

in_chroot() {
  chroot "$ROOT" /usr/bin/env -i HOME=/root TERM=dumb LANG=C \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin "$@"
}

setup_chroot() {
  ensure_emulation
  install -d "$ROOT/proc" "$ROOT/sys" "$ROOT/dev"
  mount -t proc proc "$ROOT/proc"
  mount --rbind /sys "$ROOT/sys"
  mount --make-rslave "$ROOT/sys"
  mount --rbind /dev "$ROOT/dev"
  mount --make-rslave "$ROOT/dev"
  CHROOT_READY=1
  rm -f "$ROOT/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$ROOT/etc/resolv.conf"
  in_chroot /usr/bin/uname -m >&2 || die "cannot execute the target rootfs (is qemu binfmt registered?)"
}

teardown_chroot() {
  [ "${CHROOT_READY:-0}" = 1 ] || return 0
  local p r
  for p in /proc/[0-9]*; do   # gpg-agent/dirmngr left behind would keep the mounts busy
    r=$(readlink "$p/root" 2>/dev/null) || continue
    if [ "$r" = "$ROOT" ]; then kill "${p#/proc/}" 2>/dev/null || true; fi
  done
  sleep 1
  umount -R -l "$ROOT/dev" "$ROOT/sys" "$ROOT/proc" 2>/dev/null || true
  CHROOT_READY=0
}

assert_unmounted() {   # never pack or delete while a bind mount of the host is still inside
  if grep -q " $ROOT" /proc/self/mountinfo; then
    die "mounts still present under $ROOT; refusing to continue"
  fi
}

# ---------------------------------------------------------------- customize + pack

customize() {
  log "Customizing inside the chroot (the slow part, especially under qemu)"
  install -d "$ROOT/tmp/archm"
  cp "$HERE/config.env" "$HERE/scripts/customize.sh" "$ROOT/tmp/archm/"
  cp -r "$HERE/rootfs-overlay" "$ROOT/tmp/archm/overlay"
  in_chroot env ARCHM_IN_CHROOT=1 ARCHM_VERSION="$VERSION" ARCHM_ABI="$ABI" ARCHM_BASE_MD5="$BASE_MD5" \
    /bin/bash /tmp/archm/customize.sh
}

finalize_rootfs() {
  rm -rf "$ROOT/tmp/archm"
  if [ -n "${QEMU_COPIED:-}" ]; then rm -f "$QEMU_COPIED"; fi
}

# Plain gzip tar, built the way an Android app can unpack it without tricks: numeric owners,
# no xattrs, no device nodes, and no hardlinks (--hard-dereference stores real copies).
pack() {
  local out=$OUT/archm-$ABI.tar.gz gz="gzip -9n"
  if command -v pigz >/dev/null 2>&1; then gz="pigz -9nT"; fi
  log "Packing $(basename "$out")"
  # shellcheck disable=SC2086
  tar -C "$ROOT" --numeric-owner --hard-dereference --sort=name \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
    --exclude='./run/*' --exclude='./tmp/*' \
    -cf - . | $gz >"$out"
  (cd "$OUT" && sha256sum "archm-$ABI.tar.gz" >"archm-$ABI.tar.gz.sha256")
}

write_info() {
  local pk
  pk=$(wc -l <"$OUT/archm-$ABI.packages.txt")
  cat >"$OUT/archm-$ABI.info" <<EOF
abi=$ABI
alarm_arch=$ALARM_ARCH
version=$VERSION
base_md5=$BASE_MD5
packages=${pk//[[:space:]]/}
EOF
}

cleanup() {
  local rc=$?
  set +e
  teardown_chroot
  if [ -n "${WORK:-}" ] && [ "${KEEP_WORK:-0}" != 1 ]; then
    if grep -q " $WORK" /proc/self/mountinfo; then
      echo "WARNING: mounts still present under $WORK; leaving it alone" >&2
    else
      rm -rf --one-file-system "$WORK"
    fi
  fi
  exit "$rc"
}

main() {
  [ $# -ge 1 ] || die "usage: sudo $0 <arm64|arm> [outdir]"
  set_target "$1"
  [ "$(id -u)" -eq 0 ] || die "run as root (chroot and mount need it)"
  need curl gpg tar gzip mount umount chroot md5sum sha256sum awk sed timeout
  OUT=$(realpath -m "${2:-dist}")
  WORK=$(mktemp -d /var/tmp/archm-build.XXXXXX)
  DL=$WORK/dl
  ROOT=$WORK/rootfs
  mkdir -p "$DL" "$ROOT" "$OUT"
  trap cleanup EXIT
  trap 'echo "error: build.sh failed at line $LINENO" >&2' ERR

  download_base
  extract_base
  setup_chroot
  customize
  in_chroot pacman -Q >"$OUT/archm-$ABI.packages.txt"
  teardown_chroot
  assert_unmounted
  finalize_rootfs
  pack
  write_info
  if [ -n "${SUDO_UID:-}" ]; then chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"; fi
  log "Done"
  ls -lh "$OUT"/archm-"$ABI".* >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

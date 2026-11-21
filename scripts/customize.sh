#!/bin/bash
# Runs INSIDE the Arch Linux ARM rootfs (chroot, usually under qemu-user). Called by build.sh.
# Every step is a function and honours $ROOT (empty inside the chroot), so tests/run.sh can
# exercise the text-editing steps against a fixture directory.
set -Eeuo pipefail

ROOT=${ROOT:-}
CFG=${ARCHM_CFG:-/tmp/archm/config.env}
OVERLAY=${ARCHM_OVERLAY:-/tmp/archm/overlay}

log() { printf '\n\033[1;35m[archm]\033[0m %s\n' "$*"; }
retry() { local n; for n in 1 2 3; do if "$@"; then return 0; fi; log "retry $n/3: $*"; sleep 10; done; return 1; }

# pacman must work under proot: no download sandbox (needs Landlock/seccomp, which Android
# kernels and proot do not offer), no CheckSpace (reads mount info proot can't provide).
patch_pacman_conf() {
  local conf=$ROOT/etc/pacman.conf blk=$ROOT/etc/pacman.conf.archm
  [ -f "$conf" ] || { echo "missing $conf" >&2; return 1; }
  sed -i '/^# >>> archm/,/^# <<< archm/d' "$conf"          # idempotent
  sed -i -E \
    -e 's/^[[:space:]]*(CheckSpace)/#\1/' \
    -e 's/^[[:space:]]*(DownloadUser)/#\1/' \
    -e 's/^#(Color)[[:space:]]*$/\1/' \
    -e 's/^#(ParallelDownloads)[[:space:]]*=.*/\1 = 5/' \
    "$conf"
  {
    echo '# >>> archm (proot tuning)'
    echo '# proot cannot provide the Landlock/seccomp sandbox pacman uses for downloads.'
    echo 'DisableSandbox'
    if [ "${SLIM:-1}" = 1 ]; then
      # In each line the "!" exceptions must come after the glob they carve out of: pacman lets
      # the last matching pattern win (tests/run.sh checks this against a real pacman).
      echo '# slim image: no docs, no non-English translations. Delete these three lines to get them.'
      echo 'NoExtract = usr/share/doc/* usr/share/gtk-doc/* usr/share/help/* usr/share/info/*'
      echo 'NoExtract = usr/share/locale/* !usr/share/locale/en* !usr/share/locale/locale.alias'
      echo 'NoExtract = usr/share/man/* !usr/share/man/man*'
    fi
    echo '# <<< archm'
  } >"$blk"
  sed -i "/^\[options\]/r $blk" "$conf"
  rm -f "$blk"
}

init_keyring() {
  pacman-key --init
  pacman-key --populate archlinuxarm
  # Locally sign the package-signing key so packages verify after --populate under proot.
  # --populate marks master keys trusted but subkey trust can still be "unknown" on arm.
  pacman-key --lsign-key builder@archlinuxarm.org 2>/dev/null || true
}

upgrade_system() {
  local p want=""
  # Keyring first: a stale keyring in the tarball is the classic "unknown trust" failure.
  retry pacman -Sy --noconfirm archlinuxarm-keyring
  pacman-key --populate archlinuxarm
  retry pacman -Su --noconfirm
  for p in $EXTRA_PKGS; do
    if pacman -Si "$p" >/dev/null 2>&1; then want+=" $p"; else log "skipping $p: not in the repos"; fi
  done
  if [ -n "$want" ]; then
    # shellcheck disable=SC2086
    retry pacman -S --needed --noconfirm $want
  fi
}

strip_kernel() {
  local list
  list=$(pacman -Qq | grep -E "$REMOVE_REGEX" || true)
  if [ -n "$list" ]; then
    log "Removing: $(echo $list)"
    # -dd: skip dependency checks (nothing we keep needs them); -n: leave no .pacsave files
    # shellcheck disable=SC2086
    pacman -Rddn --noconfirm $list
    rm -rf "$ROOT"/usr/lib/modules/*      # depmod output the kernel package did not own
  fi
  find "$ROOT/boot" -mindepth 1 -delete 2>/dev/null || true
}

install_overlay() {
  cp -rT --no-preserve=ownership "$OVERLAY" "${ROOT:-/}"
  if ! grep -qs 'archm/bashrc' "$ROOT/etc/bash.bashrc"; then
    printf '\n# archm\n[ -r /etc/archm/bashrc ] && . /etc/archm/bashrc\n' >>"$ROOT/etc/bash.bashrc"
  fi
  if [ -f "$ROOT/etc/makepkg.conf" ]; then
    sed -i -E 's|^#?MAKEFLAGS=.*|MAKEFLAGS="-j$(nproc)"|' "$ROOT/etc/makepkg.conf"
  fi
}

# Hooks that rebuild hardware databases are slow under proot and useless there. Hooks in
# /etc/pacman.d/hooks override same-named ones in /usr/share/libalpm/hooks; /dev/null disables.
mask_hooks() {
  local h
  install -d "$ROOT/etc/pacman.d/hooks"
  for h in "$ROOT"/usr/share/libalpm/hooks/*hwdb*.hook "$ROOT"/usr/share/libalpm/hooks/*udev*.hook; do
    if [ -e "$h" ]; then ln -sf /dev/null "$ROOT/etc/pacman.d/hooks/${h##*/}"; fi
  done
}

configure_system() {
  local loc=${LOCALE:-en_US.UTF-8} g
  # pacman requires these dirs; the arm64 base tarball ships them as absent in some versions.
  install -d "$ROOT/var/lib/pacman/local" "$ROOT/var/lib/pacman/sync"
  echo archm >"$ROOT/etc/hostname"
  printf '127.0.0.1 localhost\n::1 localhost\n' >"$ROOT/etc/hosts"
  rm -f "$ROOT/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$ROOT/etc/resolv.conf"
  : >"$ROOT/etc/machine-id"
  printf '# unused under proot\n' >"$ROOT/etc/fstab"

  sed -i -E "s/^#(${loc} )/\1/" "$ROOT/etc/locale.gen"
  locale-gen
  printf 'LANG=%s\n' "$loc" >"$ROOT/etc/locale.conf"
  ln -sf "/usr/share/zoneinfo/${TIMEZONE:-UTC}" "$ROOT/etc/localtime"

  # No default credentials: the stock image ships alarm/alarm and root/root.
  if getent passwd alarm >/dev/null; then userdel -r alarm >/dev/null 2>&1 || userdel alarm; fi
  if getent group alarm >/dev/null; then groupdel alarm || true; fi
  passwd -l root >/dev/null

  # Android group names, so `id` and `ls -l` don't print "cannot find name for group ID".
  for g in sdcard_rw:1015 media_rw:1023 sdcard_r:1028 net_bt_admin:3001 net_bt:3002 \
           inet:3003 net_raw:3004 net_admin:3005 everybody:9997 misc:9998 nobody:9999; do
    if ! grep -q ":${g#*:}:" "$ROOT/etc/group"; then echo "aid_${g%%:*}:x:${g#*:}:" >>"$ROOT/etc/group"; fi
  done
}

slim_down() {
  [ "${SLIM:-1}" = 1 ] || return 0
  rm -rf "$ROOT"/usr/share/doc/* "$ROOT"/usr/share/gtk-doc/* "$ROOT"/usr/share/help/* "$ROOT"/usr/share/info/*
  find "$ROOT/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name locale.alias \
    -exec rm -rf {} + 2>/dev/null || true
  # Translated man pages live in usr/share/man/<lang>/; man1, man5, ... stay.
  find "$ROOT/usr/share/man" -mindepth 1 -maxdepth 1 ! -name 'man*' \
    -exec rm -rf {} + 2>/dev/null || true
  # The systemd hook generated hwdb.bin (a sizeable file) before mask_hooks disabled that hook;
  # nothing under proot reads it, and with the hook masked it would only go stale.
  rm -f "$ROOT/usr/lib/udev/hwdb.bin" "$ROOT/etc/udev/hwdb.bin"
}

write_release() {
  {
    echo "NAME=archm"
    echo "VERSION=${ARCHM_VERSION:-dev}"
    echo "ABI=${ARCHM_ABI:-unknown}"
    echo "BASE_TARBALL_MD5=${ARCHM_BASE_MD5:-unknown}"
    echo "BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$ROOT/etc/archm-release"
}

# Nothing that is machine-specific or build-only may end up in the tarball.
clean_up() {
  gpgconf --homedir "$ROOT/etc/pacman.d/gnupg" --kill all >/dev/null 2>&1 || true
  rm -f "$ROOT"/etc/pacman.d/gnupg/S.* "$ROOT"/etc/pacman.d/gnupg/.#* \
        "$ROOT"/etc/ssh/ssh_host_* "$ROOT"/var/lib/systemd/random-seed
  rm -rf "$ROOT"/var/cache/pacman/pkg/* "$ROOT"/var/lib/pacman/sync/*
  find "$ROOT/var/log" -type f -delete 2>/dev/null || true
  find "$ROOT/root" "$ROOT/run" "$ROOT/var/tmp" -mindepth 1 -delete 2>/dev/null || true
  find "$ROOT/tmp" -mindepth 1 -maxdepth 1 ! -name archm -exec rm -rf {} + 2>/dev/null || true   # build.sh removes tmp/archm
}

main() {
  if [ -z "$ROOT" ] && [ "${ARCHM_IN_CHROOT:-}" != 1 ]; then
    echo "refusing to run outside the build chroot" >&2
    exit 1
  fi
  # shellcheck source=../config.env
  . "$CFG"
  patch_pacman_conf
  init_keyring
  strip_kernel      # before the upgrade: no kernel download, no initramfs hooks under qemu
  mask_hooks        # same reason: no hwdb rebuild during the upgrade (slow under qemu, useless here)
  upgrade_system
  strip_kernel      # safety net in case the upgrade pulled any of it back in
  install_overlay
  mask_hooks        # again: the upgrade may have installed hook files that did not exist before
  configure_system
  slim_down
  write_release
  clean_up
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

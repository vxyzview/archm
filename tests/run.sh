#!/usr/bin/env bash
# Offline tests for everything that can run without network, chroot, qemu or proot.
# (The chroot build and the proot smoke test are exercised by CI itself.)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD
T=$(mktemp -d)
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$T"' EXIT

passed=0
failed=0
assert() { if ! "$@"; then echo "assertion failed: $*" >&2; exit 1; fi; }
t() {   # t <name> <function>: run in a subshell, report, keep going
  local name=$1; shift
  if ( "$@" ) >"$T/out.log" 2>&1; then
    passed=$((passed + 1)); printf '  ok    %s\n' "$name"
  else
    failed=$((failed + 1)); printf '  FAIL  %s\n' "$name"; sed 's/^/        | /' "$T/out.log"
  fi
}

# ------------------------------------------------------------------ tests

test_syntax() {
  local f
  for f in build.sh config.env scripts/*.sh tests/*.sh extras/start-archm.sh \
           rootfs-overlay/etc/profile.d/archm.sh rootfs-overlay/etc/archm/bashrc; do
    bash -n "$f" || { echo "syntax error in $f"; exit 1; }
  done
  python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/release.yml"))'
  # every script the workflow calls must exist
  for f in $(grep -o '\(scripts\|tests\)/[a-z-]*\.sh' .github/workflows/release.yml | sort -u) build.sh; do
    [ -f "$f" ] || { echo "workflow references missing $f"; exit 1; }
  done
}

test_target() {
  source "$REPO/build.sh"
  set_target arm64; [ "$ALARM_ARCH $QEMU $ABI" = "aarch64 qemu-aarch64 arm64" ] || exit 1
  set_target arm;   [ "$ALARM_ARCH $QEMU $ABI" = "armv7 qemu-arm arm" ] || exit 1
  if ( set_target nope ) 2>/dev/null; then echo "bad ABI accepted"; exit 1; fi
}

test_remove_regex() {
  . "$REPO/config.env"
  local p
  for p in linux-aarch64 linux-aarch64-headers linux-armv7 linux-armv7-headers linux-firmware \
           linux-firmware-whence uboot-tools mkinitcpio mkinitcpio-busybox; do
    echo "$p" | grep -Eq "$REMOVE_REGEX" || { echo "should be removed: $p"; exit 1; }
  done
  for p in linux-api-headers glibc bash systemd pacman util-linux openssh linux-tools kmod; do
    if echo "$p" | grep -Eq "$REMOVE_REGEX"; then echo "must be kept: $p"; exit 1; fi
  done
}

test_md5() {
  source "$REPO/build.sh"
  echo hello >"$T/f"
  printf '%s  f\n' "$(md5sum "$T/f" | cut -d' ' -f1)" >"$T/f.md5"
  assert verify_md5 "$T/f"
  echo 00000000000000000000000000000000 >"$T/f.md5"
  if verify_md5 "$T/f"; then echo "bad md5 accepted"; exit 1; fi
}

test_signature() {
  source "$REPO/build.sh"
  WORK=$T/sig
  mkdir -p "$WORK/gnupg"; chmod 700 "$WORK/gnupg"
  export GNUPGHOME=$WORK/gnupg
  local g="gpg --batch --quiet --pinentry-mode loopback --passphrase ''"
  eval "$g --quick-generate-key 'archm test one <one@example.invalid>' default default never" 2>/dev/null
  eval "$g --quick-generate-key 'archm test two <two@example.invalid>' default default never" 2>/dev/null
  local one two
  one=$(gpg --batch --with-colons --list-keys one@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')
  two=$(gpg --batch --with-colons --list-keys two@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')
  echo payload >"$WORK/file"
  eval "$g --local-user $one --detach-sign -o '$WORK/file.sig' '$WORK/file'" 2>/dev/null

  ALARM_KEY=$one
  assert verify_sig "$WORK/file"                                   # right key, intact file
  ALARM_KEY=$two
  if verify_sig "$WORK/file"; then echo "signature by a different key accepted"; exit 1; fi
  ALARM_KEY=$one
  echo tampered >>"$WORK/file"
  if verify_sig "$WORK/file"; then echo "tampered file accepted"; exit 1; fi
}

fixture_pacman_conf() {
  cat <<'EOF'
#
# /etc/pacman.conf
#
[options]
#RootDir     = /
#DBPath      = /var/lib/pacman/
HoldPkg     = pacman glibc
Architecture = aarch64

#NoUpgrade   =
#NoExtract   =

# Misc options
#UseSyslog
#Color
#NoProgressBar
CheckSpace
#VerbosePkgLists
#ParallelDownloads = 5
DownloadUser = alpm
SigLevel    = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
}

test_pacman_conf() {
  source "$REPO/scripts/customize.sh"
  ROOT=$T/pc
  mkdir -p "$ROOT/etc"
  local c=$ROOT/etc/pacman.conf
  fixture_pacman_conf >"$c"
  SLIM=1
  patch_pacman_conf
  patch_pacman_conf                                                 # must be idempotent
  [ "$(grep -c '^DisableSandbox$' "$c")" = 1 ] || { echo "DisableSandbox count wrong"; exit 1; }
  assert grep -qx 'Color' "$c"
  assert grep -qx 'ParallelDownloads = 5' "$c"
  assert grep -qx '#CheckSpace' "$c"
  assert grep -qx '#DownloadUser = alpm' "$c"
  assert grep -q '^NoExtract = usr/share/locale/\* !usr/share/locale/en\*' "$c"
  [ "$(sed -n '/^\[options\]/{n;p}' "$c")" = '# >>> archm (proot tuning)' ] || { echo "block not after [options]"; exit 1; }
  assert grep -qx '\[core\]' "$c"
  assert grep -qx '\[extra\]' "$c"
  fixture_pacman_conf >"$c"                                         # SLIM=0 keeps stock layout
  SLIM=0
  patch_pacman_conf
  if grep -q '^NoExtract' "$c"; then echo "NoExtract present with SLIM=0"; exit 1; fi
  assert grep -qx 'DisableSandbox' "$c"
}

test_overlay() {
  source "$REPO/scripts/customize.sh"
  ROOT=$T/ov
  OVERLAY=$REPO/rootfs-overlay
  mkdir -p "$ROOT/etc"
  printf '[[ $- != *i* ]] && return\nPS1="old"\n' >"$ROOT/etc/bash.bashrc"
  printf '#MAKEFLAGS="-j2"\n' >"$ROOT/etc/makepkg.conf"
  install_overlay
  install_overlay
  assert test -f "$ROOT/etc/profile.d/archm.sh"
  assert test -f "$ROOT/etc/archm/bashrc"
  [ "$(grep -c 'archm/bashrc' "$ROOT/etc/bash.bashrc")" = 1 ] || { echo "bashrc hook duplicated"; exit 1; }
  assert grep -qxF 'MAKEFLAGS="-j$(nproc)"' "$ROOT/etc/makepkg.conf"
}

test_shell_overlay() {
  local out
  out=$(bash --norc --noprofile -ic ". '$REPO/rootfs-overlay/etc/archm/bashrc'; echo \"\$PS1|\$HISTSIZE\"" 2>/dev/null)
  case $out in *archm*'|5000') ;; *) echo "bashrc gave: $out"; exit 1 ;; esac
  # profile.d must work in plain POSIX sh too (and set the env without forking)
  out=$(env -i PATH="$PATH" sh -c ". '$REPO/rootfs-overlay/etc/profile.d/archm.sh'; echo \"\$COLORTERM \$TERM \$TMPDIR\"")
  [ "$out" = "truecolor xterm-256color /tmp" ] || { echo "profile.d gave: $out"; exit 1; }
  # an existing TERM from the launcher must win
  out=$(env -i PATH="$PATH" TERM=foot sh -c ". '$REPO/rootfs-overlay/etc/profile.d/archm.sh'; echo \"\$TERM\"")
  [ "$out" = foot ] || { echo "TERM overridden: $out"; exit 1; }
}

test_hooks() {
  source "$REPO/scripts/customize.sh"
  ROOT=$T/hk
  local d=$ROOT/usr/share/libalpm/hooks h=$ROOT/etc/pacman.d/hooks
  mkdir -p "$d"
  : >"$d/30-systemd-hwdb.hook"; : >"$d/30-systemd-udev-reload.hook"
  : >"$d/20-systemd-sysusers.hook"; : >"$d/21-systemd-tmpfiles.hook"
  mask_hooks
  [ "$(readlink "$h/30-systemd-hwdb.hook")" = /dev/null ] || { echo "hwdb hook not masked"; exit 1; }
  [ "$(readlink "$h/30-systemd-udev-reload.hook")" = /dev/null ] || { echo "udev hook not masked"; exit 1; }
  for f in 20-systemd-sysusers.hook 21-systemd-tmpfiles.hook; do   # these create users/dirs: keep
    if [ -e "$h/$f" ] || [ -L "$h/$f" ]; then echo "$f must stay active"; exit 1; fi
  done
}

test_pack() {
  source "$REPO/build.sh"
  ROOT=$T/pk/rootfs
  OUT=$T/pk/out
  ABI=arm64
  mkdir -p "$ROOT"/{etc,usr/bin,dev,proc,sys,run,tmp,root} "$OUT"
  echo data >"$ROOT/usr/bin/a"
  ln "$ROOT/usr/bin/a" "$ROOT/usr/bin/b"          # hardlink: must become a real copy
  ln -s a "$ROOT/usr/bin/c"                        # symlink: must stay a symlink
  echo x >"$ROOT/dev/leftover"; echo x >"$ROOT/tmp/junk"; echo x >"$ROOT/run/junk"
  pack >/dev/null 2>&1
  local tgz=$OUT/archm-arm64.tar.gz list
  (cd "$OUT" && sha256sum -c archm-arm64.tar.gz.sha256 >/dev/null)
  list=$(tar -tvzf "$tgz")
  if grep -q ' link to ' <<<"$list"; then echo "hardlink entries in archive"; exit 1; fi
  grep -q 'usr/bin/c -> a' <<<"$list" || { echo "symlink lost"; exit 1; }
  if grep -Eq 'dev/leftover|tmp/junk|run/junk' <<<"$list"; then echo "excluded content packed"; exit 1; fi
  grep -q ' \./dev/$' <<<"$list" || { echo "empty /dev dir missing"; exit 1; }
  grep -q ' \./root/$' <<<"$list" || { echo "/root dir missing"; exit 1; }
  mkdir "$T/pk/x"
  tar -xzf "$tgz" -C "$T/pk/x"
  [ "$(cat "$T/pk/x/usr/bin/b")" = data ] || { echo "hardlink content lost"; exit 1; }
}

test_publish() {
  local d=$T/pub abi
  mkdir -p "$d/dist" "$d/bin"
  for abi in arm64 arm; do
    head -c 4096 /dev/urandom >"$d/dist/archm-$abi.tar.gz"
    (cd "$d/dist" && sha256sum "archm-$abi.tar.gz" >"archm-$abi.tar.gz.sha256")
    echo pkg >"$d/dist/archm-$abi.packages.txt"
    printf 'abi=%s\nalarm_arch=%s\nversion=x\nbase_md5=abc123\npackages=321\n' \
      "$abi" "$([ "$abi" = arm64 ] && echo aarch64 || echo armv7)" >"$d/dist/archm-$abi.info"
  done
  cat >"$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$GH_LOG"
case "$1 $2" in
  "release view") [ "$3" = "$GH_EXISTING" ] && exit 0; exit 1 ;;   # pretend today's tag exists
  "release list") printf 'old1\nold2\n'; exit 0 ;;                  # what --jq would print
esac
exit 0
EOF
  chmod +x "$d/bin/gh"
  export PATH=$d/bin:$PATH GH_LOG=$d/gh.log GITHUB_REPOSITORY=me/archm KEEP_RELEASES=2
  export GH_EXISTING=$(date -u +%Y.%m.%d)
  bash "$REPO/scripts/publish.sh" "$d/dist" >/dev/null

  local tag=$GH_EXISTING.1
  grep -q "^release create $tag --repo me/archm --title archm $tag --notes-file notes.md --latest archm-arm.tar.gz archm-arm64.tar.gz" "$d/gh.log" \
    || { echo "unexpected release create call:"; cat "$d/gh.log"; exit 1; }
  grep -q 'SHA256SUMS manifest.json$' "$d/gh.log" || { echo "assets missing from release create"; exit 1; }
  grep -q '^release delete old1 --repo me/archm --cleanup-tag --yes' "$d/gh.log" || { echo "prune did not run"; exit 1; }
  python3 - "$d/dist" "$tag" <<'PY'
import json, sys
d, tag = sys.argv[1:3]
m = json.load(open(f"{d}/manifest.json"))
assert m["tag"] == tag and m["name"] == "archm", m
a = m["assets"]
assert list(a) == ["arm64", "arm"], list(a)
assert a["arm64"]["url"] == f"https://github.com/me/archm/releases/download/{tag}/archm-arm64.tar.gz"
assert len(a["arm64"]["sha256"]) == 64 and a["arm64"]["size"] == 4096
assert a["arm"]["alarm_arch"] == "armv7" and a["arm64"]["alarm_arch"] == "aarch64"
notes = open(f"{d}/notes.md").read()
assert a["arm64"]["sha256"] in notes and "archm-arm.tar.gz" in notes and "321 packages" in notes
PY
}

# ------------------------------------------------------------------ run

echo "archm tests"
t "scripts parse, workflow is valid YAML"   test_syntax
t "ABI mapping arm64/arm"                    test_target
t "kernel/firmware regex"                    test_remove_regex
t "md5 verification"                         test_md5
t "GPG: pinned key only, tamper detected"    test_signature
t "pacman.conf patch (idempotent, SLIM)"     test_pacman_conf
t "overlay install + makepkg flags"          test_overlay
t "login/interactive shell overlay"          test_shell_overlay
t "pacman hook masking"                      test_hooks
t "tarball: no hardlinks, excludes, hash"    test_pack
t "release: tag, manifest, notes, prune"     test_publish
t "e2e: real build.sh+customize.sh, fake chroot"  bash tests/e2e-fake.sh "$T/e2e-run"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

#!/usr/bin/env bash
# Runs the REAL build.sh and scripts/customize.sh end to end, with the system-level pieces
# faked: a local "mirror" with a locally signed tarball, stub mount/chroot/pacman/etc.
# Proves the orchestration (download -> verify -> extract -> customize -> pack) is wired
# correctly. It cannot prove pacman, qemu or proot behave; CI does that.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=${1:-$(mktemp -d)}
E=$T/e2e
mkdir -p "$E"/{bin,mirror,state,out}
export E2E_LOG=$E/calls.log E2E_STATE=$E/state
: >"$E2E_LOG"
REAL_GPG=$(command -v gpg)
export REAL_GPG

# ---- signing key standing in for the Arch Linux ARM build key
export GNUPGHOME=$E/gnupg-test
mkdir -m 700 "$GNUPGHOME"
"$REAL_GPG" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'fake alarm <alarm@example.invalid>' default default never 2>/dev/null
FPR=$("$REAL_GPG" --batch --with-colons --list-keys alarm@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')
"$REAL_GPG" --batch --armor --export "$FPR" >"$E/test.pub"
export PUBKEY=$E/test.pub
unset GNUPGHOME

# ---- a miniature Arch Linux ARM rootfs, with the things customize.sh must fix
r=$E/fakeroot
mkdir -p "$r"/etc/{pacman.d/gnupg,ssh,profile.d} "$r"/usr/{bin,lib/modules/6.1,share/{doc/foo,info,gtk-doc,locale/{de/LC_MESSAGES,fr,en_GB},libalpm/hooks}} \
  "$r"/var/{cache/pacman/pkg,lib/pacman/sync,lib/systemd,log,tmp} "$r"/{boot,root,run,tmp,proc,sys,dev}
ln -s usr/bin "$r/bin"
cat >"$r/etc/pacman.conf" <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
#Color
CheckSpace
#ParallelDownloads = 5
DownloadUser = alpm
SigLevel    = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mirrorlist
EOF
printf '[[ $- != *i* ]] && return\nPS1="[\\u@\\h \\W]\\$ "\n' >"$r/etc/bash.bashrc"
printf '#MAKEFLAGS="-j2"\n' >"$r/etc/makepkg.conf"
printf '#de_DE.UTF-8 UTF-8\n#en_US.UTF-8 UTF-8\n' >"$r/etc/locale.gen"
printf 'root:x:0:\nalarm:x:1000:\nnobody:x:65534:\n' >"$r/etc/group"
echo stale >"$r/etc/hostname"
echo 'nameserver 192.168.1.1' >"$r/etc/resolv.conf"
: >"$r/usr/share/libalpm/hooks/30-systemd-hwdb.hook"
: >"$r/usr/share/libalpm/hooks/20-systemd-sysusers.hook"
echo x >"$r/boot/Image"; echo x >"$r/usr/lib/modules/6.1/modules.dep"
echo x >"$r/usr/share/doc/foo/README"; echo x >"$r/usr/share/info/dir"
echo x >"$r/usr/share/locale/de/LC_MESSAGES/a.mo"; echo x >"$r/usr/share/locale/fr/b.mo"
echo x >"$r/usr/share/locale/en_GB/c.mo"; echo x >"$r/usr/share/locale/locale.alias"
echo x >"$r/etc/pacman.d/gnupg/S.gpg-agent"; echo x >"$r/etc/ssh/ssh_host_ed25519_key"
echo x >"$r/root/.bash_history"; echo x >"$r/tmp/leftover"; echo x >"$r/var/log/pacman.log"
echo x >"$r/var/cache/pacman/pkg/big.pkg.tar.zst"; echo x >"$r/var/lib/pacman/sync/core.db"

tar -C "$r" -czf "$E/mirror/ArchLinuxARM-aarch64-latest.tar.gz" .
(cd "$E/mirror" && md5sum ArchLinuxARM-aarch64-latest.tar.gz >ArchLinuxARM-aarch64-latest.tar.gz.md5)
BASE_MD5=$(cut -d' ' -f1 "$E/mirror/ArchLinuxARM-aarch64-latest.tar.gz.md5")
GNUPGHOME=$E/gnupg-test "$REAL_GPG" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --detach-sign -o "$E/mirror/ArchLinuxARM-aarch64-latest.tar.gz.sig" "$E/mirror/ArchLinuxARM-aarch64-latest.tar.gz"
gpgconf --homedir "$E/gnupg-test" --kill all >/dev/null 2>&1 || true

# ---- stubs
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$E/bin/$1"; chmod +x "$E/bin/$1"; }
stub gpg   'for a in "$@"; do [ "$a" = --recv-keys ] && exec "$REAL_GPG" --batch --import "$PUBKEY" 2>/dev/null; done; exec "$REAL_GPG" "$@"'
stub uname '[ "${1:-}" = -m ] && echo aarch64 || exec /usr/bin/uname "$@"'
stub id    '[ "${1:-}" = -u ] && echo 0 || exec /usr/bin/id "$@"'
stub mount      'echo "mount $*" >>"$E2E_LOG"'
stub umount     'echo "umount $*" >>"$E2E_LOG"'
stub mountpoint 'exit 0'
stub sleep      'exit 0'
stub pacman-key 'echo "pacman-key $*" >>"$E2E_LOG"'
stub locale-gen 'echo "locale-gen" >>"$E2E_LOG"'
stub userdel    'echo "userdel $*" >>"$E2E_LOG"'
stub groupdel   'echo "groupdel $*" >>"$E2E_LOG"'
stub passwd     'echo "passwd $*" >>"$E2E_LOG"'
stub getent     'exit 0'
stub pacman '
echo "pacman $*" >>"$E2E_LOG"
case "$1" in
  -Qq) printf "%s\n" bash glibc openssh
       [ -e "$E2E_STATE/removed" ] || printf "%s\n" linux-aarch64 linux-aarch64-headers linux-firmware mkinitcpio uboot-tools ;;
  -Q)  printf "bash 5.2-1\nglibc 2.40-1\nopenssh 9.9-1\n" ;;
  -Si) [ "$2" != fastfetch ] ;;                       # pretend fastfetch is missing from the repos
  -Rddn) touch "$E2E_STATE/removed" ;;
esac'
# fake chroot: run the target command with the fake rootfs standing in for "/"
stub chroot '
root=$1; shift
[ "$1" = /usr/bin/env ] && shift; [ "$1" = -i ] && shift
while [[ "$1" == *=* ]]; do shift; done
case "$1" in
  /usr/bin/uname) echo aarch64 ;;
  pacman) "$@" ;;
  env) shift; envs=(); while [[ "$1" == *=* ]]; do envs+=("$1"); shift; done
       env "${envs[@]}" ROOT="$root" ARCHM_CFG="$root/tmp/archm/config.env" ARCHM_OVERLAY="$root/tmp/archm/overlay" \
         bash "$root$2" ;;
  *) echo "unexpected chroot command: $*" >&2; exit 99 ;;
esac'

# ---- run the real thing; only the pinned key differs from production
cp -r "$REPO" "$E/repo"
sed -i "s/^ALARM_KEY=.*/ALARM_KEY=$FPR/" "$E/repo/build.sh"
(cd "$E/repo" && PATH=$E/bin:$PATH ALARM_URL=file://$E/mirror ARCHM_VERSION=2099.01.01 \
   bash build.sh arm64 "$E/out") >"$E/build.log" 2>&1 || { cat "$E/build.log"; echo "build.sh failed"; exit 1; }

# ---- what must have come out
out=$E/out
for f in archm-arm64.tar.gz archm-arm64.tar.gz.sha256 archm-arm64.packages.txt archm-arm64.info; do
  [ -s "$out/$f" ] || { echo "missing output $f"; exit 1; }
done
(cd "$out" && sha256sum -c archm-arm64.tar.gz.sha256 >/dev/null)
grep -qx 'packages=3' "$out/archm-arm64.info" || { echo "info: wrong package count"; cat "$out/archm-arm64.info"; exit 1; }
grep -qx "base_md5=$BASE_MD5" "$out/archm-arm64.info" || { echo "info: wrong base md5"; exit 1; }

x=$E/x
mkdir "$x"
tar -xzpf "$out/archm-arm64.tar.gz" -C "$x"
chk() { local what=$1; shift; "$@" || { echo "ROOTFS CHECK FAILED: $what"; exit 1; }; }
chk "DisableSandbox set"        grep -qx DisableSandbox "$x/etc/pacman.conf"
chk "CheckSpace disabled"       grep -qx '#CheckSpace' "$x/etc/pacman.conf"
chk "hostname"                  grep -qx archm "$x/etc/hostname"
chk "static DNS"                grep -qx 'nameserver 1.1.1.1' "$x/etc/resolv.conf"
chk "locale enabled"            grep -qx 'en_US.UTF-8 UTF-8' "$x/etc/locale.gen"
chk "LANG written"              grep -qx 'LANG=en_US.UTF-8' "$x/etc/locale.conf"
chk "UTC localtime"             test "$(readlink "$x/etc/localtime")" = /usr/share/zoneinfo/UTC
chk "android groups added"      grep -qx 'aid_inet:x:3003:' "$x/etc/group"
chk "alarm group untouched by groups loop" grep -q '^alarm:' "$x/etc/group"
chk "hwdb hook masked"          test "$(readlink "$x/etc/pacman.d/hooks/30-systemd-hwdb.hook")" = /dev/null
chk "sysusers hook active"      test ! -e "$x/etc/pacman.d/hooks/20-systemd-sysusers.hook"
chk "overlay installed"         test -f "$x/etc/profile.d/archm.sh"
chk "bash.bashrc hooked"        grep -q 'archm/bashrc' "$x/etc/bash.bashrc"
chk "makepkg flags"             grep -qxF 'MAKEFLAGS="-j$(nproc)"' "$x/etc/makepkg.conf"
chk "release file"              grep -qx 'VERSION=2099.01.01' "$x/etc/archm-release"
chk "release file md5"          grep -qx "BASE_TARBALL_MD5=$BASE_MD5" "$x/etc/archm-release"
for gone in boot/Image usr/lib/modules/6.1/modules.dep usr/share/doc/foo usr/share/info/dir \
            usr/share/locale/de usr/share/locale/fr etc/pacman.d/gnupg/S.gpg-agent \
            etc/ssh/ssh_host_ed25519_key root/.bash_history tmp/leftover tmp/archm var/log/pacman.log \
            var/cache/pacman/pkg/big.pkg.tar.zst var/lib/pacman/sync/core.db; do
  chk "removed: $gone" test ! -e "$x/$gone"
done
chk "kept en_GB locale"         test -e "$x/usr/share/locale/en_GB/c.mo"
chk "kept locale.alias"         test -e "$x/usr/share/locale/locale.alias"
for d in dev proc sys; do chk "empty /$d" test -z "$(ls -A "$x/$d")"; done
chk "/bin symlink preserved"    test "$(readlink "$x/bin")" = usr/bin

# ---- what must have been asked of pacman, and in which order
log=$E2E_LOG
chk "pacman-key init+populate"  grep -q '^pacman-key --init' "$log"
chk "locale-gen ran"            grep -qx locale-gen "$log"
chk "root locked"               grep -q '^passwd -l root' "$log"
chk "alarm user removed"        grep -q '^userdel' "$log"
chk "kernel removed once"       test "$(grep -c '^pacman -Rddn --noconfirm linux-aarch64 linux-aarch64-headers linux-firmware mkinitcpio uboot-tools$' "$log")" = 1
rm_line=$(grep -n '^pacman -Rddn' "$log" | head -1 | cut -d: -f1)
up_line=$(grep -n '^pacman -Su --noconfirm' "$log" | head -1 | cut -d: -f1)
chk "kernel removed BEFORE upgrade" test "$rm_line" -lt "$up_line"
chk "keyring refreshed first"   grep -q '^pacman -Sy --noconfirm archlinuxarm-keyring$' "$log"
chk "extras (minus missing ones)" grep -qx 'pacman -S --needed --noconfirm nano sudo curl wget git openssh htop' "$log"
chk "chroot mounts set up"      grep -q '^mount -t proc' "$log"
chk "chroot mounts torn down"   grep -q '^umount -R -l' "$log"
# ---- negative scenarios: a bad base tarball must abort the build and publish nothing
run_build() {  # run_build <mirror-dir> <outdir>
  (cd "$E/repo" && PATH=$E/bin:$PATH ALARM_URL=file://$1 ARCHM_VERSION=2099.01.01 \
     bash build.sh arm64 "$2") >"$E/neg.log" 2>&1
}
expect_abort() {  # expect_abort <what> <mirror-dir>
  local what=$1 mirror=$2 outdir=$E/out-$RANDOM
  if run_build "$mirror" "$outdir"; then echo "BUILD ACCEPTED: $what"; exit 1; fi
  if ls "$outdir"/archm-arm64.tar.gz >/dev/null 2>&1; then echo "TARBALL PRODUCED DESPITE: $what"; exit 1; fi
  grep -q 'could not download a verified' "$E/neg.log" || { echo "wrong failure for: $what"; cat "$E/neg.log"; exit 1; }
}
tgz=ArchLinuxARM-aarch64-latest.tar.gz

# (a) content changed after signing, md5 regenerated to match: only the signature can catch it
cp -r "$E/mirror" "$E/mirror-tampered"
echo "backdoor" >>"$E/mirror-tampered/$tgz"
(cd "$E/mirror-tampered" && md5sum "$tgz" >"$tgz.md5")
expect_abort "tampered tarball with matching md5" "$E/mirror-tampered"

# (b) intact tarball + matching md5, but signed by a key that is not the pinned one
cp -r "$E/mirror" "$E/mirror-wrongkey"
export GNUPGHOME=$E/gnupg-evil
mkdir -m 700 "$GNUPGHOME"
"$REAL_GPG" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'evil <evil@example.invalid>' default default never 2>/dev/null
rm -f "$E/mirror-wrongkey/$tgz.sig"
"$REAL_GPG" --batch --quiet --pinentry-mode loopback --passphrase '' \
  --detach-sign -o "$E/mirror-wrongkey/$tgz.sig" "$E/mirror-wrongkey/$tgz" 2>/dev/null
gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
unset GNUPGHOME
expect_abort "valid signature from the wrong key" "$E/mirror-wrongkey"

# (c) plain corruption: md5 does not match
cp -r "$E/mirror" "$E/mirror-corrupt"
echo 00000000000000000000000000000000 >"$E/mirror-corrupt/$tgz.md5"
expect_abort "md5 mismatch" "$E/mirror-corrupt"

echo "e2e OK"

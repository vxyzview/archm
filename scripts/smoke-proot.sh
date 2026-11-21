#!/usr/bin/env bash
# Smoke test run as a NORMAL user, the way an Android app would: unpack the tarball without
# root (no ownership, no devices, no xattrs) and run a few commands through proot.
#   scripts/smoke-proot.sh dist/archm-arm64.tar.gz arm64
set -Eeuo pipefail

tarball=${1:?usage: $0 <archm-ABI.tar.gz> <arm64|arm>}
abi=${2:?usage: $0 <archm-ABI.tar.gz> <arm64|arm>}
command -v proot >/dev/null 2>&1 || { echo "proot is not installed" >&2; exit 2; }
# --link2symlink and --kill-on-exit arrived in proot 5.2.0 (Ubuntu's apt package is 5.1.0). Fail
# once, clearly, instead of letting every check below die with the same "unknown option".
probe=$(proot --kill-on-exit --link2symlink -0 -r / true 2>&1 || true)
case $probe in
  *"unknown option"*)
    echo "$probe" >&2
    echo "proot is too old: need >= 5.2.0 (5.4.0 recommended, it adds faccessat2)" >&2
    exit 2 ;;
esac

case $abi in
  arm64) native="aarch64";       qemu="qemu-aarch64-static" ;;
  arm)   native="armv7l armv8l"; qemu="qemu-arm-static" ;;
  *)     echo "unknown ABI: $abi" >&2; exit 2 ;;
esac
emu=()
case " $native " in *" $(uname -m) "*) ;; *) emu=(-q "$qemu") ;; esac

root=$(mktemp -d)
trap 'chmod -R u+rwX "$root" 2>/dev/null || true; rm -rf "$root"' EXIT
echo "unpacking $(basename "$tarball") as uid $(id -u)"
tar -xzpf "$tarball" -C "$root"

unset PROOT_NO_SECCOMP LD_PRELOAD   # seccomp acceleration must stay on
run() {
  proot --kill-on-exit --link2symlink -0 -r "$root" -b /dev -b /proc -b /sys -w /root "${emu[@]}" \
    /usr/bin/env -i HOME=/root TERM=xterm-256color PATH=/usr/local/bin:/usr/bin \
    /bin/bash -c "$1"
}

failed=0
report=""
check() {   # check "<what>" "<shell snippet that must exit 0>"
  local out
  if out=$(run "$2" 2>&1); then
    report+="ok    $1"$'\n'
  else
    report+="FAIL  $1"$'\n'"$(sed 's/^/        | /' <<<"$out")"$'\n'
    failed=1
  fi
}
check_net() {   # like check, but up to 3 tries: a mirror hiccup must not block a release
  local out try
  for try in 1 2 3; do
    if out=$(run "$2" 2>&1); then
      report+="ok    $1"$'\n'
      return 0
    fi
    if [ "$try" -lt 3 ]; then sleep 10; fi
  done
  report+="FAIL  $1"$'\n'"$(sed 's/^/        | /' <<<"$out")"$'\n'
  failed=1
}
soft() {   # like check, but only reported ("warn"), never failing the run: for the optional trimming
  local out
  if out=$(run "$2" 2>&1); then
    report+="ok    $1"$'\n'
  else
    report+="warn  $1"$'\n'"$(sed 's/^/        | /' <<<"$out")"$'\n'
  fi
}

check "identifies as Arch Linux ARM"        '. /etc/os-release && [ "$NAME" = "Arch Linux ARM" ]'
check "fake root (uid 0)"                   '[ "$(id -u)" = 0 ]'
check "pacman runs"                         'pacman --version >/dev/null'
check "package database is populated"       '[ "$(pacman -Qq | wc -l)" -gt 50 ]'
check "kernel and firmware are gone"        '! pacman -Qq | grep -Eq "^(linux-aarch64|linux-armv7|linux-firmware)"'
check "pacman download sandbox is disabled" 'grep -qx DisableSandbox /etc/pacman.conf'
check "locale was generated"                'locale -a | grep -qi "^en_US.utf-\?8$"'
check "no default alarm user"               '! getent passwd alarm'
check "login shell applies archm prompt"    'bash -lic "case \$PS1 in *archm*) ;; *) exit 1;; esac"'
check_net "pacman can sync (network, DNS, sandbox off)" 'pacman -Sy --noconfirm'
check_net "pacman can install a package"        'pacman -S --needed --noconfirm tree'

# Reported but not blocking: if one of these breaks, the image still works, only less slim.
soft "first login fills /etc/machine-id"      'bash -lc true; [ -s /etc/machine-id ]'
soft "generated hwdb.bin is gone"             '[ ! -e /usr/lib/udev/hwdb.bin ]'
soft "translated man pages are gone"          '! ls /usr/share/man 2>/dev/null | grep -qv "^man"'

# Informational, not a check: login-shell cost under proot (qemu runs are inflated, and say so).
ms() {   # ms "<command>": mean wall time in milliseconds over 5 runs
  local t0 t1
  t0=$(date +%s%N)
  for _ in 1 2 3 4 5; do run "$1" >/dev/null 2>&1 || true; done
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 5000000 ))
}
timing="startup, mean of 5: login shell $(ms 'bash -lic exit') ms, bare proot + true $(ms true) ms${emu[*]:+ (under qemu: inflated)}"
report+=$'\n'"$timing"$'\n'

printf '\n%s' "$report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### proot smoke test: $abi"; echo '```'; printf '%s' "$report"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"

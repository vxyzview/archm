#!/usr/bin/env bash
# Reference launcher for the archm rootfs: the proot flags and Android workarounds that
# matter. Port the same ideas into xyzterm's launch command (or use this from Termux).
#
#   ARCHM_ROOTFS=$HOME/archm ./start-archm.sh                   interactive login shell
#   ARCHM_ROOTFS=$HOME/archm ./start-archm.sh -c 'pacman -Syu'  run one command
set -u

ROOTFS=${ARCHM_ROOTFS:-$HOME/archm}
STATE=${ARCHM_STATE:-$ROOTFS.state}        # fake /proc files live outside the rootfs
mkdir -p "$STATE" "$ROOTFS/tmp"

unset LD_PRELOAD                           # Termux's libtermux-exec confuses proot
# NEVER export PROOT_NO_SECCOMP: the seccomp fast path is what keeps proot tolerable.
: "${PROOT_TMP_DIR:=${TMPDIR:-/tmp}}"
export PROOT_TMP_DIR

binds=(
  -b /dev -b /proc -b /sys
  -b /dev/urandom:/dev/random              # /dev/random must never block
  -b /proc/self/fd:/dev/fd                 # <(process substitution), /dev/stdin, ...
  -b /proc/self/fd/0:/dev/stdin
  -b /proc/self/fd/1:/dev/stdout
  -b /proc/self/fd/2:/dev/stderr
  -b "$ROOTFS/tmp:/dev/shm"                # Android has no /dev/shm; many programs need one
)

# Android hides some /proc files from apps; htop, top, uptime and ps then break.
# Bind a stand-in only when the real file is unreadable.
fake() {   # fake <proc-path> <content>
  local f=$STATE/${1//\//_}
  if cat "$1" >/dev/null 2>&1; then return 0; fi
  printf '%s\n' "$2" >"$f"
  binds+=(-b "$f:$1")
}
cpus=$(nproc 2>/dev/null || echo 4)
stat="cpu  1000 0 1000 100000 100 0 0 0 0 0"
for ((i = 0; i < cpus; i++)); do stat+=$'\n'"cpu$i 250 0 250 25000 25 0 0 0 0 0"; done
stat+=$'\nintr 0\nctxt 0\nbtime 0\nprocesses 0\nprocs_running 1\nprocs_blocked 0'
fake /proc/stat    "$stat"
fake /proc/loadavg "0.10 0.10 0.10 1/100 1000"
fake /proc/uptime  "1000.00 1000.00"
fake /proc/version "Linux version 6.1.0 (proot@android) (gcc 14.2.1) #1 SMP PREEMPT"
fake /proc/sys/kernel/cap_last_cap "40"

# --link2symlink  Android forbids hard links; proot emulates them
# -0              fake root (uid 0), needed by pacman
# --kill-on-exit  no orphaned processes when the shell exits
exec proot --kill-on-exit --link2symlink -0 -r "$ROOTFS" "${binds[@]}" -w /root \
  /usr/bin/env -i HOME=/root TERM="${TERM:-xterm-256color}" LANG=en_US.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
  /bin/bash --login "$@"

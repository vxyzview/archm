# archm: proot-friendly defaults, sourced by every login shell.
# Keep this file fork-free (no $(...), no external commands): every fork+exec costs several
# milliseconds under proot, and this runs at each login.
# Config lives in /etc on purpose: xyzterm binds /root and /home to Android storage, so
# anything placed there would be hidden.

export TERM="${TERM:-xterm-256color}"
export COLORTERM="${COLORTERM:-truecolor}"
export TMPDIR="${TMPDIR:-/tmp}"
export LESS="${LESS:--R}"
if command -v nano >/dev/null 2>&1; then export EDITOR="${EDITOR:-nano}"; fi

# /etc/machine-id ships empty (it has to differ per install) and D-Bus or GUI programs complain
# about that. Fill it on the first login from the kernel's random UUID: POSIX builtins only,
# nothing happens afterwards (the file is no longer empty) or when /proc hides the UUID.
# The two ARCHM_* variables exist for tests/run.sh; nothing else sets them.
__archm_mid=${ARCHM_MACHINE_ID_FILE:-/etc/machine-id}
if [ ! -s "$__archm_mid" ] && [ -w "$__archm_mid" ]; then
  { IFS=- read -r __archm_a __archm_b __archm_c __archm_d __archm_e \
      <"${ARCHM_UUID_SOURCE:-/proc/sys/kernel/random/uuid}"; } 2>/dev/null
  __archm_id=${__archm_a-}${__archm_b-}${__archm_c-}${__archm_d-}${__archm_e-}
  case $__archm_id in
    *[!0-9a-f]*) ;;
    *) [ "${#__archm_id}" = 32 ] && { printf '%s\n' "$__archm_id" >"$__archm_mid"; } 2>/dev/null ;;
  esac
  unset __archm_a __archm_b __archm_c __archm_d __archm_e __archm_id
fi
unset __archm_mid

# Arch login shells do not read /etc/bash.bashrc; pull it in so the prompt, aliases and
# completion match non-login shells.
if [ -n "${BASH_VERSION-}" ]; then
  case $- in
    *i*) [ -r /etc/bash.bashrc ] && . /etc/bash.bashrc ;;
  esac
fi

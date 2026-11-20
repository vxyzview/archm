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

# Arch login shells do not read /etc/bash.bashrc; pull it in so the prompt, aliases and
# completion match non-login shells.
if [ -n "${BASH_VERSION-}" ]; then
  case $- in
    *i*) [ -r /etc/bash.bashrc ] && . /etc/bash.bashrc ;;
  esac
fi

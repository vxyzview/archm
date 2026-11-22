#!/usr/bin/env bash
# Offline tests for everything that can run without network, chroot, qemu or proot.
# (The chroot build and the proot smoke test are exercised by CI itself.)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD
T=$(mktemp -d)
export GNUPGHOME=$T/gnupg   # keep gpgconf --kill away from the developer's real agent
mkdir -m 700 "$GNUPGHOME"
trap 'gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true; rm -rf "$T"' EXIT

passed=0
failed=0
assert() { if ! "$@"; then echo "assertion failed: $*" >&2; exit 1; fi; }
t() {   # t <name> <function>: run in a subshell, report, keep going
  local name=$1 rc
  shift
  rm -f "$T/skip"
  set +e
  ( set -e; "$@" ) >"$T/out.log" 2>&1   # an if-condition would disable set -e in the test
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    failed=$((failed + 1)); printf '  FAIL  %s\n' "$name"; sed 's/^/        | /' "$T/out.log"
  elif [ -e "$T/skip" ]; then
    printf '  skip  %s\n' "$name"
  else
    passed=$((passed + 1)); printf '  ok    %s\n' "$name"
  fi
}

# ------------------------------------------------------------------ tests

test_syntax() {
  local f
  for f in build.sh config.env scripts/*.sh tests/*.sh extras/start-archm.sh \
           rootfs-overlay/etc/profile.d/archm.sh rootfs-overlay/etc/archm/bashrc; do
    bash -n "$f" || { echo "syntax error in $f"; exit 1; }
  done
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/release.yml"))'
    python3 -c 'import yaml; yaml.safe_load(open(".github/dependabot.yml"))'
  else
    echo "skip: python3-yaml not installed, workflow YAML not validated"
    touch "$T/skip"
  fi
  # every script the workflow calls must exist
  for f in $(grep -o '\(scripts\|tests\)/[a-z-]*\.sh' .github/workflows/release.yml | sort -u) build.sh; do
    [ -f "$f" ] || { echo "workflow references missing $f"; exit 1; }
  done
}

# Warnings and errors only: the info/style notes are taste, these are bugs. config.env is data
# that build.sh sources, so it is checked through build.sh. The overlay files have no shebang.
test_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "skip: shellcheck not installed"
    touch "$T/skip"
    return 0
  fi
  shellcheck -x -S warning -s bash build.sh scripts/*.sh tests/*.sh extras/start-archm.sh \
    rootfs-overlay/etc/archm/bashrc
  shellcheck -x -S warning -s sh rootfs-overlay/etc/profile.d/archm.sh
}

# The README is the front door: a broken image, a dead anchor or a ragged table would only show
# up on GitHub, after the push. Anchors follow GitHub's heading rule: lower-case, drop everything
# but letters, digits, "_", "-" and spaces (emoji go too), spaces become "-".
test_readme() {
  python3 - <<'PY'
import pathlib, re, sys
import xml.etree.ElementTree as ET

text = pathlib.Path("README.md").read_text()
errors = []

if len(re.findall(r"^```", text, flags=re.M)) % 2:
    errors.append("unbalanced ``` fences")
prose = re.sub(r"^```.*?^```", "", text, flags=re.M | re.S)       # code blocks are not markup

if len(re.findall(r"<details>", prose)) != len(re.findall(r"</details>", prose)):
    errors.append("<details> and </details> do not match")

def slug(heading):
    heading = re.sub(r"<[^>]+>|`", "", heading).lower()
    return re.sub(r"[^\w\- ]", "", heading).replace(" ", "-")

slugs, seen = set(), {}
for m in re.finditer(r"^#{1,6}\s+(.+?)\s*$", prose, flags=re.M):
    s = slug(m.group(1))
    n = seen.get(s, 0)
    seen[s] = n + 1
    slugs.add(s if n == 0 else f"{s}-{n}")

targets = re.findall(r"\]\(([^)\s]+)", prose) + re.findall(r'(?:href|src)="([^"]+)"', prose)
for t in targets:
    if re.match(r"(https?:|mailto:)", t):
        continue
    if t.startswith("#"):
        if t[1:] not in slugs:
            errors.append(f"anchor {t} matches no heading (headings give: {sorted(slugs)})")
    elif not pathlib.Path(t.split("#")[0]).exists():
        errors.append(f"linked file does not exist: {t}")

for tag in re.findall(r"<img\b[^>]*>", prose):
    if 'alt="' not in tag:
        errors.append(f"image without alt text: {tag[:70]}")

lines = prose.splitlines()
i = 0
while i < len(lines):
    if not lines[i].lstrip().startswith("|"):
        i += 1
        continue
    j = i
    while j < len(lines) and lines[j].lstrip().startswith("|"):
        j += 1
    block = lines[i:j]
    widths = {len(re.split(r"(?<!\\)\|", row.strip().strip("|"))) for row in block}
    if len(block) < 2 or len(widths) != 1 or not re.match(r"^\s*\|?\s*:?-{3,}", block[1]):
        errors.append(f"table at line {i + 1} is malformed or ragged: {block[0][:60]}")
    i = j

for m in re.finditer(r"^```mermaid\n(.*?)^```", text, flags=re.M | re.S):
    first = m.group(1).split("\n", 1)[0].strip()
    if not re.match(r"(flowchart|graph|sequenceDiagram|gantt|classDiagram|stateDiagram|pie|journey|erDiagram)\b", first):
        errors.append(f"mermaid block starts with {first!r}")

try:                                                              # the banner must at least be well-formed SVG
    svg = ET.parse("assets/banner.svg").getroot()
    if not svg.tag.endswith("svg") or "viewBox" not in svg.attrib:
        errors.append("assets/banner.svg is not an SVG with a viewBox")
except (ET.ParseError, OSError) as e:
    errors.append(f"assets/banner.svg: {e}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
}

# The release pipeline's safety rules, so an edit cannot quietly undo them.
test_workflow_policy() {
  local wf=.github/workflows/release.yml bad
  # every third-party action pinned to a full commit SHA (a tag can be moved, a SHA cannot)
  bad=$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$wf" | grep -vE 'uses: [^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' || true)
  [ -z "$bad" ] || { echo "actions not pinned to a commit SHA:"; echo "$bad"; exit 1; }
  # a failing smoke test must stop the release: nothing may be allowed to fail silently
  if grep -n 'continue-on-error' "$wf"; then echo "continue-on-error would let a broken image through"; exit 1; fi
  # publishing only ever happens from main, never from a branch someone ran by hand
  grep -q "github.ref == 'refs/heads/main'" "$wf" || { echo "release job is not restricted to main"; exit 1; }
  # signed provenance for what gets published
  grep -q 'id-token: write' "$wf" && grep -q 'attestations: write' "$wf" \
    || { echo "attestation permissions missing"; exit 1; }
  grep -qE 'uses: actions/attest@' "$wf" || { echo "no attestation step"; exit 1; }
  # one version for the image and the tag: the build job and the publish step both get it from
  # the version job, and sudo (which drops the environment) is told to pass it on to build.sh
  [ "$(grep -c 'needs.version.outputs.tag' "$wf")" -ge 2 ] \
    || { echo "ARCHM_VERSION must come from the version job in both the build job and the publish step"; exit 1; }
  grep -q 'sudo env ARCHM_VERSION=' "$wf" || { echo "sudo would drop ARCHM_VERSION before build.sh sees it"; exit 1; }
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

  # A key that expired after signing still produces VALIDSIG; it must not be accepted.
  # Faked time keeps the test deterministic: sign in 2020, verify now.
  eval "$g --faked-system-time 20200101T000000 --quick-generate-key 'archm test exp <exp@example.invalid>' default default 1d" 2>/dev/null
  local exp
  exp=$(gpg --batch --with-colons --list-keys exp@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')
  echo payload >"$WORK/file2"
  eval "$g --faked-system-time 20200101T010000 --local-user $exp --detach-sign -o '$WORK/file2.sig' '$WORK/file2'" 2>/dev/null
  ALARM_KEY=$exp
  if verify_sig "$WORK/file2"; then echo "expired key accepted"; exit 1; fi
}

# A gpg that records and refuses keyserver lookups: proves whether recv_key went to the network.
fake_keyserver_gpg() {   # fake_keyserver_gpg <bindir> <logfile>
  mkdir -p "$1"
  cat >"$1/gpg" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --recv-keys ] && { echo "keyserver lookup" >>"$2"; exit 2; }; done
exec "$(command -v gpg)" "\$@"
EOF
  chmod +x "$1/gpg"
}

test_vendored_key() {
  source "$REPO/build.sh"
  local file=$REPO/keys/archlinuxarm.asc home=$T/vk log=$T/vk.log fprs

  # the shipped file is the default, and holds exactly one primary key: the pinned one
  [ "$ALARM_KEYFILE" = "$file" ] || { echo "default key file is $ALARM_KEYFILE"; exit 1; }
  assert test -s "$file"
  fprs=$(gpg --batch --show-keys --with-colons "$file" |
    awk -F: '$1 == "pub" { p = 1; next } $1 == "sub" { p = 0 } $1 == "fpr" && p { print $10; p = 0 }')
  [ "$fprs" = "$ALARM_KEY" ] || { echo "key file holds: $fprs (want only $ALARM_KEY)"; exit 1; }

  # recv_key takes it from the file and never asks a keyserver
  fake_keyserver_gpg "$T/vk-bin" "$log"
  : >"$log"
  mkdir -m 700 "$home"
  export GNUPGHOME=$home
  PATH=$T/vk-bin:$PATH recv_key
  gpg --batch --list-keys "$ALARM_KEY" >/dev/null 2>&1 || { echo "pinned key not in keyring"; exit 1; }
  [ ! -s "$log" ] || { echo "keyserver contacted although the key file had the key"; exit 1; }

  # a file with some other key is no help: recv_key falls back to the keyservers (here: refused)
  local other=$T/vk-other.asc evil=$T/vk-evil
  mkdir -m 700 "$evil"
  GNUPGHOME=$evil gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'other <other@example.invalid>' default default never 2>/dev/null
  GNUPGHOME=$evil gpg --batch --armor --export other@example.invalid >"$other"
  gpgconf --homedir "$evil" --kill all >/dev/null 2>&1 || true
  rm -rf "$home"; mkdir -m 700 "$home"
  : >"$log"
  ALARM_KEYFILE=$other
  if (PATH=$T/vk-bin:$PATH recv_key) >/dev/null 2>&1; then echo "wrong key file accepted"; exit 1; fi
  [ "$(wc -l <"$log")" = 3 ] || { echo "expected all 3 keyservers to be tried, log: $(cat "$log")"; exit 1; }

  # an empty or missing file behaves like no file at all
  : >"$T/vk-empty.asc"
  for ALARM_KEYFILE in "$T/vk-empty.asc" "$T/vk-missing.asc"; do
    : >"$log"
    if (PATH=$T/vk-bin:$PATH recv_key) >/dev/null 2>&1; then echo "recv_key succeeded without any key"; exit 1; fi
    [ "$(wc -l <"$log")" = 3 ] || { echo "no keyserver fallback for $ALARM_KEYFILE"; exit 1; }
  done
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
  assert grep -qxF 'NoExtract = usr/share/man/* !usr/share/man/man*' "$c"
  [ "$(sed -n '/^\[options\]/{n;p}' "$c")" = '# >>> archm (proot tuning)' ] || { echo "block not after [options]"; exit 1; }
  assert grep -qx '\[core\]' "$c"
  assert grep -qx '\[extra\]' "$c"
  fixture_pacman_conf >"$c"                                         # SLIM=0 keeps stock layout
  SLIM=0
  patch_pacman_conf
  if grep -q '^NoExtract' "$c"; then echo "NoExtract present with SLIM=0"; exit 1; fi
  assert grep -qx 'DisableSandbox' "$c"
}

# Pattern order in NoExtract is easy to get silently wrong: pacman lets the LAST matching
# pattern win, so a "!" exception written before its glob strips everything, English included.
# So install a fixture package with a real pacman, using the NoExtract lines customize.sh writes.
test_noextract_pacman() {
  local wrap=()
  if ! command -v pacman >/dev/null 2>&1; then
    echo "skip: pacman not installed (Debian/Ubuntu: pacman-package-manager)"; touch "$T/skip"; return 0
  fi
  if [ "$(id -u)" != 0 ]; then
    if ! command -v fakeroot >/dev/null 2>&1; then
      echo "skip: pacman needs root or fakeroot"; touch "$T/skip"; return 0
    fi
    wrap=(fakeroot)
  fi
  source "$REPO/scripts/customize.sh"
  ROOT=$T/ne
  mkdir -p "$ROOT/etc"
  fixture_pacman_conf >"$ROOT/etc/pacman.conf"
  SLIM=1
  patch_pacman_conf

  local pkg=$T/ne-pkg dest=$T/ne-root f
  mkdir -p "$pkg" "$dest" "$T/ne-db" "$T/ne-cache" "$T/ne-hooks" "$T/ne-gnupg"
  for f in usr/bin/keepme \
           usr/share/doc/foo/README usr/share/gtk-doc/html/index.html usr/share/help/de/x usr/share/info/dir \
           usr/share/locale/de/LC_MESSAGES/a.mo usr/share/locale/fr/LC_MESSAGES/a.mo \
           usr/share/locale/en_GB/LC_MESSAGES/a.mo usr/share/locale/en_US/LC_MESSAGES/a.mo \
           usr/share/locale/locale.alias \
           usr/share/man/man1/ls.1.gz usr/share/man/man8/x.8.gz \
           usr/share/man/de/man1/ls.1.gz usr/share/man/fr/man1/ls.1.gz usr/share/man/ja/man8/x.8.gz; do
    mkdir -p "$pkg/$(dirname "$f")"
    echo x >"$pkg/$f"
  done
  printf 'pkgname = fixture\npkgver = 1-1\npkgdesc = NoExtract fixture\nbuilddate = 1700000000\npackager = test\nsize = 1\narch = any\n' >"$pkg/.PKGINFO"
  tar -C "$pkg" -czf "$T/fixture-1-1-any.pkg.tar.gz" .PKGINFO usr
  {
    printf '[options]\nRootDir = %s\nDBPath = %s/\nCacheDir = %s/\nLogFile = %s\nGPGDir = %s/\nHookDir = %s/\n' \
      "$dest" "$T/ne-db" "$T/ne-cache" "$T/ne-pacman.log" "$T/ne-gnupg" "$T/ne-hooks"
    printf 'Architecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\n'
    grep '^NoExtract' "$ROOT/etc/pacman.conf"
  } >"$T/ne.conf"
  "${wrap[@]}" pacman --config "$T/ne.conf" -U --noconfirm --noscriptlet "$T/fixture-1-1-any.pkg.tar.gz" >/dev/null 2>&1 \
    || { echo "pacman -U failed:"; "${wrap[@]}" pacman --config "$T/ne.conf" -U --noconfirm --noscriptlet "$T/fixture-1-1-any.pkg.tar.gz" 2>&1 | tail -5; exit 1; }

  local got want
  got=$(cd "$dest" && find . -type f | sort)
  want=$(printf '%s\n' ./usr/bin/keepme \
    ./usr/share/locale/en_GB/LC_MESSAGES/a.mo ./usr/share/locale/en_US/LC_MESSAGES/a.mo ./usr/share/locale/locale.alias \
    ./usr/share/man/man1/ls.1.gz ./usr/share/man/man8/x.8.gz | sort)
  [ "$got" = "$want" ] || { echo "pacman extracted the wrong files"; diff <(echo "$want") <(echo "$got") || true; exit 1; }
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

# First login fills the empty /etc/machine-id from the kernel UUID, once, quietly, in any shell
# (and under `set -u`, which some login setups use).
test_machine_id() {
  local sh mid=$T/machine-id uuid=$T/uuid p=$REPO/rootfs-overlay/etc/profile.d/archm.sh out
  login() {   # login <shell> [uuid source]: source profile.d the way a login shell would
    env -i PATH="$PATH" ARCHM_MACHINE_ID_FILE="$mid" ARCHM_UUID_SOURCE="${2:-$uuid}" \
      "$1" -c "set -u; . '$p'; echo login-ok" 2>&1
  }
  for sh in sh bash; do
    echo 3f2a9c1e-7b44-4d0a-9e55-0c1d2e3f4a5b >"$uuid"
    : >"$mid"
    out=$(login "$sh")
    [ "$out" = login-ok ] || { echo "$sh: noise or failure on first login: $out"; exit 1; }
    [ "$(cat "$mid")" = 3f2a9c1e7b444d0a9e550c1d2e3f4a5b ] || { echo "$sh: machine-id is [$(cat "$mid")]"; exit 1; }

    echo 00000000-0000-0000-0000-000000000000 >"$uuid"          # a later login must not change it
    login "$sh" >/dev/null
    [ "$(cat "$mid")" = 3f2a9c1e7b444d0a9e550c1d2e3f4a5b ] || { echo "$sh: machine-id rewritten"; exit 1; }

    : >"$mid"                                                    # /proc hides the UUID: stay empty, say nothing
    out=$(login "$sh" "$T/no-such-uuid")
    [ "$out" = login-ok ] || { echo "$sh: noise when the UUID is unreadable: $out"; exit 1; }
    [ ! -s "$mid" ] || { echo "$sh: machine-id invented from nothing"; exit 1; }

    echo not-a-uuid >"$uuid"                                     # garbage is never written
    login "$sh" >/dev/null
    [ ! -s "$mid" ] || { echo "$sh: garbage written to machine-id: $(cat "$mid")"; exit 1; }

    echo 3f2a9c1e-7b44-4d0a-9e55-0c1d2e3f4a5b >"$uuid"          # an id someone set is never replaced
    echo preset >"$mid"
    login "$sh" >/dev/null
    [ "$(cat "$mid")" = preset ] || { echo "$sh: existing machine-id replaced"; exit 1; }
  done
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
  # main() masks before the upgrade and again after it: a second pass must be harmless, and must
  # catch hook files the upgrade installed in between
  mask_hooks
  [ "$(readlink "$h/30-systemd-hwdb.hook")" = /dev/null ] || { echo "second pass broke a mask"; exit 1; }
  : >"$d/40-new-udev-thing.hook"
  mask_hooks
  [ "$(readlink "$h/40-new-udev-thing.hook")" = /dev/null ] || { echo "hook added by the upgrade not masked"; exit 1; }
}

test_slim_down() {
  source "$REPO/scripts/customize.sh"
  ROOT=$T/sd
  local f
  mkdir -p "$ROOT"/usr/share/{doc/foo,gtk-doc,help,info,locale/{de,en_GB},man/{man1,man8,de/man1,fr/man1}} \
           "$ROOT"/usr/lib/udev "$ROOT"/etc/udev
  for f in usr/share/doc/foo/README usr/share/info/dir usr/share/locale/de/a.mo usr/share/locale/en_GB/a.mo \
           usr/share/locale/locale.alias usr/share/man/man1/ls.1.gz usr/share/man/man8/x.8.gz \
           usr/share/man/de/man1/ls.1.gz usr/share/man/fr/man1/ls.1.gz usr/lib/udev/hwdb.bin etc/udev/hwdb.bin; do
    echo x >"$ROOT/$f"
  done
  SLIM=0                                                         # stock layout: nothing is touched
  slim_down
  for f in usr/share/doc/foo/README usr/share/locale/de/a.mo usr/share/man/de/man1/ls.1.gz usr/lib/udev/hwdb.bin; do
    [ -e "$ROOT/$f" ] || { echo "SLIM=0 removed $f"; exit 1; }
  done
  SLIM=1
  slim_down
  for f in usr/share/doc/foo usr/share/info/dir usr/share/locale/de usr/share/man/de usr/share/man/fr \
           usr/lib/udev/hwdb.bin etc/udev/hwdb.bin; do
    [ ! -e "$ROOT/$f" ] || { echo "SLIM=1 kept $f"; exit 1; }
  done
  for f in usr/share/locale/en_GB/a.mo usr/share/locale/locale.alias usr/share/man/man1/ls.1.gz usr/share/man/man8/x.8.gz; do
    [ -e "$ROOT/$f" ] || { echo "SLIM=1 removed $f"; exit 1; }
  done
  rm -rf "$ROOT/usr/share/man"                                   # a rootfs without man pages is fine too
  slim_down
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

test_pack_failure() {
  source "$REPO/build.sh"
  ROOT=$T/pkf/rootfs; OUT=$T/pkf/out; ABI=arm64
  mkdir -p "$ROOT" "$OUT" "$T/pkf/bin"
  printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$T/pkf/bin/tar"
  chmod +x "$T/pkf/bin/tar"
  if PATH=$T/pkf/bin:$PATH pack >/dev/null 2>&1; then echo "pack succeeded with failing tar"; exit 1; fi
  [ -z "$(ls -A "$OUT")" ] || { echo "partial output left: $(ls -A "$OUT")"; exit 1; }
}

test_build_report() {
  source "$REPO/build.sh"
  ROOT=$T/br/rootfs; OUT=$T/br/out; ABI=arm64; VERSION=2099.01.01; ALARM_ARCH=aarch64; BASE_MD5=abc123
  mkdir -p "$ROOT"/{etc,usr/bin,dev,proc,sys,run,tmp,root} "$OUT"
  head -c 100 /dev/zero >"$ROOT/usr/bin/a"
  ln "$ROOT/usr/bin/a" "$ROOT/usr/bin/b"
  ln "$ROOT/usr/bin/a" "$ROOT/usr/bin/c"          # 3 names for one 100-byte file: 2 extra copies in the tarball
  head -c 50 /dev/zero >"$ROOT/etc/conf"
  ln -s a "$ROOT/usr/bin/link"
  printf 'bash 5.2-1\nglibc 2.40-1\n' >"$OUT/archm-arm64.packages.txt"

  [ "$(hardlink_stats)" = "3 1 200" ] || { echo "hardlink_stats: $(hardlink_stats)"; exit 1; }

  pack >/dev/null 2>&1
  measure_tarball
  [ "$UNPACKED" = 350 ] || { echo "unpacked bytes: $UNPACKED (want 350)"; exit 1; }
  [ "$FILES" = "$(tar -tzf "$OUT/archm-arm64.tar.gz" | wc -l)" ] || { echo "file count $FILES is wrong"; exit 1; }

  # the 30 largest packages, KiB/MiB/GiB all understood, biggest first
  {
    printf 'Name            : big\nInstalled Size  : 1.50 GiB\n\nName            : tiny\nInstalled Size  : 12.00 KiB\n\n'
    local i
    for i in $(seq 1 35); do printf 'Name            : p%s\nInstalled Size  : %s.00 MiB\n\n' "$i" "$i"; done
  } >"$T/br/qi.txt"
  in_chroot() { cat "$T/br/qi.txt"; }
  local top
  top=$(top_packages)
  [ "$(wc -l <<<"$top")" = 30 ] || { echo "expected 30 lines, got $(wc -l <<<"$top")"; exit 1; }
  [ "$(sed -n 1p <<<"$top")" = "  1536.0 MiB  big" ] || { echo "first line: $(sed -n 1p <<<"$top")"; exit 1; }
  [ "$(sed -n 2p <<<"$top")" = "    35.0 MiB  p35" ] || { echo "second line: $(sed -n 2p <<<"$top")"; exit 1; }
  grep -q ' p7$' <<<"$top" || { echo "p7 should be the last one kept"; exit 1; }
  if grep -Eq ' (p6|tiny)$' <<<"$top"; then echo "list is longer than 30 or unsorted"; exit 1; fi
  TOP_PACKAGES=$top
  HARDLINKS="3 1 209715200"
  write_report >/dev/null 2>&1
  local md=$OUT/archm-arm64.stats.md
  grep -q '^### archm arm64 build report' "$md"                                || { echo "report heading"; exit 1; }
  grep -qF '| packages | 2 |' "$md"                                            || { echo "report: packages"; cat "$md"; exit 1; }
  grep -qF "| files in the tarball | $FILES |" "$md"                            || { echo "report: files"; exit 1; }
  grep -qF '| hardlinked files | 3 in 1 groups; --hard-dereference stores 200.0 MiB' "$md" || { echo "report: hardlinks"; cat "$md"; exit 1; }
  grep -q 'Largest packages by installed size' "$md"                           || { echo "report: package list"; exit 1; }

  # .info gets the two new numbers when they are known, and only then
  write_info
  grep -qx 'files='"$FILES" "$OUT/archm-arm64.info"                            || { echo "info: files"; cat "$OUT/archm-arm64.info"; exit 1; }
  grep -qx 'uncompressed_bytes=350' "$OUT/archm-arm64.info"                    || { echo "info: uncompressed_bytes"; exit 1; }
  grep -qx 'packages=2' "$OUT/archm-arm64.info"                                || { echo "info: packages"; exit 1; }
  unset FILES UNPACKED
  write_info
  if grep -q '^files=\|^uncompressed_bytes=' "$OUT/archm-arm64.info"; then echo "info: numbers written although unknown"; exit 1; fi

  # a tarball that cannot be listed is reported as a failure, not as "0 files"
  echo junk >"$OUT/archm-arm64.tar.gz"
  if measure_tarball 2>/dev/null; then echo "measure_tarball accepted a corrupt tarball"; exit 1; fi
  [ -z "${FILES:-}" ] || { echo "FILES set from a corrupt tarball: $FILES"; exit 1; }
}

test_publish() {
  local d=$T/pub tag
  mkdir -p "$d/bin"
  cat >"$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$GH_LOG"
case "$1 $2" in
  "release view")
    case "$3" in
      --repo) [ -n "${GH_PREV:-}" ] && { echo "$GH_PREV"; exit 0; }; exit 1 ;;   # no tag given: the latest release
      "$GH_EXISTING") exit 0 ;;                                                  # pretend this tag exists
    esac
    exit 1 ;;
  "release download")                                                            # the previous release's package lists
    dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    [ -n "${GH_PREV_DIR:-}" ] && cp "$GH_PREV_DIR"/*.packages.txt "$dir"/
    exit 0 ;;
  "release list") printf 'old1\nold2\n'; exit 0 ;;                                # what --jq would print
esac
exit 0
EOF
  chmod +x "$d/bin/gh"
  export PATH=$d/bin:$PATH GH_LOG=$d/gh.log GITHUB_REPOSITORY=me/archm KEEP_RELEASES=2
  GH_EXISTING=$(date -u +%Y.%m.%d)
  export GH_EXISTING
  unset ARCHM_VERSION GH_PREV GH_PREV_DIR

  mkdist() {   # mkdist <dir> <version stamped in .info>
    local abi
    mkdir -p "$1"
    for abi in arm64 arm; do
      head -c 4096 /dev/urandom >"$1/archm-$abi.tar.gz"
      (cd "$1" && sha256sum "archm-$abi.tar.gz" >"archm-$abi.tar.gz.sha256")
      printf 'bash 5.2.1-1\nglibc 2.40-1\nadded 1.0-1\n' >"$1/archm-$abi.packages.txt"
      printf 'abi=%s\nalarm_arch=%s\nversion=%s\nbase_md5=abc123\npackages=321\nfiles=41234\nuncompressed_bytes=812345678\n' \
        "$abi" "$([ "$abi" = arm64 ] && echo aarch64 || echo armv7)" "$2" >"$1/archm-$abi.info"
    done
  }

  # (1) by hand, no ARCHM_VERSION: today's date, and ".1" because today's tag already exists
  mkdist "$d/a" x
  bash "$REPO/scripts/publish.sh" "$d/a" >/dev/null
  tag=$GH_EXISTING.1
  grep -q "^release create $tag --repo me/archm --title archm $tag --notes-file notes.md --latest archm-arm.tar.gz archm-arm64.tar.gz" "$d/gh.log" \
    || { echo "unexpected release create call:"; cat "$d/gh.log"; exit 1; }
  grep -q 'SHA256SUMS manifest.json$' "$d/gh.log" || { echo "assets missing from release create"; exit 1; }
  grep -q '^release delete old1 --repo me/archm --cleanup-tag --yes' "$d/gh.log" || { echo "prune did not run"; exit 1; }
  python3 - "$d/a" "$tag" <<'PY'
import json, sys
d, tag = sys.argv[1:3]
m = json.load(open(f"{d}/manifest.json"))
assert m["tag"] == tag and m["name"] == "archm", m
a = m["assets"]
assert list(a) == ["arm64", "arm"], list(a)
assert a["arm64"]["url"] == f"https://github.com/me/archm/releases/download/{tag}/archm-arm64.tar.gz"
assert len(a["arm64"]["sha256"]) == 64 and a["arm64"]["size"] == 4096
assert a["arm"]["alarm_arch"] == "armv7" and a["arm64"]["alarm_arch"] == "aarch64"
for abi in a:   # numbers for the launcher: free-space check and progress by file count
    assert a[abi]["files"] == 41234 and a[abi]["uncompressed_bytes"] == 812345678, a[abi]
notes = open(f"{d}/notes.md").read()
assert a["arm64"]["sha256"] in notes and "archm-arm.tar.gz" in notes and "321 packages" in notes
assert "41234 files, 812 MB unpacked" in notes, notes
assert "Changes since" not in notes, "no previous release was given"
PY

  # (2) as the workflow does it: the exact tag from ARCHM_VERSION, notes with the package changes
  mkdist "$d/b" 2030.01.02
  mkdir -p "$d/prevfix"
  printf 'bash 5.2.0-1\nglibc 2.40-1\nremoved 1.0-1\n' | tee "$d/prevfix/archm-arm64.packages.txt" >"$d/prevfix/archm-arm.packages.txt"
  : >"$d/gh.log"
  ARCHM_VERSION=2030.01.02 GH_PREV=2029.12.31 GH_PREV_DIR=$d/prevfix bash "$REPO/scripts/publish.sh" "$d/b" >/dev/null
  grep -q '^release create 2030.01.02 --repo me/archm --title archm 2030.01.02 ' "$d/gh.log" || { echo "wrong tag:"; cat "$d/gh.log"; exit 1; }
  grep -qF 'release download 2029.12.31 --repo me/archm --pattern archm-*.packages.txt --dir prev' "$d/gh.log" \
    || { echo "previous package lists not fetched:"; cat "$d/gh.log"; exit 1; }
  python3 - "$d/b" <<'PY'
import json, sys
d = sys.argv[1]
assert json.load(open(f"{d}/manifest.json"))["tag"] == "2030.01.02"
notes = open(f"{d}/notes.md").read()
for want in ("## Changes since 2029.12.31",
             "- `arm64`: 1 updated, 1 added, 1 removed", "- `arm`: 1 updated, 1 added, 1 removed",
             "~ bash 5.2.0-1 -> 5.2.1-1", "+ added 1.0-1", "- removed 1.0-1", "<details><summary>arm64 package changes"):
    assert want in notes, (want, notes)
assert "glibc" not in notes.split("## Changes since")[1], "an unchanged package is listed as a change"
PY

  # (3) a missing or unusable previous release only means no "changes" section
  mkdist "$d/b2" 2030.01.03
  ARCHM_VERSION=2030.01.03 GH_PREV=2029.12.31 bash "$REPO/scripts/publish.sh" "$d/b2" >/dev/null   # nothing to download
  if grep -q 'Changes since' "$d/b2/notes.md"; then echo "changes section without a previous package list"; exit 1; fi

  # (4) refuse to publish over an existing tag, or an image built as some other version
  mkdist "$d/c" "$GH_EXISTING"
  : >"$d/gh.log"
  if ARCHM_VERSION=$GH_EXISTING bash "$REPO/scripts/publish.sh" "$d/c" >/dev/null 2>&1; then echo "published over an existing tag"; exit 1; fi
  mkdist "$d/e" 2030.01.01
  if ARCHM_VERSION=2030.01.04 bash "$REPO/scripts/publish.sh" "$d/e" >/dev/null 2>&1; then echo "published an image built as another version"; exit 1; fi
  if grep -q '^release create' "$d/gh.log"; then echo "a release was created despite the refusal"; exit 1; fi
}

# ------------------------------------------------------------------ run

echo "archm tests"
t "scripts parse, workflow is valid YAML"   test_syntax
t "shellcheck: no warnings or errors"        test_shellcheck
t "workflow: pinned actions, gated release"  test_workflow_policy
t "README: links, anchors, tables, banner"    test_readme
t "ABI mapping arm64/arm"                    test_target
t "kernel/firmware regex"                    test_remove_regex
t "md5 verification"                         test_md5
t "GPG: pinned key only, tamper/expiry detected" test_signature
t "signing key vendored, keyserver fallback" test_vendored_key
t "pacman.conf patch (idempotent, SLIM)"     test_pacman_conf
t "NoExtract strips/keeps the right files (real pacman)" test_noextract_pacman
t "overlay install + makepkg flags"          test_overlay
t "login/interactive shell overlay"          test_shell_overlay
t "first login initialises machine-id"       test_machine_id
t "pacman hook masking"                      test_hooks
t "slim_down: translations, man pages, hwdb" test_slim_down
t "tarball: no hardlinks, excludes, hash"    test_pack
t "tarball: failed pack leaves nothing"      test_pack_failure
t "build report: sizes, hardlinks, top packages" test_build_report
t "release: tag, manifest, notes, changes, prune" test_publish
t "e2e: real build.sh+customize.sh, fake chroot"  bash tests/e2e-fake.sh "$T/e2e-run"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

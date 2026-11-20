# archm

Arch Linux ARM rootfs tuned for **proot on Android**, made for [xyzterm](https://github.com/vxyzview/xyzterm).
Rebuilt every week from the official Arch Linux ARM tarball (full `pacman -Syu` at build time) and published as GitHub releases.

| ABI (xyzterm) | Arch Linux ARM | Always-latest download |
|---|---|---|
| `arm64` | aarch64 | `https://github.com/vxyzview/archm/releases/latest/download/archm-arm64.tar.gz` |
| `arm` | armv7 | `https://github.com/vxyzview/archm/releases/latest/download/archm-arm.tar.gz` |

Every release also carries `*.tar.gz.sha256`, `SHA256SUMS`, `manifest.json` (tag, URL, SHA-256, size per ABI) and `*.packages.txt`.
Tags are dates: `2026.11.20`, and `2026.11.20.1` for a second build the same day.

## Use it in xyzterm

1. Create the GitHub repo `archm` from these files; the first push to `main` publishes the first release (**Actions → release → Run workflow** works too).
2. In xyzterm, replace the Ubuntu rootfs source with archm, per ABI: the release URL and its pinned SHA-256
   (`archm-arm64.tar.gz.sha256`, or `manifest.json` if you want the app to look it up).
3. What the extractor can rely on: plain `.tar.gz`; entries start at `./` (`./bin`, `./etc`, ...); no hardlinks,
   no device nodes, no xattrs; `dev`, `proc`, `sys` are empty. Shell: `/bin/bash`. First command: `pacman -Syu`.
4. Anything in the app that assumes Ubuntu (apt commands, `/etc/lsb-release`, `pfetch` tweaks) needs a pacman equivalent.

Shell setup lives in `/etc` (`/etc/profile.d/archm.sh`, `/etc/archm/bashrc`) on purpose: xyzterm binds `/root` and
`/home` to Android storage, so dotfiles baked into them would be hidden. Put your own tweaks in `~/.bashrc`.

## What archm changes compared with the stock tarball

| Change | Why it matters under proot |
|---|---|
| `DisableSandbox` in `pacman.conf`; no `DownloadUser`, no `CheckSpace` | pacman 7's download sandbox needs Landlock/seccomp, which proot/Android generally can't give. Without this, `pacman -Syu` fails. |
| Kernel, headers, firmware, U-Boot, initramfs tools removed | The Android kernel is what runs. Far fewer files and bytes to extract and back up. |
| Docs and non-English translations not installed (`NoExtract`, `SLIM=1`) | Fewer files means faster installs and upgrades (every file costs ptrace round-trips). Man pages stay. |
| Hardware-database pacman hooks masked (`*hwdb*`, `*udev*`) | They rebuild databases that are useless here and are slow under proot. |
| `makepkg` uses `-j$(nproc)` | Builds use all cores. |
| Keyring initialised and populated | No slow `pacman-key --init` on first use. |
| No default credentials: `alarm` user removed, root locked, no SSH host keys | Stock Arch Linux ARM ships `alarm/alarm` and `root/root`. |
| Static DNS (1.1.1.1, 8.8.8.8), Android group names (`aid_inet`, ...) | Android has no `/etc/resolv.conf`; `id` stops complaining about unknown groups. |
| Fork-free login scripts; prompt says `archm` | Every fork+exec is slow under proot, and Android reports the hostname as `localhost`. |
| Hardlink-free, xattr-free `.tar.gz` | Unpacks on Android without special handling. |

The rootfs is `en_US.UTF-8`, `UTC`. Change `LOCALE`/`TIMEZONE`/`EXTRA_PKGS`/`SLIM` in `config.env`.
Get docs and translations back: delete the two `NoExtract` lines in `/etc/pacman.conf`, then reinstall the packages you want them for.

## Make proot faster (launcher and Android side)

`extras/start-archm.sh` is a working reference; port the same ideas into xyzterm's launch command.

- **Never set `PROOT_NO_SECCOMP`.** The seccomp fast path avoids a ptrace stop on most syscalls.
- Flags: `--link2symlink` (Android forbids hardlinks), `-0` (fake root, pacman needs it), `--kill-on-exit`.
  Bind as little as possible: each bind adds path-translation work to every `open`.
- Bind `<rootfs>/tmp` to `/dev/shm` (Android has none), `/dev/urandom` to `/dev/random`, and stand-ins for
  `/proc/stat`, `loadavg`, `uptime`, `version` when Android hides them (htop, top, uptime and ps break otherwise).
- Keep proot current (Termux's build). Do not nest proot inside proot.
- Do heavy I/O (git clone, npm, cargo, compiling) inside the rootfs, for example under `/opt`. If `/home` is shared
  storage it goes through FUSE and is much slower than the app's private directory.
- Android 12+ may kill proot children (`[Process completed (signal 9)]`). Android 14+: Developer options →
  *Disable child process restrictions*. Android 12-13 over adb:
  `adb shell settings put global settings_enable_monitor_phantom_procs false`.
- Set battery to *Unrestricted* for the app, hold a wake lock for long jobs, and run big `pacman -Syu` upgrades while charging.
- Pass `TZ` from Android into the session if you want local time.

## Releases and updates

- **Weekly**: Mondays 03:17 UTC the workflow downloads the newest official tarball, verifies it, upgrades everything, and publishes.
- **Manual**: Actions → release → *Run workflow*.
- **On push**: builds, tests, and publishes a release, like a manual run.
- The signature of the base tarball is checked against key `68B3537F39A313B3E574D06777193F152BDBE6A6` (published by Arch Linux ARM).
- Optional repo variable `KEEP_RELEASES` (for example `12`) deletes older releases and tags.
  Remember xyzterm pins a specific release: do not prune the one it points to.
- GitHub pauses schedules after 60 days without repository activity; the workflow tries to re-enable itself on every run (best effort), and
  *Enable workflow* on the Actions tab fixes it if it ever stops.

## Build it yourself

Needs a real Linux machine with root (not proot/Termux).

```sh
sudo apt install qemu-user-static binfmt-support libarchive-tools pigz curl gnupg
sudo ./build.sh arm64 dist        # or: arm
bash tests/run.sh                 # offline tests, no root needed
```

Output: `dist/archm-<abi>.tar.gz` (+ `.sha256`, `.packages.txt`, `.info`). `KEEP_WORK=1` keeps the temp rootfs for inspection.

## Troubleshooting

- `restricting filesystem access failed ... Landlock`: `DisableSandbox` is missing from `[options]` in `/etc/pacman.conf`.
- `signature ... is unknown trust`: `pacman -Sy archlinuxarm-keyring && pacman-key --populate archlinuxarm`.
- `failed retrieving file ... 404`: a mirror is mid-sync. Retry, or pick another in `/etc/pacman.d/mirrorlist`.
- Database not found / `target not found`: run `pacman -Syu` first; archm ships without sync databases.
- D-Bus or GUI programs complain about the machine ID: `dbus-uuidgen --ensure=/etc/machine-id`.
- `sshd` has no host keys: `ssh-keygen -A`, and set a root or user password first.

## License

Scripts: MIT. The packages inside the rootfs keep their own licenses. Not affiliated with Arch Linux or Arch Linux ARM.

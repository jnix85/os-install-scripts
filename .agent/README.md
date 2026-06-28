# Agent Context — ubuntu-zfs-installer

This directory is agent-agnostic context for AI assistants working on this repository.
Read this before making changes to `install-ubuntu-zfs.sh`.

## What this repo is

A single bash installer script that provisions Ubuntu Server (targeting 26.04) on bare
metal from a Desktop Live ISO environment. It uses ZFS-on-root with separate `bpool`
(boot) and `rpool` (root) pools, ZFSBootMenu + systemd-boot for booting, sanoid for
snapshots, and cdebootstrap for the base OS install.

## Architecture decisions that are intentional — do not reverse

| Decision | Why |
|---|---|
| Separate bpool / rpool | bpool uses restricted ZFS feature set for ZFSBootMenu compatibility |
| `canmount=off` on pool roots | Prevents auto-mount shadowing; only `rpool/ROOT/ubuntu` mounts explicitly |
| rpool root mounted BEFORE bpool datasets created | bpool/BOOT/ubuntu must land on top of an already-mounted `/boot` dir |
| `org.zfsbootmenu:commandline` set in live env, not chroot | Pools aren't imported inside chroot; `zfs set` is a no-op there |
| `resolv.conf` bind-mounted, not copied | Prevents a stale live-ISO DNS file persisting on the installed system |
| Passwords set via `printf ... \| chpasswd` OUTSIDE chroot | Avoids exposure in `/proc/<pid>/environ` during the long-running chroot |
| DEB822 format for apt sources | `sources.list` one-liner format is deprecated in Ubuntu 24.04+ |
| `systemd-boot` + `systemd-boot-efi` in live-env packages | `bootctl` command exists (from `systemd`) but EFI stubs may be absent |
| `cdebootstrap --verbose 2>&1 \| tee \| grep '^P:'` | Logs full verbose output to file while keeping console to P: lines only |
| Swap auto-sized from `/proc/meminfo` | ≤8G→equal to RAM; ≤32G→half; >32G→16G cap |
| `zfs-import-bpool.service` custom unit | Reliable bpool import at boot; stock scan/cache services don't handle it |
| `exec > >(tee -a "${LOG}") 2>&1` at top | All console output transparently duplicated to `/var/log/os-install.log` |

## Key variables

- `TARGET_DISK` — hard-coded to `/dev/nvme0n1`; single disk, no redundancy
- `POOL_ROOT` — live-env mountpoint: `/mnt/zfsinstall`
- `RPOOL` / `BPOOL` — pool names `rpool` / `bpool`
- `LOG` — `/var/log/os-install.log`

## Dataset layout

```
rpool/ROOT/ubuntu          → /
rpool/ROOT/ubuntu/home     → /home
rpool/ROOT/ubuntu/root     → /root
rpool/ROOT/ubuntu/srv      → /srv
rpool/ROOT/ubuntu/tmp      → /tmp
rpool/ROOT/ubuntu/usr      → (canmount=off)
rpool/ROOT/ubuntu/usr/local→ /usr/local
rpool/ROOT/ubuntu/var      → (canmount=off)
rpool/ROOT/ubuntu/var/cache→ /var/cache    (no snapshots)
rpool/ROOT/ubuntu/var/lib  → (canmount=off)
rpool/ROOT/ubuntu/var/lib/docker → /var/lib/docker (no snapshots)
rpool/ROOT/ubuntu/var/log  → /var/log
rpool/ROOT/ubuntu/var/spool→ /var/spool    (no snapshots)
rpool/ROOT/ubuntu/var/tmp  → /var/tmp      (no snapshots)
rpool/swap                 → zvol, auto-sized from RAM

bpool/BOOT/ubuntu          → /boot
```

## Known issues / watch points

- **Ubuntu 26.04 codename**: not finalized as of this writing. The script defaults to
  `noble` (24.04) as a placeholder — verify with `lsb_release -cs` on a running 26.04
  system before running.
- **cdebootstrap hang at `P: Extracting gcc-16-base`**: Observed in practice. Full
  verbose output goes to `/var/log/os-install.log` for diagnosis. If it hangs, check
  whether the live ISO has sufficient entropy (`cat /proc/sys/kernel/random/entropy_avail`)
  and whether `dpkg` inside the chroot is consuming CPU (`ps aux | grep dpkg`).
- **ZFSBootMenu EFI binary**: downloaded from GitHub releases with SHA256 verification.
  If the download fails, the apt package path is attempted as a fallback. If both fail,
  a warning is printed and the EFI path is set as a placeholder — the system will not
  boot until the binary is placed manually.
- **`visudo -c -f` inside chroot**: called to validate the sudoers.d file. If `visudo`
  is not yet installed at that point, the validation will fail and the file will be
  removed. Install `sudo` before this line runs (it is in the core package list).
- **`_rebind` in interactive chroot mode**: does not re-bind `resolv.conf` — DNS will
  not work inside the interactive chroot session (option 1 at the end). Known gap.

## Files

- `install-ubuntu-zfs.sh` — the installer (single file, no dependencies beyond live ISO)
- `.agent/README.md` — this file

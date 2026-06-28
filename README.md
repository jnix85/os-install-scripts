# ubuntu-zfs-installer

Bash script to install Ubuntu Server from a Desktop Live ISO onto a single NVMe disk
using ZFS-on-root, with ZFSBootMenu for booting and sanoid for automated snapshots.

## Requirements

- Ubuntu Desktop Live ISO (targeting 26.04; tested path uses `cdebootstrap`)
- Single NVMe disk at `/dev/nvme0n1` — **all data will be destroyed**
- UEFI firmware
- Internet access from the live environment

## What it does

1. Partitions the disk: 1G EFI + 4G bpool + remainder rpool
2. Creates ZFS pools and datasets (see layout below)
3. Runs `cdebootstrap` to install a base Ubuntu system
4. Chroots in and installs kernel, ZFS tools, NetworkManager, sanoid, ZFSBootMenu
5. Configures systemd-boot to chainload ZFSBootMenu
6. Sets up sanoid snapshot schedules and apt pre/post snapshot hooks
7. Optionally creates a non-root user, or sets a root password

## Usage

```bash
sudo bash install-ubuntu-zfs.sh
```

You will be prompted for:
- Ubuntu codename (verify with `lsb_release -cs` on a running 26.04 system)
- Hostname
- Whether to add a non-root user (if yes: username + password; if no: root password)
- Timezone and locale
- `/home` quota (or `none`)

Type `YES` at the confirmation prompt to proceed. The disk is wiped immediately after.

## Logging

All output is logged to `/var/log/os-install.log`. Verbose `cdebootstrap` output
(including every extraction step) is captured there even though only `P:` progress
lines appear on the console.

## Dataset layout

```
rpool/ROOT/ubuntu            /
rpool/ROOT/ubuntu/home       /home
rpool/ROOT/ubuntu/root       /root
rpool/ROOT/ubuntu/srv        /srv
rpool/ROOT/ubuntu/tmp        /tmp
rpool/ROOT/ubuntu/usr/local  /usr/local
rpool/ROOT/ubuntu/var/cache  /var/cache   (snapshots off)
rpool/ROOT/ubuntu/var/lib/docker  /var/lib/docker  (snapshots off)
rpool/ROOT/ubuntu/var/log    /var/log
rpool/ROOT/ubuntu/var/spool  /var/spool   (snapshots off)
rpool/ROOT/ubuntu/var/tmp    /var/tmp     (snapshots off)
rpool/swap                   zvol (auto-sized: equal to RAM ≤8G, half RAM ≤32G, 16G cap)

bpool/BOOT/ubuntu            /boot
```

## Boot chain

```
UEFI firmware
  └─ systemd-boot (ESP /boot/efi)
       └─ ZFSBootMenu EFI binary (/boot/efi/EFI/zbm/vmlinuz.EFI)
            └─ Linux kernel on bpool/BOOT/ubuntu
```

## Snapshot policy (sanoid)

| Dataset | Template | Hourly | Daily | Monthly | Yearly |
|---|---|---|---|---|---|
| `/` | system | 24 | 30 | 6 | — |
| `/home` | home | 48 | 60 | 12 | 2 |
| `/root` | home | 48 | 60 | 12 | 2 |
| `/srv`, `/usr/local` | system | 24 | 30 | 6 | — |
| `/var/log` | logs | — | 30 | 6 | — |
| cache/tmp/docker/spool | ignore | — | — | — | — |

Apt operations trigger additional `pre-apt-*` and `post-apt-*` snapshots automatically.

## First-boot checklist

1. Verify ZFSBootMenu loads at reboot
2. `sudo sanoid --cron --verbose` — confirm snapshots work
3. `sudo apt-get install --reinstall bash` — confirm apt hook creates snapshots
4. Add SSH public key, disable password auth
5. `zpool status` — confirm pool health
6. `systemctl status zfs-import-bpool.service` — confirm bpool imports cleanly

## Agent context

See `.agent/README.md` for architecture decisions, known issues, and notes for AI
assistants working on this codebase.

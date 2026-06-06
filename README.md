# install-coreos

An interactive **wizard** that installs **Fedora CoreOS + Docker (CE) + Tailscale**
onto an **OVH VPS _or_ dedicated server** that you've booted into **rescue mode**.

> Built for and tested against **OVH's rescue environment** specifically (a
> RAM-backed Debian netboot). It handles OVH's quirks end-to-end: rescue login
> (emailed root password *or* a registered SSH key), identifying the real disk
> vs. the ramdisk, and running `coreos-installer` in that container-hostile
> rescue (it extracts the installer image and runs it via `chroot`, avoiding
> overlay/cgroup/pivot_root failures). Works the same on VPS and dedicated.

Everything runs from a single script on your local Linux machine —
`./wizard.sh` — which drives the remote boxes over SSH. The procedure spans
three environments across two reboots, and each is a menu step you can resume:

```
 [local]  1. Configure        collect SSH key, IP, hostname, stream  -> profile
 [local]  2. Build Ignition   Butane -> config.ign  (native butane/podman/docker)
 [rescue] 3. Install to disk   coreos-installer writes CoreOS to the SSD
   ↳ switch OVH to "boot from hard disk" + reboot
 [coreos] 4. Layer & reboot    rpm-ostree: docker-ce + tailscale (one transaction)
 [coreos] 5. Finalize          enable services, `tailscale up`, UDP-GRO tuning
```

## Requirements (local machine)

- A **Butane** engine to transpile the config. The wizard tries, in order:
  **native `butane`** → `podman` → `docker`. The native binary needs no
  containers and avoids podman's rootless quirks — recommended:
  `sudo dnf install -y butane`.
- `ssh`, `scp`, `base64`, `python3` (all standard on Fedora).
- An SSH keypair (Ed25519 recommended).
- *Optional:* **`sshpass`** (`sudo dnf install -y sshpass`) — lets the wizard
  prompt for the OVH rescue password itself in step 3. Without it, SSH prompts
  for the password directly (also fine). The rescue password is never saved.

## Usage

```bash
./wizard.sh
```

On first run it asks for a **profile name** (one profile = one server), walks you
through the **settings menu**, then drops you at the main menu. Pick install
steps `2`→`5` (or `a` to chain them). **Reboot between step 3 and step 4** by
flipping the OVH control panel from rescue to *boot from hard disk*.

### Profiles (main menu option `p`)

Each server is a named **profile** saved at `profiles/<name>.env`. The wizard
remembers the **last-used profile** and reloads it on the next launch, so your
servers' configs persist between runs. From the profiles menu you can:

- **switch** between servers (pick its number),
- **n**ew — create another server profile,
- **d**elete a profile (its backups are kept),
- **r**estore — roll a profile back to an earlier **auto-backup**.

**Auto-backup:** every time you save a profile, the previous version is copied to
`profiles/.backups/<name>-<timestamp>.env` (the newest 10 are kept). Nothing is
lost when you edit. Generated `config.ign` is per-profile too (`profiles/<name>.ign`).

> A legacy top-level `.env` from an earlier version is auto-migrated to
> `profiles/default.env` on first launch.

### Server management (main menu option `m`)

Day-2 operations against the **live, running** server:

- **Exit node** — enable/disable (`tailscale set --advertise-exit-node`). Still
  needs one-time approval in the Tailscale admin console.
- **Public SSH** — restrict port 22 to the **Tailscale network only** (or re-open
  it). FCOS ships no firewall, so this uses **nftables**. **Lockout-safe:** before
  restricting, the wizard reads the box's Tailscale IP and verifies *this machine*
  can SSH it; every change is applied behind a **dead-man's-timer auto-rollback**
  (`systemd-run … nft delete table inet wizard` in ~120 s) that restores access if
  a rule locks you out, and is cancelled only after a fresh connection confirms
  you're still in. Once restricted, the profile manages the box over Tailscale.
- **Firewall** (nftables, default-allow) — list status, **close**/**re-open**
  individual ports (closed = blocked from the public internet; the tailnet stays
  allowed), or **disable** the managed firewall (back to FCOS all-open). The
  ruleset is a single `inet wizard` table with an **input chain only**, so Docker
  published ports and exit-node forwarding (FORWARD/DNAT traffic) keep working. It
  is persisted to `/etc/sysconfig/nftables.conf` + `systemctl enable nftables`.

### Settings menu (option `1`)

All non-secret params persist to `.env` (gitignored) so you only enter them
once. Edit any field by number:

```
== Settings  (saved to .env — secrets excluded) ==
  1) Server IP (OVH)       : 217.182.204.231
  2) Hostname              : dainet-host
  3) CoreOS admin user     : core
  4) Network interface     : ens3
  5) Rescue SSH user (OVH) : root
  6) SSH public key        : ssh-ed25519 AAAAC3Nza…
  7) SSH private key path  : /home/you/.ssh/id_ed25519
  8) Console password      : set (in-memory, not saved)
  s) Save & back   b) Back without saving
```

**Secrets are never written to `.env`:** the console password (only its hash is
used, in-memory) and the Tailscale auth key (prompted at step 5).

### What you'll need on hand

| Step | Needs |
|------|-------|
| 3 (rescue) | Server booted in **OVH rescue mode**. The rescue login is user `root` (settings #5); OVH **emails you a fresh temporary password each time you enable rescue mode**. The wizard prompts for it once (masked, session-only, never saved) — via `sshpass` if installed, otherwise SSH asks directly. Pre-registering an SSH key in OVH's rescue options makes it key-based (leave the password blank). |
| 5 (finalize) | A **Tailscale auth key** (`tskey-auth-…`). Used in-memory, **never written to disk**. |

> **Rescue login = OVH `root` + temporary password.** This is the "username and
> password" prompt you see after rebooting into rescue mode — it's the
> environment where the wizard prepares the disk and runs the installer. It is
> *not* a CoreOS prompt. If your OVH product uses a different rescue username,
> change settings #5.
>
> **Optional console password (settings #8):** sets a password on the admin user
> *and* `root` in the installed CoreOS, so you can log in at the OVH KVM/noVNC
> console or a systemd maintenance prompt. Without it, the installed server is
> SSH-key-only (root login disabled — the FCOS default).

## Notes & assumptions

- **Rescue access (#5):** OVH rescue lets you authenticate **two ways** — choose
  in settings #5: a **password** (OVH emails a fresh one each time you enable
  rescue mode; the wizard prompts for it in step 3, masked, never saved) or an
  **SSH key** you registered in OVH's rescue options (which can be a *different*
  key than the one installed on CoreOS — set its path, or leave blank for your
  default keys/agent).
- **Logging:** everything is logged to `profiles/<name>.log` (timestamped, ANSI
  stripped), including the full output of the rescue install, layering, and
  finalize steps. View the tail any time with main-menu option **`L`**, or follow
  live with `tail -f profiles/<name>.log`. Secrets (passwords, the Tailscale auth
  key) are never logged. A failed step now returns you to the menu so you can
  read the log and retry.
- **SSH key validation:** the public key (#6) is checked with `ssh-keygen` and
  shown as `✓ valid`/`⚠ invalid` in the menu — **building is blocked if it's
  malformed**, so you can't lock yourself out. The private key (#7) is checked
  for existence/validity, loose-permission warnings, and that it **matches** the
  public key being installed.
- **RAM-backed rescue → no container is run.** OVH rescue boots from a ramfs
  root, where container runtimes fail at every layer (overlay-on-ramfs, no
  systemd cgroups, `pivot_root: Invalid argument`). So step 3 does **not** run a
  container: it uses podman only to `pull` + `create` + `export` the installer
  image's filesystem (which never starts a container), then runs
  `coreos-installer` via **`chroot`** with `/dev`, `/proc`, `/sys`, `/run/udev`
  and DNS bound in. `chroot` has none of those constraints. (coreos-installer
  ships no standalone static binary — only the container image — so extracting it
  is the portable way to run it on the Debian rescue host.)
- **FCOS stream (#9):** Fedora CoreOS has **no LTS** — it auto-updates after
  install. Choose the update stream (`stable` default / `testing` / `next`);
  coreos-installer always writes the latest image in that stream.
- **Disk safety:** step 3 lists disks with `lsblk` and makes you *type the
  device name twice* before erasing it. On OVH rescue, `/dev/sda` is often the
  RAM-backed rescue root — pick the persistent SSD by its real size (e.g. `sdb`).
- **Network interface = `auto`:** you don't need to know it. The wizard detects
  the primary NIC on the server (`ip route`) during step 5. Override in settings
  #4 only if you want to force a name (`ens3`, `eth0`, `eno1`, …).
- **Networking:** assumes the server gets its address via **DHCP** on first boot
  (true for OVH VPS — this is why no `--copy-network` flag is used). Some OVH
  *dedicated* servers need static config; if so, the first boot won't get online.
- **Host keys:** the wizard runs `ssh-keygen -R <ip>` at the rescue→CoreOS
  transition, because the host identity legitimately changes after reinstall
  (otherwise you'd hit `REMOTE HOST IDENTIFICATION HAS CHANGED`).
- **Root login is disabled** on CoreOS by design — you log in as the admin user
  (`core` by default) with your SSH key.
- **rpm-ostree needs a reboot:** Docker + Tailscale are layered in a single
  transaction in step 4; step 4 offers to reboot and wait, then step 5 activates
  everything.

## Files

| File | Purpose |
|------|---------|
| `wizard.sh` | The whole interactive installer. |
| `profiles/<name>.env` | Saved per-server config (gitignored; no secrets). |
| `profiles/<name>.ign` / `.rendered.bu` | Generated Ignition / Butane per profile. |
| `profiles/<name>.log` | Timestamped run log (events + remote step output) for debugging. |
| `profiles/.backups/` | Timestamped auto-backups of each profile (newest 10 kept). |
| `.active-profile` | Remembers the last-used profile. |

## Manual equivalents

If you ever need to do a step by hand, the wizard mirrors these:

```bash
# Build Ignition locally (native binary; or swap `butane` for
# `podman run --rm -i quay.io/coreos/butane:release`)
butane --strict < config.bu > config.ign

# In the OVH rescue shell
apt-get update && apt-get install -y podman runc
apt-get clean && rm -rf /var/lib/apt/lists/*
mountpoint -q /var/lib/containers || mount -t tmpfs tmpfs /var/lib/containers
lsblk -dno NAME,SIZE,MODEL,TYPE        # identify the real SSD
podman run --pull=always --privileged --rm \
  -v /dev:/dev -v /run/udev:/run/udev -v "$(pwd)":/data -w /data \
  quay.io/coreos/coreos-installer:release install /dev/sdb -i config.ign

# On CoreOS (after reboot), layer + reboot, then:
sudo systemctl enable --now tailscaled
sudo tailscale up --auth-key=tskey-auth-... --ssh
```

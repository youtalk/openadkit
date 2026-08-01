# AutoSD on R-Car X5H (Strategy A: BSP kernel + AutoSD userspace)

Non-ostree AutoSD 10 rootfs for the R-Car X5H (`r8a78000` / `ironhide`) board,
booted with the unmodified Renesas BSP kernel 6.1.102 over the existing netboot
path (TFTP kernel + NFS root). Validated off-board first by a QEMU gate that
boots the rootfs under a **BSP-constraint-mimic kernel** — a 6.1.y LTS kernel
carrying the same feature gaps as the BSP kernel (no SELinux, no ext4 security
xattrs, no nftables, no erofs) — so every container-runtime question is
answered before board time.

## Folder Structure

- `aib/`: automotive-image-builder manifest (distro `autosd10-sig`, package mode)
- `config/`: containers.conf drop-in shipped into the image
- `kernel/`: mimic-kernel config fragment + build script (QEMU gate only, never for the board)
- `scripts/`: QEMU gate harness and board staging/smoke scripts
- `uboot/`: `bootcmd_autosd` template (site values are filled at session time, not committed)

## QEMU gate semantics

The gate boots the rootfs export under the BSP-constraint-mimic kernel in
QEMU, logs in as root, runs `scripts/gate-guest.sh` inside the guest, and
judges the run by grepping the session log for a fixed set of markers.
`gate-guest.sh` emits the markers; `qemu-gate.exp` judges them by string
match — the two must stay in exact sync.

`gate-guest.sh` never exits nonzero mid-way: every assertion prints a marker
and `GATE_DONE` always prints, no matter which gates failed. All judgement
happens on the host side (`qemu-gate.exp`), by grepping the captured log for
these markers.

Marker vocabulary (greppable, consumed by CI and quoted in the Confluence
results page):

| Marker | Meaning |
| --- | --- |
| `GATE1_LOGIN_OK` | Guest login succeeded. |
| `GATE1_SYSTEMD_STATE=<state>` | `systemctl is-system-running` output, informational. |
| `GATE2_STORE_FS=<fstype>` | Filesystem podman's store actually sat on for the GATE2 probe (expected `ext4`, since GATE2 mounts nothing). Informational — recorded so a reader can see what the GATE2 verdict was measured against, not gated on. |
| `GATE2_EXT4_FAIL_OK` | Podman image load on the ext4 root failed with an unsupported-xattr error — confirms the `EXT4_FS_SECURITY` blocker. |
| `GATE2_EXT4_FAIL_OTHER` | Podman image load on the ext4 root failed for an unrelated reason. |
| `GATE2_EXT4_UNEXPECTED_PASS` | Podman image load on the ext4 root succeeded unexpectedly. |
| `GATE3_STORE_FS=<fstype>` | Filesystem podman's store actually sat on for the GATE3 probe. **Required to equal `tmpfs`** — otherwise a silently-failed tmpfs mount could fall through to the ext4 root underneath and still print `GATE3_TMPFS_OK` for the wrong reason. |
| `GATE3_TMPFS_OK` | Podman container store on tmpfs works, including the capability xattr round-trip. |
| `GATE3_FAIL` | The tmpfs-store probe failed. Not part of the pass path; printed instead of `GATE3_TMPFS_OK` so a human reading the raw log sees why that marker is missing. |
| `GATE4_STORE_FS=<fstype>` | Filesystem podman's store actually sat on for the GATE4 probe. **Required to equal `btrfs`**, for the same reason as GATE3's. |
| `GATE4_BTRFS_OK` | Podman container store on a btrfs-formatted second disk works. |
| `GATE4_FAIL` | The btrfs-store probe failed. Not part of the pass path; printed instead of `GATE4_BTRFS_OK`, same rationale as `GATE3_FAIL`. |
| `GATE5_IPTABLES_OK` | Container networking works with the `iptables` firewall driver. |
| `GATE5_NONE_OK` | Container networking works with the `firewall_driver = "none"` fallback. |
| `GATE5_FAIL` | Neither the iptables driver nor the none-fallback produced working networking. |
| `GATE_DONE` | `gate-guest.sh` reached the end of its run. |

Two markers are deliberately **either/or**, not single-verdict:

- **GATE2 accepts either verdict.** `GATE2_EXT4_FAIL_OK` confirms the xattr
  blocker the survey predicted; `GATE2_EXT4_UNEXPECTED_PASS` is a legitimate
  finding that would simplify the board plan. `GATE2_EXT4_FAIL_OTHER` — an
  unrelated failure — matches neither accepted pattern and therefore fails
  the gate. That is deliberate: it means the ext4-store assumption broke for
  a reason the plan did not anticipate, and that needs a human to look at it.
- **GATE5 accepts either** the `iptables` firewall driver working or the
  documented `firewall_driver = "none"` fallback with a direct container IP.
  `GATE5_FAIL` means neither path produced working container networking. The
  fallback drop-in (`99-gate-fallback.conf`) that path writes is removed
  again at the end of GATE5 regardless of outcome, since Task 8 copies
  `gate-guest.sh` onto the board's persistent NFS root and a leftover
  drop-in there would silently shadow Task 2's `50-x5h.conf` for good; which
  path was taken is already on the record via the `GATE5_*` marker itself.

`GATE3_STORE_FS=tmpfs` and `GATE4_STORE_FS=btrfs` exist because GATE3/GATE4's
mount step (`mount -t tmpfs …` / `mkfs.btrfs` + `mount /dev/vdb …`) checks no
exit status and `gate-guest.sh` never aborts on a failed mount — without this
check, a silently-failed mount would leave `/var/lib/containers` on whatever
was mounted there before (typically the ext4 root), and the podman probe that
follows would still validly pass or fail, just against the wrong filesystem,
printing a `GATE3_TMPFS_OK` / `GATE4_BTRFS_OK` that didn't actually exercise
tmpfs/btrfs at all.

The overall gate (`qemu-gate.exp`) exits 0 only if `GATE1_LOGIN_OK`,
`GATE3_TMPFS_OK`, `GATE3_STORE_FS=tmpfs`, `GATE4_BTRFS_OK`,
`GATE4_STORE_FS=btrfs`, `GATE_DONE`, one of the GATE2 accepted markers, and
one of the GATE5 accepted markers are all present in the session log.

`qemu-gate.exp` waits for the guest-side run with an inactivity timeout (15
minutes with no new `GATE<n>_…` marker line, re-armed on every marker) rather
than one fixed budget for the whole run: the run's total length varies with
TCG emulation speed and isn't a meaningful thing to cap as a single number,
but a guest that goes genuinely silent, or dies outright, still fails fast
with a clear diagnostic instead of a generic "gate did not finish". The
15-minute figure is not arbitrary: GATE5 is the longest stretch with no
re-arming marker output (every command in it is output-suppressed), and its
two 30-iteration poll loops alone cap at 210s each — 420s of pure
network/sleep wall-clock — before accounting for podman process-spawn
overhead on top. See the comment at `qemu-gate.exp`'s `inactivity_timeout`
declaration for the full arithmetic; it is coupled to GATE5's poll bounds in
`gate-guest.sh`, not an independent number.

## Board bring-up

Board time is scarce and one-shot — no rerun scheduled. The order below encodes the plan's
board-safety invariants; do not reorder it.

### 1. Stage the AutoSD NFS root

The CI workflow uploads a flat artifact bundle, not a nested one, so find the tarball rather
than assuming a fixed path:

```bash
find /tmp/x5h-bundle -name x5h-rootfs.tar
```

Then, as root on the NFS server host:

```bash
scripts/stage-nfs-rootfs.sh <x5h-rootfs.tar> <bsp-rootfs-dir> <dest-dir> <testimages-dir>
```

`<bsp-rootfs-dir>` is the existing BSP NFS root — it is only ever read from (to copy
`/lib/modules/6.1.102-yocto-standard`, since overlayfs/veth/bridge/x_tables are all `=m` on
the BSP kernel), never modified. `<testimages-dir>` is the directory holding
`busybox-oci.tar` and `captest-docker.tar` — with the flat CI bundle, that is the same
bundle directory `find` located above.

The script refuses to run if `<dest-dir>` already exists, and prints `OK: staged at
<dest-dir>` plus a `<dest-dir>/.x5h-stage-complete` stamp file on success. If a previous run
was interrupted, `<dest-dir>` can exist without that stamp — treat that as incomplete, not
resumable: `rm -rf <dest-dir>` and rerun the script from scratch. Once staged, add the new
export to `/etc/exports` (mirror the existing BSP export line's options) and run
`exportfs -ra`.

### 2. U-Boot: `printenv` backup, then `bootcmd_autosd`

Before touching the U-Boot environment, capture a full `printenv` to the session log — this
is what makes the next step reversible. The default `bootcmd` is **never** modified; only a
new `bootcmd_autosd` variable is added, from the `uboot/autosd-boot.env` template.

The template's `${...}` placeholders are of two kinds: `serverip`, `kernel_addr_r`, and
`fdt_addr_r` are already defined by this board's U-Boot environment (built-ins); the rest
(`autosd_export_path`, `bootargs_bsp`, `board_ip_config`, `dtb_file`) are operator-supplied
from `x5h-work/HANDOFF.md` (not committed to this repo) and must be `setenv` at the prompt
*before* entering the template's `bootargs_autosd` line — that line is double-quoted, so
U-Boot expands it immediately at `setenv` time, and any placeholder that isn't set yet
silently expands to empty rather than erroring. After entering all three lines, read back
`printenv bootargs_autosd` and confirm it looks complete, then boot the AutoSD NFS root
with:

```
run bootcmd_autosd
```

At the end of the session, re-verify the unmodified BSP boot path still works (power cycle,
default `bootcmd`, BSP NFS root) before releasing the board.

### 3. On-board podman smoke: tmpfs before btrfs

`scripts/board-podman-smoke.sh` is staged onto the NFS root under `/var/lib/autosd-test/`
by step 1. It runs in two phases, and the order is an enforced invariant, not just a
documented one: `btrfs` refuses to run unless a `tmpfs` run has already passed on this boot.

```bash
board-podman-smoke.sh tmpfs                                        # zero board mutation
board-podman-smoke.sh btrfs /dev/disk/by-partlabel/autosd-store     # writes the LUN
```

A genuine `tmpfs` pass stamps `/run/x5h-smoke-tmpfs-passed` (cleared by a power cycle, since
`/run` is tmpfs); `btrfs` checks for that stamp before touching anything and prints
`SMOKE_btrfs_TMPFS_GATE_FAIL` and exits if it is missing. If you deliberately need to run
`btrfs` alone — e.g. after a reboot cleared the stamp but you already know `tmpfs` is fine —
either re-run `tmpfs` again (it costs nothing) or `touch /run/x5h-smoke-tmpfs-passed` by
hand to override.

Each phase prints `SMOKE_<mode>_STORE_FS=<fstype>` right after its mount succeeds (mirroring
`gate-guest.sh`'s `GATE3_STORE_FS`/`GATE4_STORE_FS`) — check it reads `tmpfs` / `btrfs`
respectively, not whatever was mounted underneath, before trusting a later `_PASS`. Every run
terminates in exactly one of `SMOKE_<mode>_PASS` or `SMOKE_<mode>_FAIL`; grep for that pair
rather than assuming silence, or a printed `_FAIL` marker earlier in the log, means the run
already stopped.

`btrfs` is the only step in this task that writes to physical storage — the previously-empty
32 GB UFS LUN. Partitioning that LUN (creating the GPT label) and formatting it
(`mkfs.btrfs -f <partition>`) are both deliberate manual, eyes-on steps done at the board
prompt itself, not by this script: the point where the operator confirms by hand that the
device names the right disk before anything is written to it. `sgdisk` (partitioning) and
`mkfs.btrfs` come from an EPEL 10 repo the image manifest adds — the AutoSD 10 repos alone
do not carry `btrfs-progs`/`gdisk`.

Site values — server IP, export paths, the `ip=` kernel argument, and the DTB filename —
live in `x5h-work/HANDOFF.md` on the operator's machine and are never committed to this
repo.

## Troubleshooting

(findings recorded as discovered)

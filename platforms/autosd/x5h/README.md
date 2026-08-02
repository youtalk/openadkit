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
from `x5h-work/HANDOFF.md` (not committed to this repo) and must all be `setenv` at the
prompt **before the first line of the template**, not merely before `bootargs_autosd` —
`autosd_export_path` is consumed by the *first* line (`autosd_nfsroot`), which is unquoted
and therefore expands immediately, exactly like the double-quoted `bootargs_autosd` line
that follows it. Setting `autosd_export_path` only after `autosd_nfsroot` has already run
still bakes an empty export path into it (`nfsroot=<ip>:,vers=3,tcp`), and that string is
plausible enough to pass a casual glance. After entering all three lines, read back
`printenv autosd_nfsroot bootargs_autosd` and check that the export path and the `ip=`
config are actually present in the output — not just that the strings "look complete" —
then boot the AutoSD NFS root with:

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

A genuine `tmpfs` pass stamps `/run/x5h-smoke-tmpfs-passed` before printing
`SMOKE_tmpfs_PASS`; `btrfs` checks for that stamp before touching anything and prints
`SMOKE_btrfs_TMPFS_GATE_FAIL` and exits if it is missing. The stamp lands in `/run` and
nowhere else because this boot has no initrd — U-Boot loads only `Image` and the DTB, so PID
1 mounts `/run` itself as an API tmpfs — which is what makes the interlock genuinely
boot-scoped: it is cleared by a power cycle, not merely by an `rm`. (If `/run` were ever
*not* a mount here, the stamp would instead land on the NFS server's copy of the export and
would survive power cycles and sessions, silently pre-authorizing a `btrfs` write on a cold
boot — so this is worth re-confirming if the boot path ever changes.) A failed unmount at the
end of a `tmpfs` run withholds the stamp even though `SMOKE_tmpfs_PASS` still prints (the
podman/network result it reports is genuine; only the "board left clean" promise the stamp
makes is at stake) — its own `SMOKE_tmpfs_UMOUNT_WARN` marker says so. If you deliberately
need to run `btrfs` alone — e.g. after a reboot cleared the stamp but you already know
`tmpfs` is fine — either re-run `tmpfs` again (it costs nothing) or
`touch /run/x5h-smoke-tmpfs-passed` by hand to override.

Each phase prints `SMOKE_<mode>_STORE_FS=<fstype>` right after its mount succeeds (mirroring
`gate-guest.sh`'s `GATE3_STORE_FS`/`GATE4_STORE_FS`) — check it reads `tmpfs` / `btrfs`
respectively, not whatever was mounted underneath, before trusting a later `_PASS`. Every run
ends in one of: `SMOKE_<mode>_PASS`; `SMOKE_<mode>_FAIL` (a podman or network check failed);
`SMOKE_<mode>_MODPROBE_FAIL`; `SMOKE_<mode>_MOUNT_FAIL`; or, `btrfs` only,
`SMOKE_<mode>_DEV_FAIL` (bad block device) or `SMOKE_<mode>_TMPFS_GATE_FAIL` (no prior
`tmpfs` pass) — except an invalid or missing mode argument, which prints a plain
`usage: ...` line and exits 2 with **no** `SMOKE_` marker at all, since the script hasn't
chosen a `$MODE` to prefix one with yet. Grep for the full set; if you see none of them, the
run stopped before producing anything trustworthy — treat that the same as a failure, not as
a pass.

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

| Symptom | Cause | Fix |
| --- | --- | --- |
| `aib build` fails during depsolve with `No match for argument: btrfs-progs`, `No match for argument: gdisk` (`osbuild.solver.exceptions.MarkingError: ... missing packages: btrfs-progs, gdisk`) | Both packages were moved out of the AutoSD 10 / CentOS Stream 10 repos upstream and are not present in `baseos`, `appstream`, `automotive`, `autosd`, or `compose`. btrfs is the only viable persistent container store on the X5H's BSP kernel (no `CONFIG_XFS_FS`, no `CONFIG_F2FS_FS`, ext4 has no security xattrs), so `btrfs-progs` is not optional; `gdisk` partitions the board's UFS LUN for it. (The plan's Task 2 note predicted `iptables-nft` would need the same treatment — it did not: `iptables-nft` resolves fine from the existing repos.) | Added EPEL 10 as an `extra_repos` entry in `aib/vars.yml` (`id: epel10`, `baseurl: https://dl.fedoraproject.org/pub/epel/10/Everything/aarch64/`, `gpgcheck: false`). `gpgcheck: false` is deliberate: EPEL is signed with its own key, not the CentOS Stream 10 / Red Hat 10 keys aib trusts globally via `distro_gpg_keys`, and aib's repo schema has no per-repo `gpgkey` field to add a second trusted key just for this repo. |
| `aib build` gets through depsolve and RPM install, then fails on the `add_files` copy: `org.osbuild.copy: ... cp: cannot create regular file '/run/osbuild/tree/etc/containers/containers.conf.d/50-x5h.conf': No such file or directory` | `org.osbuild.copy` (what `add_files` compiles down to) does not create parent directories, and nothing else in the pipeline creates `/etc/containers/containers.conf.d/` — `/etc` itself exists (aib's `init_rootfs_dirs_stage` creates it), but not this subtree. aib does have logic that auto-creates parent directories for `add_files` (`_ensure_parent_directory` in `aib/simple.py`), but it only fires on the glob/path-preserving code path and is never reached for an explicit `source_path` → `path` pair like ours. | Added a `make_dirs` entry for `/etc/containers/containers.conf.d` (`parents: true`, `exist_ok: true`) to `aib/x5h-rootfs.aib.yml` — the same shape `_ensure_parent_directory` itself constructs, aib's own idiom for this. Confirmed from `files/simple.mpp.yml`'s `rootfs` pipeline that the `org.osbuild.mkdir` stage `make_dirs` generates runs strictly before the `org.osbuild.copy` stage `add_files` feeds (mkdir is stage index 4, copy is stage index 6, and osbuild runs a pipeline's stages in the order the manifest lists them), so the directory exists by the time the copy runs. **Do not instead move the drop-in to `/usr/share/containers/containers.conf.d/`** — that path is not one of the documented `containers.conf` search paths (`/usr/share/containers/containers.conf`, `/etc/containers/containers.conf`, `/etc/containers/containers.conf.d/*.conf`, per `containers.conf(5)`); the build would go green and the drop-in would silently never apply, so GATE5 would fall back to `firewall_driver="none"` for a reason unrelated to the missing `NF_TABLES` the gate is actually there to probe — a wrong finding on the exact question this gate exists to answer. |
| The build succeeds and the gate boots, but never reaches a login prompt; the console shows a repeating cycle of `Timed out waiting for device dev-d…SP.device - /dev/disk/by-label/ESP.` → `Dependency failed for boot-efi.mount` → `Dependency failed for local-fs.target` → `Starting emergency.service - Emergency Shell Override - Reboot...` → `systemd-shutdown[1]: Syncing filesystems and block devices.`, and `qemu-gate.exp` eventually fails with `FATAL: no login prompt within 1800s` (or, after the boot-loop guard below, `FATAL: guest rebooted N times without reaching a login prompt`) | **Not fstab** (an earlier fix neutralized fstab, which was necessary but not sufficient — the cycle continued). aib itself generates and installs an *enabled* `boot-efi.mount` unit into the image (`computed-vars.ipp.yml` copies it to `/usr/lib/systemd/system/boot-efi.mount`, requiring `What=/dev/disk/by-label/ESP`, and adds it to `image_enabled_services`), gated by `use_efipart_mount`/`use_efipart`. Neither the bare ext4 export nor the board's NFS root has an ESP partition, so this unit times out (30 s), `local-fs.target` fails, and AutoSD's `emergency.service` — **"Emergency Shell Override - Reboot"** — reboots the guest instead of dropping to a shell. Forever: 37 reboots were observed in one CI run before the harness's fixed budget ran out. Because this unit ships *inside the rootfs* (not something the gate scripts add), it is not gate-specific — it would have hit the board's NFS-root boot too, over serial, in the one-shot session with the operator present. (`selinux-bools.service` also fails in the same console output, right next to this cycle — see the next row; it is not the cause of the loop and should not be conflated with it.) | Set `use_efipart: false` in `aib/vars.yml`. `computed-vars.ipp.yml` only computes `use_efipart` from `use_ukiboot` "if not already in locals()", so a `--define-file` override wins and `use_efipart_mount` (an unconditional `mpp-eval: use_efipart`) follows it to `false`, which stops `boot-efi.mount` from being generated or enabled at all. Every reference to the EFI partition/device (`build.ipp.yml`'s `base_partitions`, `content.ipp.yml`'s `disk_yaml` partition table, `image.ipp.yml`'s `mkfs.fat` stage and mount/copy device map) lives inside the disk-image-building `image` pipeline, which neither export path exercises (`aib build --tar` never requests a disk output; the gate boots the ext4 export directly via `-kernel`; the board netboots the BSP kernel) — so this only removes an unused disk-image code path, not rootfs content. `use_ukiboot` stays at its default (true); nothing it gates depends on `use_efipart`. **Kept the fstab neutralization too** — the image's fstab genuinely was written for a disk image, and it keeps the gate and board paths symmetric — just don't credit it with fixing this particular loop; a different root cause was hiding behind it. Also hardened `qemu-gate.exp` with a boot-loop guard: it counts `Booting Linux on physical CPU` (the kernel's first boot line, printed once per boot) and fails fast with a distinct diagnostic on the third occurrence, instead of waiting out the full 1800 s budget to notice a loop that was obvious by the second boot — this cost ~2.5 minutes to diagnose the `boot-efi.mount` cause above, instead of 30. |
| `selinux-bools.service` fails during boot (`[FAILED] Failed to start selinux-bools.service - Enable selinux booleans.`) | Expected, not a bug: the BSP kernel this gate mimics has no `CONFIG_SECURITY_SELINUX`, so `setsebool` has nothing to operate on. This is itself a real survey answer about running AutoSD userspace on the BSP kernel, not an artifact of the reboot-loop bug above (the two appear adjacent in the console log, but `selinux-bools.service` failing does not cause a reboot — `emergency.service` reacting to the fstab/ESP failure does, per the row above). | None needed; recorded here as the expected result for this gate run. |

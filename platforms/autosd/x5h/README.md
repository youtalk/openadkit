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
| `GATE2_EXT4_FAIL_OK` | Podman image load on the ext4 root failed with an unsupported-xattr error — confirms the `EXT4_FS_SECURITY` blocker. |
| `GATE2_EXT4_FAIL_OTHER` | Podman image load on the ext4 root failed for an unrelated reason. |
| `GATE2_EXT4_UNEXPECTED_PASS` | Podman image load on the ext4 root succeeded unexpectedly. |
| `GATE3_TMPFS_OK` | Podman container store on tmpfs works, including the capability xattr round-trip. |
| `GATE4_BTRFS_OK` | Podman container store on a btrfs-formatted second disk works. |
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
  `GATE5_FAIL` means neither path produced working container networking.

The overall gate (`qemu-gate.exp`) exits 0 only if `GATE1_LOGIN_OK`,
`GATE3_TMPFS_OK`, `GATE4_BTRFS_OK`, `GATE_DONE`, one of the GATE2 accepted
markers, and one of the GATE5 accepted markers are all present in the
session log.

## Board bring-up

(filled in by the board-prep task; operational values live outside this repo)

## Troubleshooting

(findings recorded as discovered)

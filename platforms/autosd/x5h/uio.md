# X5H UIO: reaching the SoC's accelerator blocks from userspace

The X5H describes a large set of accelerator and capture blocks — image
processing, ISP, video capture, CSI receivers, the DSP subsystem, the RPMsg
shared-memory and IPI windows — as `generic-uio` device-tree nodes. Nothing
in the kernel drives them; they are handed to userspace through
`uio_pdrv_genirq`, which maps each node's register window and delivers its
interrupt to whatever opens `/dev/uioN`.

This is how the Renesas ONNX Runtime execution provider is expected to reach
the NPU, so it is a prerequisite for that work rather than an unrelated
platform detail. It is not sufficient on its own — see
[What this does not cover](#what-this-does-not-cover).

## The trap: loaded, but bound to nothing

`uio_pdrv_genirq` ships wildcard OF aliases (`of:N*T*C*`), so udev autoloads
it during boot on the first unmatched device-tree node. But the module's
`of_match_table` starts empty and is filled from the `of_id` module
parameter, so a load with no parameter binds nothing at all.

The failure is silent and reads as a device-tree problem. `lsmod` shows the
module present, the device-tree nodes are there and carry no `status`
property (so they are enabled), and yet `/dev/uio*` does not exist,
`/sys/class/uio` is empty, and `dmesg` prints nothing — there is no probe to
fail. Every symptom points at the dtb, and the dtb is fine.

`config/x5h-uio.conf` supplies the parameter:

```
options uio_pdrv_genirq of_id=generic-uio
```

A `modprobe.d` drop-in is the right place for it precisely because the
module is modprobe-loaded. The alternative — `uio_pdrv_genirq.of_id=` on the
kernel command line — would mean editing `bootargs_autosd_ufs`, which is
coupled to the self-boot PARTUUIDs in three places that must agree (see
[selfboot.md](selfboot.md)); this needs none of that.

## Verified on hardware, 2026-08-10

On the self-booted `6.1.102-autosd` board:

| measure | value |
|---|---|
| `generic-uio` nodes in the live device tree | 201 |
| UIO devices bound | 177 (`/dev/uio0` … `/dev/uio176`) |
| probe errors in `dmesg` | none |

The devices come up named from each node's `linux,uio-name`, which is what
makes them addressable by something other than a probe-order index:

| name prefix | count | block |
|---|---|---|
| `vin_*` | 80 | video capture |
| `rsip_e_*` | 20 | RSIP engine |
| `rfso_*` | 20 | RFSO |
| `ims_*` | 8 | IMR-LX7 scaler |
| `ostm_*` | 6 | OS timer |
| `vspx_*`, `vcp5_*`, `tisp_*`, `imr_*`, `fcpvx_*`, `fcpc_*`, `csi_*`, `cisp_*` | 4 each | VSPX / DSP subsystem / ISP / CSI |
| `rpmsg_shm0`, `rpmsg_ipi0` | 1 each | CR52 shared memory and IPI |

Mappings resolve to the addresses the device tree declares — `rpmsg_shm0`
becomes `uio0` with `map0` at `0x96600000`, size `0x50000`, matching the
`cr52_ram0@96600000` reserved-memory region.

**Sibling nodes that share a register window do bind.** Several blocks are
described as one node for the window plus additional nodes carrying the same
`reg` and a different interrupt each; `irq_vcp5_00_01` comes up at
`0xc3000000`, the same address as `vcp5_0`. This pattern was in doubt and is
now settled, which matters because the NPU is described the same way.

24 of the 201 nodes did not bind, with nothing logged. Not investigated —
none of them are in a subsystem this branch depends on.

### Checking it

```sh
ls -d /sys/class/uio/uio* | wc -l
for d in /sys/class/uio/uio*; do echo "$(basename "$d") $(cat "$d/name")"; done
```

An empty result on a board whose device tree has `generic-uio` nodes means
the drop-in did not reach the image, or the module was loaded before it was
read. `modprobe -r uio_pdrv_genirq && modprobe uio_pdrv_genirq` re-reads it
without a reboot; the module binds nothing beforehand, so unloading it is a
no-op.

## What this does not cover

Enabling UIO does not by itself make the NPU reachable. Three things are
still missing, and none of them is fixed by this drop-in:

- **The NPU's device-tree nodes are absent from the board's dtb.** The board
  boots `r8a78000-ironhide-uio-autosd.dtb`, built from the public
  `renesas-rcar/linux-bsp` tree pinned by `kernel/build-bsp-kernel.sh`. That
  tree's UIO dtsi describes the ISP, IMR, VSPX, DSP, capture and RSIP blocks
  but has no NPU node — only the NPU's SMMUs, disabled. The vendor SDK's own
  UIO device-tree source does describe the NPU blocks as `generic-uio`; those
  values are SDK material and stay out of this repository.
- **`/dev/cmem_other*`** — the contiguous-memory devices the runtime opens.
  No such driver exists in the pinned kernel source or in the image's module
  tree.
- **`/dev/npuc*`** — the runtime opens these, and no `linux,uio-name` in the
  vendor source produces that name, so something else supplies them.

## Related

- [UFS self-boot](selfboot.md) — the boot path and why `bootargs` is
  expensive to change.
- [CR52 dual boot + RPMsg](rpmsg-dualboot.md) — the kernel-space RPMsg path,
  which is what the board uses today; `rpmsg_shm0`/`rpmsg_ipi0` are the
  userspace alternative the same hardware also exposes.

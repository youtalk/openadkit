# X5H NPU bring-up: what the hardware still needs

What has to be true before the ONNX Runtime Renesas execution provider can
reach the NPU from AutoSD, in what order to do it, and how to get back if a
step goes wrong.

> **Status: investigated on hardware 2026-08-10, not yet executed.** Every
> "already true" claim below was measured on the board; everything under
> Stage 1 and Stage 2 is designed and untried. The measurements are what make
> the sequencing safe to trust, so they are stated as measurements rather
> than as background.

> **Numbers live elsewhere.** Flash offsets, device-tree addresses and
> interrupt numbers come from the vendor SDK and are not in this repository —
> same boundary as [cr52-slot-update.md](cr52-slot-update.md). This document
> carries the procedure, the reasoning and the traps. Read the values from
> the SDK's own flash-target definition at the time you run the steps.

## What the runtime actually needs

The execution provider reaches the hardware entirely from userspace. It opens
two families of device:

- **`/dev/npuc0`, `/dev/npuc1`** — the NPU clusters. These are ordinary UIO
  devices: the vendor's NPU device tree declares them `generic-uio` with a
  `linux,uio-name`, and the userspace side picks their register windows with
  `mmap` offsets that are multiples of the page size, which is the UIO map
  convention. See [uio.md](uio.md).
- **`/dev/cmem_other*`** — contiguous memory, served by an out-of-tree driver
  that has to be loaded once per boot.

So there is no NPU kernel driver to find or write. What is missing is device
tree, one module, and possibly one firmware component.

## What the board already has

**The NPU firmwares are already flashed.** Both clusters' firmware is present
at the offsets the vendor's flash-target definition names, and matches the
package byte for byte across every S-record range — 139,230 chunks each, zero
mismatches. This was the step that looked like it would need a bench visit
and a serial flash writer. It does not: it is done.

**The UIO mechanism works.** 177 of the board's `generic-uio` nodes bind and
come up named, with mappings resolving to their declared addresses, once
`uio_pdrv_genirq` is given its `of_id` — which `config/x5h-uio.conf` now
supplies. Nodes that share one register window with separate interrupts bind
correctly, which is the pattern the NPU uses.

**One flash component differs.** The board carries the stock second-stage IPL
for the realtime cluster; the AI package ships a variant of it. The package
documents the change as switching DRAM ECC off *for improving performance*,
and ships the stock binary alongside so it can be put back. The manual
separately states that the SDK's IPL cannot run the package's samples, which
is in tension with a change described as a performance tweak. Nothing in the
documentation settles it, so Stage 1 below is written to find out cheaply
rather than to assume either way.

## Stage 0: capture what you would otherwise lose

Do this before anything else, and keep the results off the board.

- Read the whole extent of both realtime firmware slots to files. Stage 2
  writes into the same address space, and one of these slots holds this
  branch's RPMsg responder — see the trap below.
- Read the current contents of the flash region Stage 2 would rewrite, so a
  restore is a copy rather than a rebuild.
- Dump the U-Boot environment over serial with `printenv`. Self-boot can also
  be restored from `selfboot-env.txt` on the boot partition with no host at
  all ([selfboot.md](selfboot.md)), so this is belt and braces.

## Stage 1: bring the NPU up with no flash writes at all

Everything here is remote-capable. None of it touches flash.

1. **Merge the NPU device tree into the board's.** Three additions: the NPU
   cluster and UIO nodes, a root-level `/cmem` node carrying a
   `memory-region` phandle list, and the reserved-memory regions both refer
   to. Two of the vendor's regions collide with regions the board already
   defines — one against the board's CMA area, one against a region that
   cannot move. The vendor's memory-map appendix marks which addresses are
   redefinable and which are fixed; resolve the collisions from that table
   rather than by picking whichever side looks easier.
2. **Build the cmem driver.** It is public and needs no SDK access:
   `github.com/renesas-rcar/cmem`, branch `rcar_gen5`, GPL-2.0. **Pin commit
   `e67f473c`, not HEAD.** HEAD adapts the driver to kernel 6.12 —
   `follow_pfnmap_start`, `vm_flags_set`, and the one-argument
   `class_create` — and every one of those postdates the 6.1 this board runs.
   `e67f473c` uses the older forms and is expected to build unpatched. Pin
   the SHA the way `kernel/build-bsp-kernel.sh` pins the BSP tree: the branch
   is mutable, the commit is the source of truth.
3. **Load it and confirm the devices appear.** The driver takes its region
   sizes as a module parameter array and creates one `cmem_other` device per
   region, so the count has to match what the runtime opens. Confirm
   `/dev/npuc*` and `/dev/cmem_other*` both exist before going further —
   `board/npu-probe`-style output, not inspection by eye.
4. **Run the critical experiment.** The ONNX Runtime release ships
   precompiled artifacts for two sample models, so this needs no compiler
   licence: deploy the runtime container, run the latency evaluation, and
   assert positively that the Renesas EP executed subgraphs rather than
   inferring it from a run that merely completed.

If step 4 passes, the stock IPL is sufficient and Stage 2 is a performance
question to schedule whenever someone is next at the bench. If it fails in a
way that points at the IPL, Stage 2 becomes necessary and its cost is now
known rather than assumed.

## Stage 2: the IPL, only if Stage 1 shows it is needed

Two traps, both of which cost real work if hit.

**The vendor's flash procedure overwrites both realtime firmware slots.** Its
write list includes the stock payloads for them, and one of those slots
currently holds this branch's RPMsg responder — measured, not assumed: its
contents differ from the vendor payload in every chunk compared. Running the
procedure unedited breaks the CR52 round trip and therefore
`selfboot-smoke.sh`. Edit the flash-target definition to disable every entry
except the single component being changed.

**Never enable the tool's Linux-files stage.** Alongside the bootloader
entries, the same definition can repartition the storage and write a kernel,
device tree and root filesystem. That is what would destroy the self-boot
partitions. The vendor's own transcript skips it; keep it skipped.

Beyond that, the write itself needs the serial flash writer, two USB-serial
connections, and DIP switch changes, followed by a boot-mode command and a
power cycle.

**It is technically possible to do this from Linux instead.** The flash the
component lives in is exposed as an MTD device, the target offset is
erase-block aligned, and the writable node exists. Do not take that option
for the first attempt: a failed IPL write is recoverable only through the
serial flash writer with physical switch changes, so the one operation whose
failure mode requires someone in the room is the wrong one to do while nobody
is.

## Recovery

- **IPL** — the package ships the stock binary it replaces; write it back the
  same way it was replaced.
- **Realtime firmware slots** — restore from the Stage 0 copies.
- **U-Boot environment** — re-import `selfboot-env.txt` from the boot
  partition ([selfboot.md](selfboot.md)). This needs no host, which is the
  point of it living on the board.
- **A board that will not boot at all** — the serial flash writer, DIP
  switches and a power cycle. This is the floor, and it is why Stage 2 is a
  bench operation.

## What the address space looks like

Worth knowing before touching anything, because it is the reason Stage 1 and
Stage 2 are separable at all:

- The flash tool's storage address space is a small unpartitioned logical
  unit — realtime firmware slots, the secure payloads, U-Boot and the NPU
  firmwares all live there. **It is a different logical unit from the one
  carrying the self-boot partitions**, so writes there cannot reach
  `x5h-boot`, `x5h-root` or `autosd-store`. Address logical units by path and
  by property, never by device letter: the letters move between boots
  ([selfboot.md](selfboot.md)).
- The bootloader components proper live in a separate flash, reachable from
  Linux as an MTD device.

## Related

- [UIO](uio.md) — the mechanism `/dev/npuc*` arrives through, and the drop-in
  that enables it.
- [CR52 slot update](cr52-slot-update.md) — the established procedure for
  writing that logical unit from Linux, and the slots Stage 2 must not touch.
- [UFS self-boot](selfboot.md) — the partition layout Stage 2 must not
  disturb, and the environment-restore path.

# X5H dual boot: CR52 FreeRTOS under AutoSD, with RPMsg

Runs a FreeRTOS payload on the CR52 realtime core while AutoSD runs on
the CA720AE cluster, using the kernel remoteproc/RPMsg stack. No flash
is written: the CR52 firmware is loaded at runtime through sysfs, and a
power cycle always returns the board to its default boot.

## What the kernel already provides

The 6.1.102-autosd image and `r8a78000-ironhide-uio-autosd.dtb` ship
with `CONFIG_RCAR_GEN5_REMOTEPROC=y`, `CONFIG_RCAR_MFIS=y`,
`CONFIG_RPMSG_VIRTIO=y` (`rpmsg_char`/`rpmsg_ctrl` as modules), the
`cr52_1` remoteproc node on MFIS channel 1, and its reserved-memory
carveout. Nothing needs rebuilding to use them.

## Prerequisites

- A CR52 firmware ELF with a resource table and an RPMsg echo service,
  staged as `/lib/firmware/rpmsg-echo-cr52.elf` on the target rootfs.
  (Built from the vendor FreeRTOS BSP RPMsg sample for this board with
  MFIS channel 1 — the channel must match the device tree.)
- `rpmsg-ping` (static aarch64, built from `scripts/rpmsg-ping.c`) and
  `scripts/rpmsg-smoke.sh` on the target.

## Procedure

1. Boot the target OS (BSP Yocto default boot, or AutoSD via
   `run bootcmd_autosd` netboot).
2. Preflight (read-only): `sh rpmsg-smoke.sh --check`
   — confirms the `cr52_1` remoteproc exists and reports its state.
3. Full smoke: `sh rpmsg-smoke.sh -f rpmsg-echo-cr52.elf \
   -s rpmsg-client-sample -n 100 -c 3`
4. Expect `RPMSG_PING_PASS n=100 ...` per cycle and a final
   `RPMSG_SMOKE_PASS cycles=3 msgs=100`.

## Notes

- If the CR52 is already `running`/`attached` at preflight, something
  else (boot firmware) started it; record the state before touching it,
  then `echo stop` brings it to `offline` for a clean load.
- The kernel ships an in-tree `rpmsg_client_sample` sample driver,
  staged as a module in the AutoSD modules tree, that binds a channel
  named exactly `rpmsg-client-sample` and runs its own message exchange
  if loaded. If it auto-loads ahead of the smoke, it can win the
  channel and contend with `rpmsg-ping` for the endpoint, so the
  preflight should check `lsmod` for it and be prepared to unload it
  before the full smoke.
- Recovery from any wedge: power cycle. The default boot path is never
  modified by this procedure.

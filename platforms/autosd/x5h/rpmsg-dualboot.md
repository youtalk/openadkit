# X5H dual boot: CR52 FreeRTOS under AutoSD, with RPMsg

Runs a FreeRTOS payload on the CR52 realtime core while AutoSD runs on
the CA720AE cluster, using the kernel remoteproc/RPMsg stack. No flash
is written by this procedure: `echo start` on the `cr52_1` remoteproc
publishes the resource table into the CR52's reserved-memory carveout,
allocates the vrings, and enables the MFIS doorbell for a CR52 that is
already executing — it does not load an ELF onto the core or release
it from reset. A power cycle always returns the board to its default
boot.

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
- `rpmsg-ping` (static aarch64, built from `scripts/rpmsg-ping.c`;
  takes `-s <service>`, `-n <count>`, and `-t <timeout_s>`) and
  `scripts/rpmsg-smoke.sh` on the target. `rpmsg-smoke.sh` resolves
  `rpmsg-ping` relative to its own directory first, falling back to
  `PATH`, so `rpmsg-ping` must be executable and either sit next to
  `rpmsg-smoke.sh` or be reachable on `PATH`.

## Procedure

1. Boot the target OS (BSP Yocto default boot, or AutoSD via
   `run bootcmd_autosd` netboot).
2. Preflight (read-only): `sh rpmsg-smoke.sh --check`
   — confirms the `cr52_1` remoteproc exists, reports its state, and
   ends with the `RPMSG_SMOKE_CHECK_DONE` marker. Any problem found
   before that point instead prints `RPMSG_SMOKE_FAIL cycle=0
   reason=<...>` and exits 1; `--check` makes no state changes either
   way.
3. Single-cycle probe: `sh rpmsg-smoke.sh -f rpmsg-echo-cr52.elf \
   -s rpmsg-client-sample -n 100 -c 1` — establishes that one
   load/start/ping/stop round trip works.
4. Multi-cycle probe, run separately: `sh rpmsg-smoke.sh \
   -f rpmsg-echo-cr52.elf -s rpmsg-client-sample -n 100 -c 3` — probes
   whether the CR52 survives repeated Linux-side vdev teardown, which
   is a different question from step 3. Because `stop` is a no-op on
   this SoC (see Notes), a cycle boundary only tears down the Linux
   side: the CR52 keeps its ring indices and its already-bound
   endpoint while Linux allocates fresh vrings with reset indices on
   the next `start`. A failure at cycle 2 or later is therefore an
   expected, non-blocking outcome of that mismatch, not a regression —
   treat a passing step 3 as the meaningful result and don't escalate
   on a later-cycle failure by itself.
5. Expect `RPMSG_PING_PASS n=100 ...` per cycle and a final
   `RPMSG_SMOKE_PASS cycles=<c> msgs=100`. A failing cycle instead
   prints `RPMSG_SMOKE_FAIL cycle=<i> reason=<...>` and the script
   exits 1.

## Notes

- If the CR52 is already `running`/`attached` at preflight, something
  else (boot firmware) started it; record the state before touching it,
  then `echo stop` brings it to `offline` for a clean load.
- A `reason=service_timeout` after a successful `start` most likely
  means the CR52 is currently not running RPMsg echo firmware, not
  that the RPMsg stack is broken — `start` never fails to bring up a
  CR52 that is already executing, it just has nothing on the other end
  to announce a channel. Don't escalate on this alone before the
  firmware flashed into the CR52 Cluster0 Core1 slot has been
  identified; that is an open question this procedure does not
  resolve.
- The kernel ships an in-tree `rpmsg_client_sample` sample driver,
  staged as a module in the AutoSD modules tree, that binds a channel
  named exactly `rpmsg-client-sample` and runs its own message exchange
  if loaded. The rpmsg bus announces a `MODALIAS` on every channel
  add, so under systemd-udevd this module auto-loads on *every* smoke
  cycle, not just once at boot — unloading it once does not stop it
  coming back on the next cycle. Check for it and remove it before a
  run:
  ```
  lsmod | grep rpmsg_client_sample
  rmmod rpmsg_client_sample
  ```
  and block it from coming back with a rootfs-only blacklist (no flash
  write):
  ```
  echo 'blacklist rpmsg_client_sample' > /etc/modprobe.d/x5h-rpmsg.conf
  ```
  If it wins the channel before it is removed, the damage outlives the
  `rmmod`: OpenAMP binds the endpoint's destination address to the
  first remote sender and never re-binds, so the CR52 keeps echoing to
  the sample driver's address and `rpmsg-ping` sees `rx_timeout` on
  `seq=0` even after the module is gone. Because `stop`/`start` do not
  touch the CR52 itself (see above), only a CR52-side restart clears
  this — a Linux-side `stop`/`start` cycle will not.
- Recovery from any wedge: power cycle. The default boot path is never
  modified by this procedure.

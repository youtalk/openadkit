# OTA update hook for the X5H board

This document is the contract between an update agent and the hook `/usr/sbin/x5h-ota`. The update agent is the program that gets an update from a server and puts it on the board. The agent needs only this document. It does not need the hook source.

The hook runs as root. It updates two things on the board in the demo role:

- The VisionPilot container image `localhost/x5h-visionpilot:latest`.
- The CR52 realtime firmware, which is the payload in the CR52 boot slot and the ELF file `/lib/firmware/actuation_x5h.elf`.

The hook does not update the kernel, the root file system, the device tree or U-Boot. For those, the hook has no command.

## Commands

| Command | Who calls it | What it does |
|---|---|---|
| `x5h-ota install <component> <source>` | update agent | Gets one artifact, checks it, and stages it. It changes nothing that runs |
| `x5h-ota activate` | update agent | Applies every staged component |
| `x5h-ota status` | update agent, operator | Prints one line per component |
| `x5h-ota rollback` | update agent | Discards staged components. If none are staged, it restores the previous version of the components that the last `activate` applied |
| `x5h-ota verify` | `x5h-ota-verify.service` | Judges the start after an update, at the next boot. The agent never calls it |
| `x5h-ota init <payload-file>` | administrator, once per board | Records the CR52 payload that is in the slot now as version `baseline` |

`<component>` is `visionpilot` or `cr52`. A command with the wrong number of arguments fails with `reason=usage`. A command name that the hook does not know fails with `X5H_OTA_FAIL usage reason=usage`.

### Sources

`<source>` is one of these:

- A digest reference: `<repository>@sha256:<64 lowercase hex digits>`. The repository is `ghcr.io/youtalk/x5h-visionpilot` for `visionpilot` and `ghcr.io/youtalk/x5h-cr52-si` for `cr52`. The hook refuses a tag reference, another repository, and the repository of the other component. The reason is `bad_source`.
- An absolute path of an OCI archive file. The path must name a regular file, and it must not contain a `:`. Any other value, such as a relative path, is `bad_source`.

An archive must not carry the name of a hook tag: `localhost/x5h-visionpilot:latest`, `localhost/x5h-visionpilot:previous` or `localhost/x5h-visionpilot:staged`. If it does, the hook puts its own tags back, drops the image, and fails with `reason=bad_source`.

### Credentials

Only podman reads the registry credentials. The agent sets `REGISTRY_AUTH_FILE` in the environment of the hook. The hook never reads that file and never stores a credential. If the pull fails because of a wrong credential or no network, the reason is `pull_failed`.

### What every install checks

The hook trusts nothing in the source. A digest proves that the bytes are the published ones. It does not prove that they suit the board. So the hook checks these on every `install`:

- The label `x5h.ota.component` equals the component. If not, `bad_label`.
- The label `org.opencontainers.image.version` is 1 to 64 characters from `A-Za-z0-9._-`. If not, `bad_version`.
- The image architecture is `arm64`. If not, `bad_arch`.
- For `cr52`, the files `/cr52/slot.bin` and `/cr52/actuation_x5h.elf` exist as regular files, and their SHA-256 values equal the labels `x5h.ota.sha256` and `x5h.ota.elf_sha256`. If not, `bad_hash`.
- For `cr52`, the payload fits in the slot extent. If not, `too_large`.
- For `cr52`, the first 32 bytes of the payload are a Cortex-R52 vector table. If not, `no_vector_table`.
- For `cr52`, the ELF starts with the ELF magic bytes. If not, `no_elf_magic`.

A new `install` of a component replaces the staged update of that component.

## Output

The hook prints markers on stdout, one per line. The agent reads only the lines that start with `X5H_OTA_`.

```
X5H_OTA_PASS <command>
X5H_OTA_FAIL <command> reason=<slug>
X5H_OTA_REBOOT_REQUIRED
X5H_OTA_STATUS component=<cr52|visionpilot> version=<version> state=<state> [slot=match|mismatch]
```

A pass exits with 0. A failure exits with 1. If the hook needs a reboot, it prints `X5H_OTA_REBOOT_REQUIRED` before the final `PASS` or `FAIL` line. The hook never reboots the board itself, with one exception: `verify` can reboot after a failed check (see the flow below).

Every command takes a lock, and it waits up to 600 s for it. If it cannot get the lock, the reason is `lock`. This includes `status`. So `status` waits while a `verify` or a restart of the launch manager runs.

### Reasons

| Command | Reasons |
|---|---|
| any command | `usage`, `lock`, `state_write` |
| `install`, `init`, `activate`, `rollback` | `verify_pending`: a check is still pending (see below) |
| `install` | `bad_component`, `bad_source`, `pull_failed`, `bad_label`, `bad_version`, `bad_arch` |
| `install cr52` | also `no_conf`, `mount_failed`, `bad_hash`, `too_large`, `no_vector_table`, `no_elf_magic` |
| `init` | `no_conf`, `no_firmware`, `slot_not_found`, `slot_ambiguous` |
| `activate` | `nothing_staged`, `no_conf`, `no_firmware`, `too_large` (the staged payload no longer fits the extent), `slot_not_found`, `slot_ambiguous`, `write_mismatch`, `firmware_write` |
| `activate`, `verify` | `verify_failed`, `rollback_failed` |
| `verify` | `reboot_required`: `verify` ran in the same boot as the change. It changed nothing |
| `rollback` | `rollback_failed`, `nothing_to_roll_back` |

The reason `state_write` means that the hook could not write its state, for example because the disk is full.

### Status states

`status` prints `cr52` first, then `visionpilot`. A component with no installed version shows `version=none state=ok`. The state is one of these:

| State | Meaning |
|---|---|
| `ok` | The installed version passed its check, or no update ever ran |
| `staged` | An update is installed but not activated |
| `verifying` | An update is applied and its check is not finished |
| `rolling_back` | A rollback is applied and its check is not finished |
| `rolled_back` | The previous version is back and passed its check |
| `rollback_failed` | The rollback failed. A person must take over (see the last section) |

A state other than `verifying` or `rolling_back` is final. The first rule that applies decides the state:

1. If `pending` names the component, the state is `verifying` (an update) or `rolling_back` (a rollback).
2. If the last rollback failed, the state is `rollback_failed`. This wins over `staged`.
3. If an update is staged, the state is `staged`.
4. Otherwise, the state is the one that the installed version recorded: `ok` or `rolled_back`.

The `slot=` field appears only on the `cr52` line, and only if a CR52 version is installed. The value `match` means that the slot bytes and the ELF on Linux equal the recorded version. The value `mismatch` means that they differ, or that the hook cannot check them.

## The pending check

When `activate` or `rollback` applies a change, the hook writes a file named `pending` first. The file stays until a check gives a final result. While `pending` exists, only `status` and `verify` run. The other commands fail with `reason=verify_pending`.

For each component that `pending` names, the check needs these conditions:

- `cr52`: the journal of `x5h-si-link.service` in this boot shows two `hb seq=` lines with a rising number, and `slot=match` holds. The hook does not read `fault=`.
- `visionpilot`: the journal of this boot shows the backend ready line `[MergedBackend] Ready` after the start, and `localhost/x5h-visionpilot:latest` is the installed image.

The hook looks up to 61 times, 2 s apart, which is about 120 s. It counts looks, not clock time. The board has no RTC, and chrony can step its clock.

The checks need no camera frames. So they also pass with the simulator off.

`verify` judges a change only at a boot after the boot that applied it. In that first boot, the old versions still meet every condition: the old CR52 firmware still sends heartbeats, and the old ready line is already in the journal. So in the same boot, `verify` prints `X5H_OTA_REBOOT_REQUIRED` and `X5H_OTA_FAIL verify reason=reboot_required`, and it changes nothing. The agent never runs `verify` itself.

## The agent flow

1. For each component of the campaign, run `install`. If it fails, nothing that runs has changed. The agent can fix the cause and try again, or stop. To cancel a campaign, run `rollback`. It discards what is staged, and the board needs no reboot.
2. Run `activate`. It applies every staged component in one call. Use one `activate` per campaign (see Rollback below). Read the result as described below.
3. If the output has `X5H_OTA_REBOOT_REQUIRED`, reboot the board with a full `systemctl reboot`. The hook does not reboot it. Do not use a soft reboot or kexec. A soft reboot keeps the boot ID, so `verify` refuses to judge (`reboot_required`). A kexec does not restart the CR52, so the check then sees the old firmware.
4. After the boot, wait for the final result. Order the agent unit `After=x5h-ota-verify.service` only. Never put `Wants=` or `Requires=` on that unit, because the agent never starts the check. As an alternative, poll `x5h-ota status` until no line shows `verifying` or `rolling_back`.
5. Read the states. `ok` is a success. `rolled_back` means that the check of the update failed and the board runs the previous version again. `rollback_failed` needs a person.

Give `activate` a timeout of at least 900 s. The worst case is the 600 s lock wait plus the restart path: two checks of about 120 s each and two stops of the launch manager. Each look also takes some time, so 1000 s leaves a margin. A killed `activate` can leave `pending`. Then every command except `status` and `verify` fails with `verify_pending`, until the next demo boot judges the change.

### Activate with a reboot

If `cr52` is staged, or `score-lm.service` is not active, `activate` prints `X5H_OTA_REBOOT_REQUIRED` and then `X5H_OTA_PASS activate`. The update is applied but not judged. The agent reboots the board.

`x5h-ota-verify.service` runs at the next boot and judges the update. The unit runs only if `pending` exists and the kernel command line has `x5h.role=demo`. In another role, `pending` stays until the next demo boot, and all commands except `status` and `verify` fail with `verify_pending`.

The unit also needs UFS0, the disk that holds the CR52 slot. On some boots, Linux fails to start the UFS0 link, and the kernel log shows `c0a80000.ufs: link startup failed`. The CR52 still runs the firmware in the slot, but Linux cannot see the slot. Then the unit does not run, the hook judges and restores nothing, and `status` keeps `verifying`. If `status` still shows `verifying` 5 minutes after the boot, reboot the board again. The next boot judges the update. In such a boot, an `activate` with `cr52` fails with `slot_not_found` and changes nothing. Reboot and try again.

If the check fails, the hook restores the previous version of every pending component. Then the next step depends on the pending components:

- If `cr52` is pending, or `score-lm.service` is not active, the hook prints `X5H_OTA_FAIL verify reason=verify_failed` and runs `systemctl reboot`. **The board reboots once more by itself.** The agent must expect this second reboot. Until the next boot judges the rollback, `status` shows `rolling_back`. After that boot, the state is `rolled_back` (the previous version passed) or `rollback_failed` (it failed too).
- Otherwise, only `visionpilot` is pending and the launch manager is active. Then `verify` restarts the launch manager as in the restart path below and judges the rollback itself, with no reboot. After that check, it prints `X5H_OTA_FAIL verify reason=verify_failed` for an old image that passed (`rolled_back`). For an old image that failed too, it prints `X5H_OTA_FAIL verify reason=rollback_failed` (`rollback_failed`).

The agent reads the final state from `status`. After `rollback_failed`, the hook does not reboot or restart again.

If the board does not come back in 90 s after a reboot, a person presses SW7. The check then runs as usual.

### Activate with a restart

If only `visionpilot` is staged and `score-lm.service` is active, there is no reboot. The hook stops the launch manager, sends `USR2` to `x5h-si-link.service`, and starts the launch manager. This is the booth reset sequence. Then it judges the start, and only journal lines of this boot after the restart count.

**While the launch manager restarts, the vehicle stops.** VisionPilot sends no heartbeat, so the safety island stops the vehicle. When the new VisionPilot is ready, the vehicle drives again with no operator action.

On the restart path, `activate` returns only with a final result. It can take two checks of about 120 s each, plus the restarts. The agent must wait for it, with the timeout of the agent flow above. The possible results are:

| Output | State |
|---|---|
| `X5H_OTA_PASS activate` | `ok` |
| `X5H_OTA_FAIL activate reason=verify_failed` | `rolled_back`. The check failed, the hook restored the previous image, restarted again, and the old image passed |
| `X5H_OTA_FAIL activate reason=rollback_failed` | `rollback_failed`. The old image failed too. There is no third restart |
| `X5H_OTA_REBOOT_REQUIRED`, then `X5H_OTA_FAIL activate reason=verify_failed` | `rolling_back` |

The last row happens if the launch manager is not active after the first failed check. Then the rollback takes the reboot path. The agent reboots the board, and `verify` judges the rollback at that boot.

### A failed activate

If `activate` fails before or during the change, with any reason of the table above except `verify_failed` and `rollback_failed`, the hook puts back everything it changed. It prints no `X5H_OTA_REBOOT_REQUIRED`. The staged components stay staged, and `status` shows `staged`. The agent can run `activate` again, or `rollback` to discard the stage.

If the put-back itself fails, the reason is `rollback_failed`, and the component shows `rollback_failed`.

### Rollback

`rollback` has three cases:

- Components are staged. The hook discards them and prints `X5H_OTA_PASS rollback`. The versions that run do not change, and no reboot is needed. The hook also forgets the last `activate`. So a second `rollback` fails with `nothing_to_roll_back`.
- Nothing is staged, and the last `activate` applied components. Those components get their previous versions, once. If `cr52` is among them, or the launch manager is not active, the hook prints `X5H_OTA_REBOOT_REQUIRED` and `X5H_OTA_PASS rollback`. The state is then `rolling_back`, and the agent reboots. If only `visionpilot` was applied and the launch manager is active, the hook restarts and judges as described above. The result is `X5H_OTA_PASS rollback` with `rolled_back`, or `X5H_OTA_FAIL rollback reason=rollback_failed`.
- Anything else, including a second `rollback` after a finished one, fails with `nothing_to_roll_back`. Nothing changes.

A `rollback` never goes back more than one version, and never flips to the version it replaced. It undoes only the last `activate`, because each `activate` forgets the one before it. Use one `activate` per campaign.

## Administrator setup

### Board setup

1. Write `/etc/x5h-ota/cr52-slot.conf` with these two keys, as `KEY=value` lines with decimal values:

   ```
   SLOT_SKIP=<offset of the slot in 4 KiB units>
   SLOT_SECTORS=<size of the slot extent in 4 KiB units>
   ```

   The values come from the vendor SDK. They are never in this repository. A reflash removes the file, so write it again after each reflash.

2. Run `x5h-ota init <payload-file>` once, where the file holds the payload that is in the slot now. The hook finds the UFS device whose slot holds exactly these bytes. If no device or more than one device matches, the reason is `slot_not_found` or `slot_ambiguous`. The hook also records the hash of `/lib/firmware/actuation_x5h.elf`. See [cr52-slot-update.md](cr52-slot-update.md) for how the slot is located.

The registry credentials belong to the update agent (see Credentials above).

The hook keeps two versions of each component on the disk. A CR52 payload is about 10 MiB, and its ELF is about 40 MiB. The state is in `/var/lib/x5h-ota/`. The hook reads its `.env` files with `sed` and never sources them.

### Publish an update

On the desktop, run one of these:

```
scripts/x5h-ota-publish.sh visionpilot <version> <base-image-ref>
scripts/x5h-ota-publish.sh cr52 <version> <actuation_x5h.elf>
```

The script pushes the artifact with the labels above, using the desktop's `podman login` store. It prints one line:

```
X5H_OTA_PUBLISHED component=<component> version=<version> ref=ghcr.io/youtalk/<package>@sha256:<digest>
```

Give the `ref` value to the update agent as the `<source>`. If the environment variable `X5H_OTA_ARCHIVE` names a file, the script writes an OCI archive there and pushes nothing. After the first push of each package, make sure in the GitHub package settings that the package is private. Grant the agent's GitHub user read access only.

## At `rollback_failed`

A person takes over. The hook has removed `pending`, so the next boot runs no check. It has also forgotten the last `activate`, so `rollback` fails with `nothing_to_roll_back`. The agent must stop and report. It must not run `activate` again.

- For `cr52`, write the slot with the vendor flash tool or with [cr52-slot-update.md](cr52-slot-update.md). Then run `x5h-ota init <payload-file>` again with the payload that is in the slot.
- For `visionpilot`, run `podman tag <image-id> localhost/x5h-visionpilot:latest` with the image that works. The state stays `rollback_failed` until the next successful `activate`. After a failed campaign, the replaced image has no name. `podman image prune` removes it.

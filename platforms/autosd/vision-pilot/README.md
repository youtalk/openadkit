# AutoSD + VisionPilot

Run [VisionPilot](https://github.com/autowarefoundation/autoware_vision_pilot)
(standalone, video input, ONNX Runtime CPU EP) as a Podman Quadlet service on an
AutoSD 10 aarch64 image, validated in QEMU before any R-Car Gen 5 board work.

## Folder Structure

- `aib/`: automotive-image-builder manifest for the AutoSD 10 image (target `qemu`)
- `components/`: Quadlet files run by podman + systemd inside the image
- `smoke/`: deterministic inference smoke test (pinned test data, log assertions)
- `scripts/`: QEMU launcher and CI serial-console harness

## Host Prerequisites (Ubuntu 24.04)

See "Host setup" below. aarch64 image builds happen in CI on native arm64
runners — automotive-image-builder only builds on the native architecture.

## Host setup

Install the emulation, container, and test tooling (Ubuntu 24.04):

```bash
sudo apt-get update && sudo apt-get install -y \
  qemu-system-arm qemu-efi-aarch64 qemu-utils podman qemu-user-static ffmpeg expect
```

Register the arm64 binfmt handler for `docker buildx` (cross-arch container builds):

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Verify (all five must succeed — S0 pass criteria):

```bash
qemu-system-aarch64 --version | head -1           # QEMU emulator version 8.2.2
podman --version                                  # podman version 4.9.3
ls /usr/share/AAVMF/AAVMF_CODE.fd                 # aarch64 UEFI firmware present
docker buildx ls | head -3                        # default builder lists linux/arm64
cat /proc/sys/fs/binfmt_misc/qemu-aarch64         # enabled
```

Verified versions on the reference host: QEMU 8.2.2, podman 4.9.3, expect 5.45.4,
docker buildx 0.31.2. `qemu-efi-aarch64` provides `/usr/share/AAVMF/`; the apt
`qemu-user-static` package and the `tonistiigi/binfmt` step both register the
aarch64 binfmt interpreter (`/usr/libexec/qemu-binfmt/aarch64-binfmt-P`).

## Running

(filled in by the QEMU tasks)

## Troubleshooting

(SELinux / Quadlet / QEMU findings are recorded here as they are discovered)

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

(filled in by the host-setup task)

## Running

(filled in by the QEMU tasks)

## Troubleshooting

(SELinux / Quadlet / QEMU findings are recorded here as they are discovered)

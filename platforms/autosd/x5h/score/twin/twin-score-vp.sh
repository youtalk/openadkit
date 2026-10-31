#!/bin/sh
# Started by the S-CORE launch manager as component "visionpilot" of the twin
# configuration (score/config/twin): the CES 2027 digital twin on a Corellium
# arm64 VM. It is scripts/x5h-score-vp.sh without the NPU: no devices, no
# NPU mounts, no x5h-work mount. VisionPilot runs the fp32 model on the
# CPU from /var/lib/twin/model, with the twin vision_pilot.conf from
# /etc/twin. Read x5h-score-vp.sh for the notes on the exec chain, the ready
# file, --pid=host and LD_LIBRARY_PATH: they apply here unchanged.
#
# /etc/twin/twin-vm.env names the VM interface for domain 1
# (X5H_D1_INTERFACE). cyclonedds-x5h-demo.xml reads it.
set -a
. /etc/twin/twin-vm.env
set +a
rm -f "$SCORE_VP_READY_FILE"
mkdir -p /run/score
exec /usr/bin/systemd-cat -t twin-vp /usr/bin/podman run --rm --replace --name twin-vp \
    --network=host --ipc=host --pid=host --cgroups=split --log-driver=passthrough --pull=never --privileged \
    -v /tmp:/tmp -v /run/score:/run/score \
    -e IDENTIFIER -e LCM_ALIVE_INTERFACE_PATH -e SCORE_VP_FRAME_MAX_MS -e SCORE_VP_READY_FILE \
    -e SCORE_VP_LIB=/opt/score/lib/libscore_vp.so \
    -e MW_LOG_CONFIG_FILE=/etc/score/vp-logging.json \
    -v /usr/local/score/lib/libscore_vp.so:/opt/score/lib/libscore_vp.so:ro \
    -v /etc/score/vp-logging.json:/etc/score/vp-logging.json:ro \
    -v /var/lib/twin/model:/model:ro \
    -v /etc/twin/vision_pilot.conf:/usr/share/visionpilot/config/vision_pilot.conf:ro,z \
    -v /etc/containers/systemd/vision_pilot_ros2.conf:/usr/share/visionpilot/config/vision_pilot_ros2.conf:ro,z \
    -v /etc/containers/systemd/cyclonedds-x5h-demo.xml:/etc/x5h/cyclonedds.xml:ro,z \
    -e ROS_DOMAIN_ID=1 -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp -e X5H_D1_INTERFACE \
    -e CYCLONEDDS_URI=file:///etc/x5h/cyclonedds.xml -e QT_QPA_PLATFORM=offscreen \
    -e LD_LIBRARY_PATH=/opt/ros/jazzy/lib/aarch64-linux-gnu:/opt/ros/jazzy/lib:/usr/share/visionpilot/onnxruntime/lib \
    localhost/x5h-visionpilot:latest --no-window

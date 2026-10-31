#!/bin/sh
# Started by the S-CORE launch manager as component "camera" of the twin
# configuration (score/config/twin). It is scripts/x5h-score-camera.sh with
# the VM interface for domain 1 (X5H_D1_INTERFACE from /etc/twin/twin-vm.env).
# Read x5h-score-camera.sh for the notes on the output topic name and the
# republish parameters: they apply here unchanged.
set -a
. /etc/twin/twin-vm.env
set +a
exec /usr/bin/systemd-cat -t twin-camera /usr/bin/podman run --rm --replace --name twin-image-republish \
    --network=host --cgroups=split --log-driver=passthrough --pull=never \
    -v /etc/containers/systemd/cyclonedds-x5h-demo.xml:/etc/x5h/cyclonedds.xml:ro,z \
    -e ROS_DOMAIN_ID=1 -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp -e X5H_D1_INTERFACE \
    -e CYCLONEDDS_URI=file:///etc/x5h/cyclonedds.xml \
    --entrypoint /bin/bash localhost/x5h-image-republish:latest \
    -c 'source /opt/ros/jazzy/setup.bash && exec /opt/ros/jazzy/lib/image_transport/republish --ros-args -p in_transport:=compressed -p out_transport:=raw -r in/compressed:=/carla/hero/main_cam/image/compressed -r out:=/x5h/main_cam/image'

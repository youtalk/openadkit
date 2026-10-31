#!/bin/sh
# Started by the S-CORE launch manager as component "si_fault" of the twin
# configuration, in the fallback run target. The twin has no CR52 link to
# signal (the board sends SIGUSR1 to the link service). The
# fallback stops VisionPilot, so its heartbeat goes stale and the Safety
# Island stops the car. This only marks the time of the switch in the
# journal (journalctl -t twin-si-fault).
echo "TWIN_SI_FAULT at=$(date +%s.%3N)" | /usr/bin/systemd-cat -t twin-si-fault
exit 0

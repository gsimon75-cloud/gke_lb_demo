#!/usr/bin/env bash
# Run a playbook and record its output to a log file as well

LOGFILE="playbook.log"

stdbuf -oL ansible-playbook -i inventory.gcp_compute.yaml "$@" 2>&1 | awk '{print strftime("%H:%M:%S ") $0; fflush();}' | stdbuf -oL tee "$LOGFILE"

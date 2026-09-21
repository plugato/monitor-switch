#!/usr/bin/env bash
# Atalho de um clique: monitor -> HDMI. Equivalente de to-hdmi.cmd.
exec "$(dirname "$(readlink -f "$0")")/set-monitor-input.sh" --notify HDMI

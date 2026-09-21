#!/usr/bin/env bash
# Atalho de um clique: monitor -> DisplayPort. Equivalente de to-dp.cmd.
exec "$(dirname "$(readlink -f "$0")")/set-monitor-input.sh" --notify DP

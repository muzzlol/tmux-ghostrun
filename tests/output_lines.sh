#!/usr/bin/env bash
# Outputs a large number of lines to stdout

LINES=${1:-500}

for i in $(seq 1 "$LINES"); do
  echo "Line $i: $(date +%T) - $(head -c 32 /dev/urandom | base64 | tr -d '\n')"
done

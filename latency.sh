#!/bin/bash
# Sends N sequential requests and prints latency statistics.
#
# usage: ./latency.sh <path> [N]
#   path : ""  -> InferencePool route
#          /rr -> plain Kubernetes Service route

if [ -z "$NGF_IP" ] || [ -z "$HTTP_PORT" ]; then
  echo "NGF_IP and HTTP_PORT must be exported first (see README)" >&2
  exit 1
fi

PFX=$1
N=${2:-16}

for i in $(seq 1 "$N"); do
  curl -s -m 20 -o /dev/null -w "%{time_total}\n" "http://$NGF_IP:$HTTP_PORT$PFX/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"food-review-1\",\"prompt\":\"latency test $RANDOM $i\",\"max_tokens\":10}"
done | sort -n | awk '{a[NR]=$1; s+=$1} END {printf "requests=%d  avg=%.3fs  p50=%.3fs  max=%.3fs\n", NR, s/NR, a[int((NR+1)/2)], a[NR]}'

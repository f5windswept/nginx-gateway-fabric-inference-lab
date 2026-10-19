#!/bin/bash
# Sends N completion requests through the gateway and counts which model server pod served each one.
#
# usage: ./tally.sh <path> <mode> [N] [parallel]
#   path     : ""   -> InferencePool route (Endpoint Picker decides)
#              /rr  -> plain Kubernetes Service route (NGINX load balancing, no Endpoint Picker)
#   mode     : shared   -> every prompt starts with the same long "system prompt" (prefix cache candidate)
#              distinct -> every prompt is random (no shared prefix)
#   N        : number of requests (default 12)
#   parallel : number of concurrent requests (default 1)
#
# The gateway address is taken from $NGF_IP and $HTTP_PORT (see README step 1.6)

if [ -z "$NGF_IP" ] || [ -z "$HTTP_PORT" ]; then
  echo "NGF_IP and HTTP_PORT must be exported first (see README)" >&2
  exit 1
fi

export GW="$NGF_IP:$HTTP_PORT" PFX="$1" MODE="$2"
N=${3:-12}
P=${4:-1}

export SYS="You are a senior SRE assistant with deep Kubernetes and NGINX knowledge. Always follow the incident runbook precisely: first identify the failing component, then check readiness and liveness probes, then inspect recent rollouts and events, then review Gateway and HTTPRoute status conditions, and finally summarise the root cause in three bullet points for the on-call engineer."

req() {
  if [ "$MODE" = "shared" ]; then
    PROMPT="$SYS Question $1: why is my pod restarting?"
  else
    PROMPT="Request $RANDOM-$1: $(head -c 300 /dev/urandom | base64 | tr -d '\n/+=' | head -c 300)"
  fi
  curl -s -m 20 -D - -o /dev/null "http://$GW$PFX/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"food-review-1\",\"prompt\":\"$PROMPT\",\"max_tokens\":20}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-inference-pod"{print $2} /^HTTP\/1.1 [^2]/{print "HTTP error: " $0}'
}
export -f req

seq 1 "$N" | xargs -P "$P" -I{} bash -c 'req {}' | sort | uniq -c

#!/bin/bash

set -x

bail() {
  printf 'Error executing command, exiting'
  exit 1
}

exec_cmd_nobail() {
  printf '\n%s$ %s\n\n' "$(pwd)" "$1"
  bash -c "$1"
}

exec_cmd() {
  exec_cmd_nobail "$1" || bail
}

if [[ -n "${PROXY_SOCKS_HOST}" && -n "${PROXY_SOCKS_PORT}" ]]; then
  jq \
    --arg proxy_host "$PROXY_SOCKS_HOST" \
    --arg proxy_port "$PROXY_SOCKS_PORT" \
    --arg proxy_user "$PROXY_SOCKS_USER" \
    --arg proxy_pass "$PROXY_SOCKS_PASS" \
    '.outbounds[0] += {server: $proxy_host, server_port: ($proxy_port | tonumber), username: $proxy_user, password: $proxy_pass}' \
    /root/sing-box/config.template.json > /root/sing-box/config.json
  EOB
  exec_cmd '/root/sing-box/sing-box run -c /root/sing-box/config.json' &
  singbox_pid=$!
  sleep 2
  exec_cmd '/root/sing-box/iptables-set.sh'
  trap 'kill -SIGINT $singbox_pid; wait -fn $singbox_pid' EXIT ERR HUP INT QUIT TERM ABRT
fi

REG_TOKEN=$(curl -sLX POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${REPO}/actions/runners/registration-token" | jq .token --raw-output)

cleanup() {
  echo 'Removing runner...'
  ./config.sh remove --token "${REG_TOKEN}"
}

exec_cmd "./config.sh --unattended --url https://github.com/${REPO} --token ${REG_TOKEN} --ephemeral --labels self-hosted --replace --name $(hostname)"

trap cleanup EXIT ERR HUP INT QUIT TERM ABRT

(
  max_retries=10
  attempt=1
  while (( attempt <= max_retries )); do
    if ! dockerd-entrypoint.sh; then
      echo 'Failed to start Docker Daemon. Retrying in 2 seconds...'
      sleep 2
      attempt=$(( attempt + 1 ))
    fi
    echo "Failed to start Docker Daemon after $attempt attempts."
    exit 1
  done
) &
dockerd_entrypoint_pid=$!

trap '[[ -f /var/run/docker.pid ]] && kill -INT "$(cat /var/run/docker.pid); wait -fn $dockerd_entrypoint_pid"' EXIT ERR HUP INT QUIT TERM ABRT

(
  command='docker info >/dev/null 2>&1'
  max_retries=10
  attempt=1
  while (( attempt <= max_retries )); do
    if eval "$command"; then
      sleep 1
      attempt=$(( attempt + 1 ))
    fi
    echo "Failed to wait for Docker Daemon to become ready after $attempt attempts."
    exit 1
  done
)

exec_cmd_nobail './run.sh' || cleanup

kill -INT "$(cat /var/run/docker.pid)"; wait -fn $dockerd_entrypoint_pid

kill -SIGINT "$singbox_pid"; wait -fn "$singbox_pid"

sleep 1

#!/usr/bin/env bash
# Launch the TwinCAT runtime (XAR) in a detached container so a TwinCAT XAE
# can connect over ADS. Run from anywhere:
#   ./docker/scripts/run-xar.sh [--replace] [--down]
#
# What it does:
#   - starts TcSysConf followed by TcSystemServiceUm as the container's
#     foreground process (the image has no systemd; the unit files are inert)
#   - publishes ADS (48898/tcp), Secure ADS (8016/tcp) and discovery
#     (48899/udp), and persists /etc/TwinCAT in a named volume so the
#     AmsNetId and routes survive restarts
#   - creates a Linux user inside the container; TwinCAT validates XAE
#     route-add credentials against Linux system users (via tcauth)
#   - after start, PROBES whether the runtime actually registered an ADS
#     server (adstool 127.0.0.1 state). Container transport coming up does not
#     mean the runtime did. On success it reports the address to route XAE to;
#     on failure it prints a diagnosis and exits non-zero (container left up).
#
# Hardware reality check: the runtime binds to hardware it recognizes:
#   - amd64: real Intel/AMD silicon. Under emulation (Apple Silicon
#     Rosetta/QEMU, or any x86-on-ARM layer) the ADS router never starts;
#     Beckhoff confirms ARM cannot emulate the x86 memory model it needs.
#   - arm64: Beckhoff CX8290/CX9240 only. The binaries match the device-tree
#     compatible strings cx8200/cx9240; generic ARM boards will not work.
#   On unsupported hosts the container still runs and answers UDP discovery,
#   but the system service replies ADS error 6 and XAE cannot attach.
#
# Remote engine: every docker call here honours the active context, so on an
# Apple Silicon Mac you point at a real x86_64 engine and run this unchanged:
#   docker context create x86 --docker host=ssh://user@x86-host
#   docker context use x86 && ./docker/scripts/run-xar.sh
# See README "Running from a Mac (Apple Silicon)".
set -euo pipefail

IMAGE="${BHF_IMAGE:-beckhoff-rt-linux:latest}"
CONTAINER="${BHF_CONTAINER:-beckhoff-xar}"
VOLUME="${BHF_VOLUME:-beckhoff-xar-data}"
# Without -i the service derives 0.0.0.0.1.1 off Beckhoff hardware, which no
# XAE can route to. Any unique NetId works; convention is <ip>.1.1.
NETID="${BHF_NETID:-192.168.77.10.1.1}"
ADS_USER="${BHF_ADS_USER:-Administrator}"
ADS_PASSWORD="${BHF_ADS_PASSWORD:-1}"

# Host XAE routes to. Auto-derived from the active Docker context / DOCKER_HOST
# below; override when the routable address differs (tunnels, NAT, Tailscale).
ENGINE_HOST_OVERRIDE="${BHF_ENGINE_HOST:-}"

REPLACE=0
DOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --replace) REPLACE=1; shift ;;
    --down)    DOWN=1;    shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$DOWN" = "1" ]; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "run-xar: removed container '${CONTAINER}'."
  echo "run-xar: volume '${VOLUME}' kept (routes, NetId). Remove with: docker volume rm ${VOLUME}"
  exit 0
fi

# Address XAE should route to: the Docker ENGINE host, not necessarily this
# machine. Local socket -> localhost; ssh://user@host or tcp://host:port -> host.
engine_host() {
  if [ -n "$ENGINE_HOST_OVERRIDE" ]; then
    printf '%s' "$ENGINE_HOST_OVERRIDE"
    return
  fi
  local ep="${DOCKER_HOST:-}"
  if [ -z "$ep" ]; then
    ep="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  fi
  case "$ep" in
    ""|unix://*|npipe://*) printf 'localhost' ;;
    ssh://*) ep="${ep#ssh://}"; ep="${ep##*@}"; printf '%s' "${ep%%:*}" ;;
    tcp://*) ep="${ep#tcp://}"; printf '%s' "${ep%%:*}" ;;
    *)       printf '%s' "$ep" ;;
  esac
}

ENGINE_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo unknown)"

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if [ "$REPLACE" = "1" ]; then
    docker rm -f "$CONTAINER" >/dev/null
  else
    echo "run-xar: container '${CONTAINER}' already exists; rerun with --replace" >&2
    exit 1
  fi
fi

# CAP_SYS_NICE + unlimited memlock cover RT scheduling; BHF_PRIVILEGED=1
# switches to --privileged for experiments that poke /sys or devices.
PRIV_ARGS=(--cap-add SYS_NICE --ulimit memlock=-1:-1)
if [ "${BHF_PRIVILEGED:-0}" = "1" ]; then
  PRIV_ARGS=(--privileged)
fi

docker volume create "$VOLUME" >/dev/null
docker run -d --name "$CONTAINER" --restart unless-stopped \
  "${PRIV_ARGS[@]}" \
  -e BHF_QUIET="${BHF_QUIET:-0}" \
  -v "${VOLUME}:/etc/TwinCAT" \
  -p 48898:48898 -p 8016:8016 -p 48899:48899/udp \
  "$IMAGE" \
  bash -c "/usr/bin/TcSysConf || true; exec /usr/bin/TcSystemServiceUm -f 0x5 -i ${NETID} -p /var/run/TcSystemServiceUm.pid" \
  >/dev/null

# Route-add credentials: XAE's Add Route dialog authenticates against Linux
# users inside the container. chpasswd reads user:password from stdin.
docker exec "$CONTAINER" bash -c \
  "useradd -m '${ADS_USER}' 2>/dev/null || true; chpasswd <<< '${ADS_USER}:${ADS_PASSWORD}'"

sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
  echo "run-xar: container exited; logs:" >&2
  docker logs "$CONTAINER" >&2 || true
  exit 1
fi

# The container transport coming up does not mean the runtime registered an ADS
# server. Probe the local system service (ADS port 10000): a healthy runtime
# returns its ADS state; an unsupported/emulated host replies ADS error 6.
REGISTERED=0
STATE=""
tries=0
while [ "$tries" -lt 20 ]; do
  if STATE=$(docker exec "$CONTAINER" adstool 127.0.0.1 state 2>/dev/null); then
    REGISTERED=1
    break
  fi
  tries=$((tries + 1))
  sleep 1
done

GOT_NETID=$(docker exec "$CONTAINER" adstool 127.0.0.1 netid 2>/dev/null || echo "unavailable")
HOST=$(engine_host)

echo "run-xar: container '${CONTAINER}' is up (image ${IMAGE}, engine arch ${ENGINE_ARCH})."
echo "run-xar: AmsNetId ${GOT_NETID}; ADS 48898/tcp, Secure ADS 8016/tcp, discovery 48899/udp."

if [ "$REGISTERED" = "1" ]; then
  echo "run-xar: ADS server registered (system-service state ${STATE}) : runtime is usable."
  echo "run-xar: XAE route: Add Route -> ${HOST}, Secure ADS, user '${ADS_USER}'."
  exit 0
fi

echo "run-xar: ERROR: the runtime did not register an ADS server." >&2
echo "run-xar:   'adstool 127.0.0.1 state' failed (ADS error 6): discovery answers, XAE cannot attach." >&2
echo "run-xar:   Common reasons:" >&2
echo "run-xar:     - unsupported host: XAR needs real x86_64 (Intel/AMD) or Beckhoff CX arm64;" >&2
echo "run-xar:       engine arch here is '${ENGINE_ARCH}'." >&2
echo "run-xar:     - Apple Silicon: x86 cannot be emulated faithfully (Docker/Rosetta, QEMU," >&2
echo "run-xar:       Windows-on-ARM), so the ADS router never starts. Run the container on an" >&2
echo "run-xar:       x86_64 engine instead; see README 'Running from a Mac (Apple Silicon)'." >&2
echo "run-xar: container left running for inspection (docker logs ${CONTAINER})." >&2
exit 1

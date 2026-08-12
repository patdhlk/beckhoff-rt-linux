#!/usr/bin/env bash
# Orchestrator: preflight → render credentials → buildx → optional smoke + push.
# Run from anywhere: ./docker/scripts/build.sh [--smoke] [--push]
#
# Platforms come from BHF_PLATFORMS (default: linux/amd64,linux/arm64).
#
# Local builds go one platform at a time with --load, because this host uses
# the classic overlay2 image store, whose exporter cannot load a manifest list.
# The multi-arch manifest is only assembled on --push, which needs a
# docker-container builder — the default docker driver cannot build one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=docker/scripts/env-lib.sh
. docker/scripts/env-lib.sh

PLATFORMS="${BHF_PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="${BHF_BUILDER:-bhf-builder}"
TAG_BASE="beckhoff-rt-linux"

SMOKE=0
PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --push)  PUSH=1;  shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# 1. Preflight.
bash docker/scripts/preflight.sh

# 2. Render credentials to a temp BuildKit secret. Trap removes it on any exit.
SECRET=$(mktemp)
trap 'rm -f "$SECRET"' EXIT INT TERM
BECKHOFF_EMAIL="$(env_file_get BECKHOFF_EMAIL ./.env)" \
BECKHOFF_PASSWORD="$(env_file_get BECKHOFF_PASSWORD ./.env)" \
  bash docker/scripts/render-bhf-conf.sh --out "$SECRET"

# 3. Tagging.
VCS_REF=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_VERSION="${VCS_REF}"

export DOCKER_BUILDKIT=1

# 4. Build each platform separately and load it under a per-arch tag.
IFS=',' read -r -a PLATFORM_LIST <<< "$PLATFORMS"
for platform in "${PLATFORM_LIST[@]}"; do
  arch="${platform#linux/}"
  echo "build: ${platform} -> ${TAG_BASE}:${IMAGE_VERSION}-${arch}"
  docker buildx build \
    --platform "$platform" \
    --secret "id=apt,src=${SECRET}" \
    --build-arg VCS_REF="${VCS_REF}" \
    --build-arg IMAGE_VERSION="${IMAGE_VERSION}" \
    --tag "${TAG_BASE}:${IMAGE_VERSION}-${arch}" \
    --load \
    docker
done

# 5. Point the unsuffixed tags at this host's native arch, so a bare
#    `docker run beckhoff-rt-linux:latest` does not silently emulate.
HOST_ARCH=$(docker version --format '{{.Server.Arch}}')
if printf '%s\n' "${PLATFORM_LIST[@]}" | grep -qx "linux/${HOST_ARCH}"; then
  docker tag "${TAG_BASE}:${IMAGE_VERSION}-${HOST_ARCH}" "${TAG_BASE}:${IMAGE_VERSION}"
  docker tag "${TAG_BASE}:${IMAGE_VERSION}-${HOST_ARCH}" "${TAG_BASE}:latest"
else
  echo "build: note — host arch ${HOST_ARCH} was not built, leaving :latest alone" >&2
fi

# 6. Optional smoke, per built platform.
if [ "$SMOKE" = "1" ]; then
  for platform in "${PLATFORM_LIST[@]}"; do
    arch="${platform#linux/}"
    bash docker/scripts/smoke-test.sh "${TAG_BASE}:${IMAGE_VERSION}-${arch}" "$arch"
  done
fi

# 7. Optional push as a single multi-arch manifest.
if [ "$PUSH" = "1" ]; then
  : "${BHF_PUSH_REGISTRY:?Set BHF_PUSH_REGISTRY (e.g., ghcr.io/yourname) to push}"
  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "build: creating docker-container builder '${BUILDER_NAME}' (manifest lists need it)"
    docker buildx create --name "$BUILDER_NAME" --driver docker-container >/dev/null
  fi
  docker buildx build \
    --builder "$BUILDER_NAME" \
    --platform "$PLATFORMS" \
    --secret "id=apt,src=${SECRET}" \
    --build-arg VCS_REF="${VCS_REF}" \
    --build-arg IMAGE_VERSION="${IMAGE_VERSION}" \
    --tag "${BHF_PUSH_REGISTRY}/${TAG_BASE}:${IMAGE_VERSION}" \
    --tag "${BHF_PUSH_REGISTRY}/${TAG_BASE}:latest" \
    --push \
    docker
fi

echo
echo "build: done. Local tags: ${TAG_BASE}:${IMAGE_VERSION}-<arch>"
echo "Reminder: distribution of Beckhoff packages is restricted. See README §Licensing."

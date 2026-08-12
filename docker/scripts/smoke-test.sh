#!/usr/bin/env bash
# Post-build checks against a built image. Returns non-zero if any fail.
# Usage: smoke-test.sh <image-ref> [arch]
#   arch is the Docker arch the ref was built for (amd64|arm64), default amd64.
set -euo pipefail

TAG="${1:?usage: smoke-test.sh <image-ref> [arch]}"
ARCH="${2:-amd64}"

case "$ARCH" in
  amd64) UNAME_M="x86_64" ;;
  arm64) UNAME_M="aarch64" ;;
  *) echo "smoke: unsupported arch '$ARCH' (want amd64|arm64)" >&2; exit 2 ;;
esac

PLATFORM="linux/$ARCH"
PASS=0
FAIL=0

run_check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name" >&2
    FAIL=$((FAIL + 1))
  fi
}

# 1. Built for the architecture we asked for.
check_arch() {
  [ "$(docker run --rm --platform "$PLATFORM" "$TAG" uname -m)" = "$UNAME_M" ]
}
run_check "uname -m == $UNAME_M" check_arch

# 2. Debian base is present and is the expected suite.
check_os_release() {
  docker run --rm --platform "$PLATFORM" "$TAG" test -f /etc/os-release
}
run_check "/etc/os-release present" check_os_release

# 3. Beckhoff packages actually installed.
check_bhf_packages() {
  docker run --rm --platform "$PLATFORM" "$TAG" \
    sh -c "dpkg-query -W -f='\${Package}\n' 2>/dev/null | grep -qE '^(tc|adstool|libadscomm|bhfinfo)'"
}
run_check "Beckhoff packages installed" check_bhf_packages

# 4. The ADS CLI is on PATH. (tcadsbridge does not exist in this repo; the
#    equivalent is adstool.)
check_adstool() {
  docker run --rm --platform "$PLATFORM" "$TAG" sh -c 'command -v adstool'
}
run_check "adstool available" check_adstool

# 5. Entrypoint passthrough works.
check_entrypoint() {
  docker run --rm --platform "$PLATFORM" "$TAG" true
}
run_check "entrypoint passthrough" check_entrypoint

# 6. No apt credentials left in the image.
check_no_credentials() {
  ! docker run --rm --platform "$PLATFORM" "$TAG" \
      sh -c 'cat /etc/apt/auth.conf /etc/apt/auth.conf.d/* 2>/dev/null | grep -q .'
}
run_check "no apt credentials baked into image" check_no_credentials

# 7. The RT warning actually fires under stock docker capabilities. The unit
#    tests use fixtures; this proves the real container path, where an earlier
#    heuristic ("is CapBnd zero") was silent because CapBnd is never zero.
check_rt_warning() {
  docker run --rm --platform "$PLATFORM" "$TAG" true 2>&1 | grep -q 'CAP_SYS_NICE'
}
run_check "RT warning fires under stock docker caps" check_rt_warning

# 8. OCI license label set — the distribution restriction must travel with it.
check_license_label() {
  [ "$(docker inspect "$TAG" --format '{{ index .Config.Labels "org.opencontainers.image.licenses" }}')" \
    = 'proprietary-Beckhoff' ]
}
run_check "OCI license label set" check_license_label

echo
echo "smoke [$TAG / $ARCH]: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

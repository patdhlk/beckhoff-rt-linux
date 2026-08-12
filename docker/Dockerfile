# syntax=docker/dockerfile:1.7

ARG BHF_CODENAME=trixie
FROM debian:${BHF_CODENAME}-slim AS base

# Repeated after FROM: ARGs declared before it leave scope at the FROM line.
ARG BHF_CODENAME
# The apt suite is NOT the Debian codename. Beckhoff publishes trixie-stable,
# trixie-testing, trixie-unstable and bookworm-unstable — there is no
# bookworm-stable.
ARG BHF_SUITE=trixie-stable
ARG VCS_REF=unknown
ARG IMAGE_VERSION=unknown

ENV DEBIAN_FRONTEND=noninteractive

# Prereqs for adding the Beckhoff apt source and verifying its key.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# Fingerprint-pinned import of the Beckhoff archive key.
#
# deb.beckhoff.com puts the key itself behind HTTP auth, so this needs the
# credential secret as well — it is not a public keyring URL. The apt-auth
# format is also valid netrc, which is why curl can consume the same file.
# The key is ASCII-armored, hence the dearmor.
COPY apt-config/bhf-fingerprint.txt /tmp/bhf-fingerprint.txt
RUN --mount=type=secret,id=apt,target=/etc/apt/auth.conf.d/bhf.conf,mode=0600 \
    set -eu; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL --netrc-file /etc/apt/auth.conf.d/bhf.conf \
      -o /tmp/repo.pub https://deb.beckhoff.com/repo.pub; \
    gpg --dearmor < /tmp/repo.pub > /etc/apt/keyrings/beckhoff.gpg; \
    rm -f /tmp/repo.pub; \
    gpg --show-keys --with-fingerprint --with-colons /etc/apt/keyrings/beckhoff.gpg \
      > /tmp/keyinfo.txt; \
    FP_GOT=$(awk -F: '$1=="fpr"{print $10; exit}' /tmp/keyinfo.txt); \
    rm -f /tmp/keyinfo.txt; \
    FP_WANT=$(tr -d ' :\r\n' < /tmp/bhf-fingerprint.txt); \
    if [ "$FP_GOT" != "$FP_WANT" ]; then \
      echo "GPG fingerprint mismatch: got=$FP_GOT want=$FP_WANT" >&2; \
      exit 1; \
    fi; \
    rm -f /tmp/bhf-fingerprint.txt

# Render the apt source list from the template.
COPY apt-config/bhf.list.template /tmp/bhf.list.template
RUN sed "s|\${BHF_SUITE}|${BHF_SUITE}|g" /tmp/bhf.list.template \
      > /etc/apt/sources.list.d/bhf.list \
 && rm /tmp/bhf.list.template \
 && grep -q "${BHF_SUITE}" /etc/apt/sources.list.d/bhf.list

# Install Beckhoff packages with credentials mounted as a BuildKit secret.
# The secret is never written to a layer.
COPY apt-config/packages.txt /tmp/packages.txt
# hadolint ignore=DL3008
RUN --mount=type=secret,id=apt,target=/etc/apt/auth.conf.d/bhf.conf,mode=0600 \
    apt-get update \
 && xargs -a /tmp/packages.txt apt-get install -y --no-install-recommends \
      -o Dpkg::Options::=--force-confnew \
      -o Dpkg::Options::=--force-confdef \
 && rm /tmp/packages.txt \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/*

# Belt + suspenders: ensure no persistent apt auth was written into the image.
RUN rm -f /etc/apt/auth.conf.d/bhf.conf /etc/apt/auth.conf

# Overlay: entrypoint and OCI labels.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work

LABEL org.opencontainers.image.title="beckhoff-rt-linux" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="proprietary-Beckhoff" \
      org.opencontainers.image.description="Dev/CI image of Beckhoff RT Linux. NOT real-time. Distribution restricted — see README."

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

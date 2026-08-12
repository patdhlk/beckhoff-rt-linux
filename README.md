# beckhoff-rt-linux Docker image

A Debian-based Docker image built from Beckhoff's official APT repository at
`deb.beckhoff.com`. Suitable for dev and CI use of the TwinCAT/XAR userspace,
cross-compiling against the Beckhoff libraries, and running Beckhoff CLI tools.

**Not real-time.** Containers share the host kernel, so real-time scheduling
needs two things the default `docker run` does not give you:

- `CAP_SYS_NICE` — Docker's default capability set omits it. Add
  `--cap-add SYS_NICE` (or `--privileged`).
- a `PREEMPT_RT` host kernel — nothing inside the container substitutes for it.

The entrypoint checks both on startup and names whichever is missing. Silence
it with `BHF_QUIET=1`.

## Licensing

The Beckhoff RT Linux installer Readme states:

> "This software without a separate commercial license is for testing only.
> For a commercial usage of the product a separate license as well as a license batch is necessary.
> The distribution of the product installed on a CPU without a license batch is prohibited."

### What this repo contains, and what it doesn't

**This repository ships build scripts only.** No Beckhoff software is included
or redistributed here. The packages are pulled at build time from
`deb.beckhoff.com` using *your* customer-account credentials, and they land
only in the image on your machine.

That distinction matters for what you may do with each half:

| Artifact | Terms |
|----------|-------|
| Scripts, Dockerfile, workflows in this repo | MIT |
| The image you build from them | Contains proprietary Beckhoff software — the notice above governs it |

### Recommended posture

This is operational guidance, not legal advice. If in doubt, ask Beckhoff.

1. **Keep built images private.** Never push to a public registry. If you use
   the `push_to_ghcr` workflow input, confirm the resulting GHCR package is
   marked **private** — a public one distributes Beckhoff software to anyone.
2. **Let each user build their own image** rather than sharing yours. The
   build is reproducible and takes minutes; every colleague already needs a
   Beckhoff account to be entitled to the software anyway.
3. **Treat it as testing-only** unless you hold a commercial license and
   license batch. That is Beckhoff's wording, and it covers CI and development
   use of an unlicensed runtime.
4. **Do not bake credentials into the image.** The build already prevents this
   — credentials are mounted as BuildKit secrets and never written to a layer,
   and smoke check 6 fails the build if any apt auth survives. Keep it that way
   if you modify the Dockerfile: a leaked image would expose your Beckhoff
   account, not just the software.
5. **Redistribution to third parties needs explicit Beckhoff permission.**
   That decision is **yours as the builder**, not this repo's.

## Prerequisites

- Docker with BuildKit (`docker buildx version` should succeed)
- A Beckhoff customer account with access to `deb.beckhoff.com`
- Linux x86_64 host, or Apple Silicon (both `linux/amd64` and `linux/arm64` are
  buildable — see [Architectures](#architectures))

## Quick start

```bash
cp .env.example .env
$EDITOR .env                          # fill in BECKHOFF_EMAIL and BECKHOFF_PASSWORD

./docker/scripts/build.sh --smoke     # builds every platform and smoke-tests each
docker run --rm -it beckhoff-rt-linux:latest    # shell into /work
```

If your password contains shell metacharacters — `(`, `)`, `$`, backticks —
that is fine. Nothing sources `.env`; it is parsed (see
`docker/scripts/env-lib.sh`). Quoting the value is optional.

## What's in the image

Pinned in `docker/apt-config/packages.txt`:

| Package | Purpose |
|---------|---------|
| `tc31-xar-um` | TwinCAT 3 base runtime |
| `tcsysconf` | Real-time Ethernet and system configuration tools |
| `adstool` | CLI to access TwinCAT systems over ADS |
| `libadscomm`, `libadscomm-dev` | TF6000 ADS communication library + headers |
| `bhfinfo` | System information collector |
| `tc31-orderno` | Maps TwinCAT order numbers to Debian packages |

The repository carries 68 packages in total, including TF-series function
packages (OPC UA, Modbus TCP, BACnet, HMI server) and the Beckhoff
`PREEMPT_RT` kernel images. The kernel packages are deliberately excluded: a
container uses the host kernel, so they would add hundreds of MB for nothing.
To add packages, edit `packages.txt` and rebuild.

## Repository facts

Established by the discovery pass; useful if you are debugging apt problems:

- The whole host is behind HTTP auth, including the signing key. There is no
  anonymous URL for anything.
- The signing key is at `https://deb.beckhoff.com/repo.pub`, ASCII-armored.
  The build pins it by fingerprint (`docker/apt-config/bhf-fingerprint.txt`)
  and fails closed on mismatch.
- Suites are `trixie-stable`, `trixie-testing`, `trixie-unstable` and
  `bookworm-unstable`. **There is no `bookworm-stable`.** This image pins
  `trixie-stable` on a `debian:trixie-slim` base.
- Published architectures: `amd64`, `arm64`, `armhf`.

## Use cases

```bash
# Cross-compile with your tree mounted
docker run --rm -v "$PWD:/work" beckhoff-rt-linux:latest make

# Talk to a TwinCAT system over ADS
docker run --rm beckhoff-rt-linux:latest adstool --help

# Inspect the rootfs
docker run --rm -it beckhoff-rt-linux:latest

# Bring up systemd-managed services (advanced; still not real-time)
docker run --rm --privileged beckhoff-rt-linux:latest --systemd
```

## Architectures

`build.sh` builds `linux/amd64` and `linux/arm64` by default. Override with:

```bash
BHF_PLATFORMS=linux/amd64 ./docker/scripts/build.sh --smoke
```

Each platform is built and loaded separately under a per-arch tag
(`beckhoff-rt-linux:<sha>-amd64`), because Docker's classic overlay2 image
store cannot load a multi-arch manifest list. The unsuffixed `:latest` and
`:<sha>` tags point at your host's native architecture, so a bare `docker run`
never silently emulates. A true manifest list is assembled only on `--push`,
which uses a dedicated `docker-container` builder.

On Apple Silicon, `linux/amd64` runs under emulation — fine for shell,
inspection, and cross-compile prep, noticeably slow for real workloads.

## CI

Two workflows:

- **`lint.yml`** — always-on. ShellCheck on every `*.sh`, hadolint on the
  Dockerfile, and a gitignore audit that fails if blocked patterns
  (`*.img`, `*.zip`, `.env`, `docs/superpowers/`, etc.) are tracked.

- **`build.yml`** — manual `workflow_dispatch`. Reads `BECKHOFF_EMAIL` and
  `BECKHOFF_PASSWORD` from repo secrets, builds and smoke-tests `linux/amd64`
  natively, and uploads the image as a workflow artifact. With input
  `push_to_ghcr=true`, it also sets up QEMU and pushes a multi-arch manifest to
  `ghcr.io/<owner>/beckhoff-rt-linux`.

Configure secrets in: **Settings → Secrets and variables → Actions**.

## Pushing to a private registry locally

```bash
export BHF_PUSH_REGISTRY=ghcr.io/yourname        # or any registry/namespace
docker login "$BHF_PUSH_REGISTRY"
./docker/scripts/build.sh --push
```

Verify the package is **private** afterwards. On GHCR a newly created package
is private by default, but a repo-linked package can inherit visibility — check
it rather than assuming. See [Licensing](#licensing) before pushing anywhere.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `preflight: BuildKit required` | Old Docker or buildx missing | `export DOCKER_BUILDKIT=1` or install `docker buildx` |
| `preflight: BECKHOFF_* is empty in .env` | Placeholder values still in `.env` | Fill in real credentials; preflight only checks non-emptiness, so placeholders pass and fail later as a 401 |
| `apt-get update` 401/403 | Wrong credentials | Recheck `.env` against your Beckhoff portal |
| 404 on `Release` | Wrong suite | Suites are `trixie-*` / `bookworm-unstable`; see `docker/apt-config/bhf.list.template` |
| `GPG fingerprint mismatch` during build | Key rotated, or MITM | Verify the new fingerprint with Beckhoff, then update `docker/apt-config/bhf-fingerprint.txt` |
| `docker exporter does not currently support exporting manifest lists` | Multi-arch `--load` on the overlay2 image store | Expected — `build.sh` builds per-arch instead. To load one manifest, enable the containerd image store in Docker Desktop |
| Postinst failure during install | Package expects hardware or an RT kernel | `dpkg-divert` the offending postinst before the install `RUN`; see the plan's Task 11 escalation ladder |

## License

Scripts, Dockerfile, and workflows in this repo: MIT.
Beckhoff packages inside the built image: see [Licensing](#licensing) above —
they are proprietary and are never redistributed by this repository.

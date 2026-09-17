# beckhoff-rt-linux Docker image

A Debian-based Docker image built from Beckhoff's official APT repository at
`deb.beckhoff.com`. Suitable for dev and CI use of the TwinCAT/XAR userspace,
cross-compiling against the Beckhoff libraries, and running Beckhoff CLI tools.

**Not real-time.** Containers share the host kernel, so real-time scheduling
needs two things the default `docker run` does not give you:

- `CAP_SYS_NICE`: Docker's default capability set omits it. Add
  `--cap-add SYS_NICE` (or `--privileged`).
- a `PREEMPT_RT` host kernel: nothing inside the container substitutes for it.

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
| The image you build from them | Contains proprietary Beckhoff software; the notice above governs it |

### Recommended posture

This is operational guidance, not legal advice. If in doubt, ask Beckhoff.

1. **Keep built images private.** Never push to a public registry. If you use
   the `push_to_ghcr` workflow input, confirm the resulting GHCR package is
   marked **private**: a public one distributes Beckhoff software to anyone.
2. **Let each user build their own image** rather than sharing yours. The
   build is reproducible and takes minutes; every colleague already needs a
   Beckhoff account to be entitled to the software anyway.
3. **Treat it as testing-only** unless you hold a commercial license and
   license batch. That is Beckhoff's wording, and it covers CI and development
   use of an unlicensed runtime.
4. **Do not bake credentials into the image.** The build already prevents this:
  credentials are mounted as BuildKit secrets and never written to a layer,
   and smoke check 6 fails the build if any apt auth survives. Keep it that way
   if you modify the Dockerfile: a leaked image would expose your Beckhoff
   account, not just the software.
5. **Redistribution to third parties needs explicit Beckhoff permission.**
   That decision is **yours as the builder**, not this repo's.

## Prerequisites

- Docker with BuildKit (`docker buildx version` should succeed)
- A Beckhoff customer account with access to `deb.beckhoff.com`
- Linux x86_64 host, or Apple Silicon (both `linux/amd64` and `linux/arm64` are
  buildable, see [Architectures](#architectures))
- **Running the XAR runtime in Docker needs a real x86_64 engine.** Docker on
  Apple Silicon cannot run it. A full-system x86 QEMU VM on the Mac can, for
  offline simulation only, see [Running from a Mac (Apple Silicon)](#running-from-a-mac-apple-silicon).

## Quick start

```bash
cp .env.example .env
$EDITOR .env                          # fill in BECKHOFF_EMAIL and BECKHOFF_PASSWORD

./docker/scripts/build.sh --smoke     # builds every platform and smoke-tests each
docker run --rm -it beckhoff-rt-linux:latest    # shell into /work
```

If your password contains shell metacharacters, `(`, `)`, `$`, backticks,
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

# Run the TwinCAT runtime so an XAE can connect, see the next section
./docker/scripts/run-xar.sh
```

Note the entrypoint's `--systemd` flag is inert: the slim image does not
contain systemd, so the unit files shipped by the Beckhoff packages are never
used. `run-xar.sh` starts the service chain directly instead.

## Running the TwinCAT runtime (XAR)

```bash
./docker/scripts/run-xar.sh            # start detached container 'beckhoff-xar'
./docker/scripts/run-xar.sh --replace  # recreate it
./docker/scripts/run-xar.sh --down     # remove the container (volume kept)
```

The script runs `TcSysConf` followed by `TcSystemServiceUm -f 0x5 -i <NetId>`
as the container's foreground process, publishes ADS (`48898/tcp`), Secure ADS
(`8016/tcp`) and discovery (`48899/udp`), and persists `/etc/TwinCAT` in a
named volume so the AmsNetId and routes survive restarts. It also creates a
Linux user inside the container, because the runtime validates XAE route-add
credentials against Linux system users (via `tcauth`).

Configuration, all optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `BHF_IMAGE` | `beckhoff-rt-linux:latest` | Image to run |
| `BHF_CONTAINER` | `beckhoff-xar` | Container name |
| `BHF_VOLUME` | `beckhoff-xar-data` | Volume for `/etc/TwinCAT` |
| `BHF_NETID` | `192.168.77.10.1.1` | AmsNetId. Without an explicit one the service derives `0.0.0.0.1.1` off Beckhoff hardware |
| `BHF_ADS_USER` / `BHF_ADS_PASSWORD` | `Administrator` / `1` | Route-add credentials. Beckhoff's conventional defaults; change them for anything reachable by others |
| `BHF_PRIVILEGED` | `0` | `1` runs `--privileged` instead of `--cap-add SYS_NICE --ulimit memlock=-1` |
| `BHF_ENGINE_HOST` | derived | Hostname/IP printed in the XAE route hint. Auto-derived from the active Docker context / `DOCKER_HOST`; set it when the routable address differs (tunnels, NAT) |

From the XAE: **Add Route** → enter this host's IP (broadcast search will not
cross the Docker NAT), Secure ADS, and the credentials above.

`run-xar.sh` verifies the runtime actually registered an ADS server before it
reports success: it probes the local system service (`adstool 127.0.0.1
state`). If no server registers, the normal outcome on an unsupported or
emulated host, it prints a diagnosis and exits non-zero, leaving the container
up for inspection. See [Where the runtime actually starts](#where-the-runtime-actually-starts).

### Where the runtime actually starts

The XAR binds to hardware it recognizes; the container transport coming up
does not mean the runtime did:

- **amd64**: real Intel/AMD silicon. It needs a real PC underneath (SMBIOS/DMI,
  unrestricted `/dev/mem`, a CPUID it recognises). Under emulation it fails for
  one of two reasons: a TSO-less x86 layer (QEMU-user, the Windows-on-ARM x64
  emulator) breaks the memory ordering the ADS router relies on; Apple's Rosetta
  gets the memory ordering right, but the container has no real PC beneath it and
  the system service aborts in its hardware layer. Either way no ADS server
  registers. A full-system x86 VM that presents a complete PC (QEMU with UEFI and
  SMBIOS) does start it, measured on an M3 Max. See
  [Running from a Mac](#running-from-a-mac-apple-silicon) for the detail.
- **arm64**: Beckhoff CX8290/CX9240 only. The binaries match the device-tree
  `compatible` strings `cx8200`/`cx9240`; generic ARM boards (Raspberry Pi,
  Revolution Pi) will not work, RT kernel or not.

On unsupported hosts the container still answers UDP discovery (`adstool
<host> netid` returns the NetId), but the system service and every AMS port
reply with ADS error 6 (target port not found) and the XAE cannot attach.
`run-xar.sh` detects exactly this (its post-start `adstool 127.0.0.1 state`
probe) and fails with a diagnosis instead of reporting a dead container as up.

If your development machine is an Apple Silicon Mac, see the next section for
the working topology.

## Running from a Mac (Apple Silicon)

Short version, all measured on an M3 Max:

| Goal | On the Mac alone | Status |
|------|------------------|--------|
| Edit and compile PLC projects | XAE in a Parallels Windows VM | Works |
| Run the XAR in Docker (either image arch) | No | Fails, see table below |
| Run the XAR for offline simulation and TcUnit | Beckhoff RT Linux + `tc31-xar-um` in a full-system x86 **QEMU** VM | Works (2026-09-16), unsupported, 10 ms tasks |
| Real-time, EtherCAT, 1 ms tasks | No | Needs a real x86_64 machine or a Beckhoff CX |

You cannot run the XAR runtime in **Docker** on an Apple Silicon Mac, on either
image architecture, and, contrary to the usual explanation, the "x86 memory
model" is not what stops it. Each Docker path was tested:

| Path | What happens | Root cause (verified) |
|------|--------------|-----------------------|
| Docker **amd64**, Rosetta | `TcSysConf` completes (once `/sys/kernel/iommu_groups` exists), but the system service aborts in its HAL: `Unknown Intel CPU model`, `Mapping memory failed … /dev/mem … Operation not permitted`; `state` → ADS error 6. | Rosetta emulates x86 memory ordering (TSO) correctly, so the router is not the blocker. Docker's LinuxKit VM is not a real PC: no SMBIOS/DMI, `/dev/mem` restricted (`STRICT_DEVMEM`), a CPUID TwinCAT does not recognise. |
| Docker **amd64**, QEMU-user, or **Windows-on-ARM** x64 emulator | ADS router never starts. | No hardware TSO, so x86 memory ordering is not preserved. This is the case Beckhoff support describes. |
| Docker **arm64**, native (no emulation) | `TcSystemService` runs, discovery answers, `state` → ADS error 6. Spoofing the identity gate (`/sys/firmware/devicetree/base/compatible` = `beckhoff,cx9240`) clears the check; then it **segfaults**. | The arm64 build is gated to Beckhoff CX (`beckhoff,cx8200`/`cx9240`), then drives their real peripherals (CCAT PCIe FPGA, board EEPROMs, fixed MMIO via `/dev/mem`) that do not exist on a Mac. |

The common thread: the runtime needs a **complete PC** underneath: a genuine
x86_64 machine (TwinCAT runs on generic x86 by design), a Beckhoff CX, or a
full-system x86 VM that fakes one (see the next section). Containers, privilege,
`/sys` doctoring or device-tree spoofing do not substitute for it. As of 2026
there is no ARM-native TwinCAT runtime and no Apple-Silicon support.

### Develop offline: XAE without a runtime

Run XAE in the Parallels Windows VM (x64 under Windows' emulation). Editing
POUs and **building** the PLC project needs no runtime, so it works with no
network and no hardware. Activating, going online, running and debugging need a
runtime: either the QEMU VM below or a real x86_64 engine.

### Simulate offline: the XAR in a QEMU x86 VM on the Mac

Measured on 2026-09-16 on a MacBook Pro M3 Max (macOS 26.6, QEMU 11.1.1 from
Homebrew, Parallels 26.4.1 with a Windows 11 ARM VM running TwinCAT 4026 XAE):
Beckhoff RT Linux (installer build 306707, kernel `6.19.10-rt1-bhf2 PREEMPT_RT`)
installs in a full-system `qemu-system-x86_64` VM, `tc31-xar-um 4026.28.0-1`
starts and logs `TwinCAT system start completed. AdsState: >15<`, XAE in
Parallels adds the route, activates a PLC project and the runtime enters RUN
(AdsState 5). The only thing that stopped it was the missing TC3 PLC trial
licence on the fresh install, which XAE requests interactively.

Why this works where Docker does not: the VM presents a complete PC. UEFI
(OVMF), SMBIOS/DMI (`-smbios` set to a Beckhoff C6015), a Skylake CPUID, an
IOMMU and unrestricted `/dev/mem` inside the guest. QEMU runs the x86 guest in
software (TCG); there is no hardware acceleration for x86 on Apple Silicon.

Rebuild it with the scripts in
[`docs/research/apple-silicon-qemu/`](docs/research/apple-silicon-qemu/README.md)
(about an hour end to end):

1. `brew install qemu` and download the Beckhoff RT Linux installer image from
   myBeckhoff (not in git).
2. `install-vm.sh <installer.img>`: boots the installer with a blank 16 GB
   `target.qcow2`, drive the TUI over VNC `:5` or with `vm.py`. About 10 minutes.
3. `start-vm.sh`: boots the installed guest and forwards SSH (2222), ADS
   (48898, 8016) and discovery (48899/udp) to the Mac. Inside the guest, add your
   `deb.beckhoff.com` credentials to `/etc/apt/auth.conf.d/bhf.conf` and
   `apt install tc31-xar-um tcsysconf adstool`.
4. Routes: install the `StaticRoutes.xml` template on the guest (XAE's NetId at
   `10.0.2.2`, the QEMU gateway) and the `10-ads.conf` nftables drop-in. On
   Windows, add a route to the Mac's Parallels bridge IP (usually `10.211.55.2`)
   with the guest NetId `0.18.52.86.1.1`, or run `windows/add-route.ps1`.
5. In XAE pick the route, request the 7-day trial licence, activate, RUN.

Limits and gotchas, all measured:

- **Timing is emulation-bound.** `cyclictest` at a 1 ms interval inside the
  guest: min 46 µs, avg 900 µs, max 5.2 ms. A 1 ms PLC task overruns
  continuously; **use 10 ms tasks** for logic simulation and TcUnit. No
  real-time, no EtherCAT (the user-mode runtime has none anyway).
- **Beckhoff RT Linux firewalls plain ADS.** Its nftables opens only Secure ADS
  (8016), SSH, HTTPS and discovery (48899/udp) by default. Either add the
  `10-ads.conf` drop-in for 48898 or use a Secure ADS route.
- **No broadcast discovery.** QEMU user-mode networking has no inbound path, so
  XAE must be given the Mac's address explicitly; traffic from Windows reaches
  the guest via the Mac, which is why the guest route points at `10.0.2.2`.
- **`adstool` is not a liveness probe here.** It returns ADS error 6 against this
  runtime even when XAE is happily online. Check the journal for "start
  completed" or use the Windows router (`windows/ads-state.ps1`).
- **Unsupported by Beckhoff.** Offline simulation and testing only; the
  licensing notice above applies unchanged.

Full forensics, the route-by-route verdict and the raw measurements are in
[docs/research/apple-silicon-xar-feasibility.md](docs/research/apple-silicon-xar-feasibility.md#measured-result-2026-09-16-route-2-on-an-m3-max).

### Simulate against a real x86_64 engine

For anything beyond simulation (real cycle times, EtherCAT, a supported
setup) keep XAE on the Mac and put the XAR on a real x86_64 engine reachable
over the network. XAE is only an ADS client:

```
  Mac (Apple Silicon)                      x86_64 Linux host
  +-------------------------+             +--------------------------+
  | Parallels VM            |   ADS/TCP   | Docker engine            |
  |  Windows + TwinCAT XAE  |--48898/8016>|  beckhoff-xar container  |
  |  (ADS client)           |   48899/udp |  (TcSystemServiceUm)     |
  +-------------------------+             +--------------------------+
```

The x86_64 host can be anything real: a NUC or spare PC, a cloud VM, or an x86
CI runner. You drive it from the Mac with a remote Docker context, so the same
`build.sh` / `run-xar.sh` work unchanged; they act on the active context.

1. **Provision the x86_64 host** with Docker and network reachability from the
   Mac (and from the Parallels VM's network).

2. **Point the Mac's Docker CLI at it.** Over SSH is simplest:

   ```bash
   docker context create x86 --docker host=ssh://user@x86-host
   docker context use x86
   docker version --format '{{.Server.Arch}}'   # must print: amd64
   ```

3. **Build (or load) the image on that engine.** `build.sh` honours the active
   context and tags `:latest` for the engine's native arch:

   ```bash
   ./docker/scripts/build.sh --smoke
   ```

   Or build once elsewhere and transfer it: `docker save beckhoff-rt-linux:latest | docker -c x86 load`.

4. **Start the runtime on the x86 engine:**

   ```bash
   ./docker/scripts/run-xar.sh
   ```

   Because the engine is real x86, the ADS router starts and the post-start
   health check passes. The script prints the address to route XAE to; if the
   derived host is wrong for your network, set `BHF_ENGINE_HOST=<routable-ip>`.

5. **Attach XAE (in Parallels):** SYSTEM → Routes → **Add Route** → enter the
   x86 host's IP (broadcast discovery will not cross the VM/Docker NAT), tick
   Secure ADS, and use the `BHF_ADS_USER` / `BHF_ADS_PASSWORD` credentials.
   Then set it as the target system and activate your configuration.

**If the Mac is genuinely all you have**, no x86 machine anywhere, the QEMU VM
above is the only way to run the runtime locally, and only for simulation. ADS
*client* code (the standalone `adstool`, or the
[Beckhoff/ADS](https://github.com/Beckhoff/ADS) library) builds natively on
macOS and can target either that VM or a real TwinCAT system elsewhere.

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

On Apple Silicon, `linux/amd64` runs under emulation: fine for shell,
inspection, and cross-compile prep, noticeably slow for real workloads.

## CI

Two workflows:

- **`lint.yml`**: always-on. ShellCheck on every `*.sh`, hadolint on the
  Dockerfile, and a gitignore audit that fails if blocked patterns
  (`*.img`, `*.zip`, `.env`, `docs/superpowers/`, etc.) are tracked.

- **`build.yml`**: manual `workflow_dispatch`. Reads `BECKHOFF_EMAIL` and
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
is private by default, but a repo-linked package can inherit visibility; check
it rather than assuming. See [Licensing](#licensing) before pushing anywhere.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `preflight: BuildKit required` | Old Docker or buildx missing | `export DOCKER_BUILDKIT=1` or install `docker buildx` |
| `preflight: BECKHOFF_* is empty in .env` | Placeholder values still in `.env` | Fill in real credentials; preflight only checks non-emptiness, so placeholders pass and fail later as a 401 |
| `apt-get update` 401/403 | Wrong credentials | Recheck `.env` against your Beckhoff portal |
| 404 on `Release` | Wrong suite | Suites are `trixie-*` / `bookworm-unstable`; see `docker/apt-config/bhf.list.template` |
| `GPG fingerprint mismatch` during build | Key rotated, or MITM | Verify the new fingerprint with Beckhoff, then update `docker/apt-config/bhf-fingerprint.txt` |
| `docker exporter does not currently support exporting manifest lists` | Multi-arch `--load` on the overlay2 image store | Expected; `build.sh` builds per-arch instead. To load one manifest, enable the containerd image store in Docker Desktop |
| Postinst failure during install | Package expects hardware or an RT kernel | `dpkg-divert` the offending postinst before the install `RUN`; see the plan's Task 11 escalation ladder |
| XAE finds the target but cannot attach; `adstool <host> state` returns ADS error 6; `run-xar.sh` exits non-zero with "did not register an ADS server" | Runtime registered no ADS servers: unsupported/emulated host (see [Where the runtime actually starts](#where-the-runtime-actually-starts)) | Run the container on a real x86_64 engine or Beckhoff CX; from a Mac use a remote context, or the QEMU x86 VM for offline simulation, see [Running from a Mac](#running-from-a-mac-apple-silicon) |

## License

Scripts, Dockerfile, and workflows in this repo: MIT.
Beckhoff packages inside the built image: see [Licensing](#licensing) above,
they are proprietary and are never redistributed by this repository.

# Running TwinCAT 3 XAR on Apple Silicon: deep-engineering feasibility

Scope: can the Beckhoff TwinCAT 3 runtime (XAR), the Linux user-mode runtime
`tc31-xar-um`, the classic Windows/BSD XAR, or the arm64 Beckhoff RT Linux build,
be made to run on an Apple Silicon (M-series) Mac by any route deeper than the
already-measured Docker paths? This note digs underneath the facts already
established in the repo `README.md` ("Where the runtime actually starts",
"Running from a Mac"), by disassembling the shipped runtime binaries and checking
Beckhoff, QEMU, Apple, and kernel primary sources.

Runtime binaries examined (extracted from the local images
`beckhoff-rt-linux:2906c10-amd64` / `-arm64`, package `tc31-xar-um 4026.27.8-1`):
`/usr/lib/libTcPalDrvUm.so`, `/usr/lib/libTcOsSys.so`, `/usr/lib/libTcSystemUm.so`,
`/usr/bin/TcSystemServiceUm`, `/usr/bin/TcSysConf`. All are stripped PIE ELFs
(`TcSystemServiceUm`: x86-64 / ARM aarch64 respectively). The
hardware-abstraction layer (PAL) that does every host probe is
`libTcPalDrvUm.so`; the symbol `tc_pal_set_dpdk_functions` is the nearest exported
symbol and appears in disassembly as an umbrella label for much of `.text`
(it is not the real function name, the binaries are stripped).

---

## TL;DR: verdict table

| # | Route | What blocks it | Fundamental vs. effort | Effort estimate | RT / sim viability | Confidence |
|---|-------|----------------|------------------------|-----------------|--------------------|------------|
| 1 | amd64 XAR under **Docker Desktop / Rosetta** (baseline, already measured) | LinuxKit VM is not a PC: `/dev/mem` physical mapping refused (`STRICT_DEVMEM`), no SMBIOS/DMI, CPUID unrecognized | Fixed by design of Docker's VM, not the runtime | n/a (measured to fail) | none | High |
| 2 | amd64 XAR in a **self-controlled full-system x86 VM** (QEMU TCG / UTM / Parallels x86 preview) presenting a complete fake PC | **Measured 2026-09-16: works.** Beckhoff RT Linux + `tc31-xar-um` boots in QEMU TCG, XAE (Parallels) activates a PLC project on it and the runtime enters RUN (AdsState 5); the only stop was the missing TC3 PLC licence. See [Measured result](#measured-result-2026-09-16-route-2-on-an-m3-max). Remaining: TCG speed/jitter, no EtherCAT | Solved for sim; RT is emulation-bound | ~1 h to reproduce with the scripts in `apple-silicon-qemu/` | Sim/TcUnit only, heavy jitter (cyclictest max 5.2 ms); **no** RT, **no** EtherCAT | High |
| 3 | amd64 XAR, **CPUID/SMBIOS spoofing** to clear "Unknown Intel CPU model" | The message is cosmetic (a microarch *name* decoder). Spoofing clears the log line but not the real blocker (`/dev/mem`) | Effort, but solves the wrong problem | Hours | Doesn't change outcome alone | High |
| 4 | amd64 XAR under **QEMU-user / Windows-on-ARM x64 layer** (no full VM) | No hardware TSO → ADS router memory ordering breaks; also no `/dev/mem` | Fundamental for the emulator class chosen | n/a | none | High |
| 5 | **arm64 (native) XAR** on a plain arm64 Linux VM (Lima/Tart/UTM-Apple-Virt), even with spoofed device-tree `compatible` | After the `cx8200`/`cx9240` gate, the PAL drives real CX peripherals: CCAT PCIe FPGA (Beckhoff VID `0x15EC`), fixed MMIO via `/dev/mem`, board I²C EEPROM at bus 3 / addr 0x50, GPIO. None exist on a Mac | Fundamental (needs physical Beckhoff silicon or a full peripheral emulation) | Weeks-months to fake peripherals, still unsupported | none | High |
| 6 | **arm64 VM + emulated CCAT / fake CX device tree** (QEMU aarch64 with a synthetic CCAT PCI model + DT) | Would require writing a QEMU device model of the CCAT FPGA function blocks and every board peripheral the PAL touches, matched to undocumented register semantics | Effort, very large; reverse-engineering-grade | Many weeks minimum | Possibly sim-only if ever completed | Low-Medium |
| 7 | **Rosetta-for-Linux in a self-controlled Virtualization.framework VM** (Lima/Tart/UTM-Apple), amd64 XAR | Guest kernel is arm64; Rosetta only translates *user-space* x86_64. `/dev/mem`, `/dev/cpu/*/msr`, SMBIOS are the arm64 host's, same wall as route 1, minus Docker | Fundamental for this topology | Days | none | High |
| 8 | **Windows XAR (x64) in Parallels/UTM x86 emulation** | XAR real-time needs exclusive VT-x and kernel-mode HAL; emulated x86 offers no nested VT-x, Parallels preview is UEFI-only/1-vCPU/"really slow". Only *XarMode: UM* (no RT) could run | Fundamental for RT; UM path is engineering-only | Days | UM sim only (Windows) | Medium-High |

Bottom line: **no route yields real-time, but route 2 is confirmed to run the
runtime.** A full-system x86 VM running the **user-mode** runtime starts, registers
ADS, accepts an activated PLC project from XAE and enters RUN, because a full VM
restores the one thing Docker withholds: a writable `/dev/mem` over a synthetic
PC address space. Every arm64-native route dies on physical Beckhoff peripherals.

---

## What the binaries actually check (forensics)

### amd64 PAL host probes

`strings`/`objdump -d` over `libTcPalDrvUm.so`, `TcSystemServiceUm`, `TcSysConf`
show the PAL probes, in one place, essentially the full surface of a real PC:

- **CPU identity via the `cpuid` instruction** (not `/proc/cpuinfo` alone).
  `libTcPalDrvUm.so` executes `cpuid` leaf 0 to read the vendor string, comparing
  against `0x756e6547 / 0x49656e69 / 0x6c65746e` = `"GenuineIntel"` and
  `0x68747541…"AuthenticAMD"` (disasm at file offsets `0x43a3a`, `0x43a9e`,
  `0x5e809`). Leaf 1 is read for family/model/stepping (`0x43a9e`:
  `cpuid; shr $8; and $0xf` → family into struct+0x84).
- **CPU model → microarchitecture NAME decoder.** The string
  `"Unknown Intel CPU model: 0x%02X"` (rodata `0xdd61`) is the *default* arm of a
  large switch that maps Intel family/model bytes to marketing names. Decoding the
  `movabs` immediates around offset `0x43ba7`-`0x43e9e` recovers the table:
  `Sandy Bridge, Ivy Bridge, Broadwell, Skylake, Comet Lake, Ice Lake, Tiger Lake,
  Alder Lake, Raptor Lake, Meteor Lake, Bartlett Lake, Bay Trail, Apollo Lake,
  Elkhart Lake, Amston Lake, Xeon Broadwell/Skylake, …`; the AMD side has
  `AMD Zen (Family 17h)…Zen 5 (Family 1Ah)` and `"Unknown AMD CPU family: 0x%02X,
  model: 0x%02X"`. **Interpretation:** this is a *name / power-and-frequency
  optimization* lookup, not a licensing gate. The message is emitted when the
  model byte is unrecognized (the repo measured `0x2C` = Westmere-era under Docker's
  vCPU). It is cosmetic/telemetry: spoofing CPUID to a known model (trivial with
  QEMU `-cpu <model>`) removes the message but does not by itself let the runtime
  start, the fatal error is the physical-memory mapping below.
- **`/dev/mem` physical mapping: the real blocker.** In `libTcPalDrvUm.so` the
  PAL does `open("/dev/mem", 0x101002)` (= `O_RDWR|O_SYNC|O_CLOEXEC`) then `mmap`
  of a physical address/length; on failure it logs
  `"Mapping memory failed: %s (%d) (pPhysAddr=0x%lx, nMemSize=%u)"` (rodata
  `0xe54e`; disasm `0x30c10`-`0x30d33`). This is how it reaches CCAT MMIO, DMI
  tables, and fixed board regions. Docker Desktop's LinuxKit VM enforces
  `CONFIG_STRICT_DEVMEM`, so this `mmap`/access returns `EPERM`, matching the
  measured "Operation not permitted". (See kernel semantics below.)
- **SMBIOS / DMI**: `/sys/firmware/dmi/tables/DMI`, `/sys/class/dmi/id/`,
  `/sys/class/dmi/id/product_name`, `/sys/class/dmi/id/product_uuid`, and parsing
  of "DMI Type 41" structures (`Found DMI Type 41 structure with insufficient
  length`). A VM with no DMI (Docker) yields nothing here.
- **VFIO real-time Ethernet path**: `/dev/vfio/vfio`, `/dev/vfio/%d`,
  `/sys/kernel/iommu_groups`, `/sys/class/iommu`, `vfio-pci` bind/unbind under
  `/sys/bus/pci/devices/%s/driver*`, `enable_unsafe_noiommu_mode`,
  `CONFIG_VFIO_NOIOMMU`, and the message
  `"IOMMU is disabled. Enable VT-d in BIOS/UEFI … intel_iommu=on iommu=pt"`.
  Real-time Ethernet requires a PCI NIC bound to `vfio-pci`; absent it, the PAL
  logs `"Real-time Ethernet communication as well as CCAT are not available."`
- **MSR access (TcSysConf only)**: `/dev/cpu/0/msr`, `/dev/cpu/`,
  `/sys/module/msr/parameters/allow_writes`, `"Failed to get IA32 MISC ENABLE
  MSR"`, `"Failed to get IA32 POWER CTL MSR"`, `"MSR interface is not available.
  Please ensure the msr kernel module is loaded."` `TcSysConf` tunes MCA/watchdog
  and power MSRs; it also detects virtualization: `"Running in a hypervisor
  environment. Core optimizations not applicable."` (string near offset in
  `TcSysConf`), and `hypervisor` / `family` / `stepping` tokens.
- **Hypervisor detection (informational)**: `libTcOsSys.so` carries the classic
  vendor strings `KVMKVMKVM`, `VMwareVMware`, `Microsoft Hyper-V`, `VirtualBox`,
  `Oracle VirtualBox`, `BSD Hypervisor`, `VirtualApple`, plus
  `"no virtual machine" / "unknown virtual machine"`. So the runtime *knows* it is
  virtualized; on Linux user-mode this is not by itself a hard stop (unlike Windows
  RT, which refuses Hyper-V, see Beckhoff sources).
- **Real-time / scheduling probes**: `/sys/kernel/realtime`, `SCHED_FIFO` via
  `pthread_attr_setschedpolicy/param/inheritsched`, `"Insufficient privileges to
  set realtime scheduling."`, `"Realtime kernel is not active."`,
  `/sys/devices/system/cpu/isolated`, `/sys/fs/cgroup/cpuset.cpus.effective`,
  hugepages under `/sys/kernel/mm/hugepages/…` and `/proc/meminfo`.

Takeaway for a *fake PC*: every amd64 identity probe (CPUID, DMI, PCI, `/dev/mem`)
is exactly what a **full-system** x86 VM provides and what Docker's cut-down VM
does not. That is why route 2 is the only amd64 candidate that could clear the
identity wall, it does not need real Beckhoff hardware for the user-mode runtime,
only a believable PC. It still gets no EtherCAT (no `vfio-pci` NIC) and no RT.

### arm64 PAL host probes (the CX gate and what's behind it)

The arm64 `libTcPalDrvUm.so` reads the device-tree `compatible` file
(`/sys/firmware/devicetree/base/compatible`, also
`"Error: Could not read 'compatible' file!"`) and does substring matching. Resolved
`adrp+add` pairs (disasm at `0x3da94`/`0x3daa0`) show it `strstr`-matches the
compatible blob against the constants `cx8200` and `cx9240` (rodata; the arm64
strings table lists the pairs `beckhoff`/`cx8200`, `beckhoff`/`cx9240`). This is
the gate the repo already spoofs past.

Immediately *after* a match, the PAL hard-codes that board's peripherals; this is
the wall:

- **`'CX9240' device found`** branch (disasm `0x3da98` region) sets fixed
  parameters: `w20=#0x51`, `w22=#0x2c00` (a fixed MMIO window size) and points at
  the board EEPROM path **`/sys/bus/i2c/devices/3-0050/eeprom`** (rodata `0xd2a9`,
  referenced at `0x3dac4`), i.e. I²C bus 3, address 0x50. The CX8290 branch uses
  **`/sys/bus/i2c/devices/1-0050/eeprom`**. These are physical board EEPROMs.
- **`"Device type not found in the address array"`** (rodata `0x11d21`,
  referenced twice at `0x6e828` and `0x6e9d0`) is emitted when the detected device
  is not present in a hard-coded *address array* of known CX boards, this is the
  segfault-adjacent path the repo observed after spoofing: the code proceeds to
  drive a device that is not really there.
- **CCAT peripheral access**: identical CCAT surface as amd64,
  `CcatBaseAddr`, `"Error no node Value with the attribute Name=CcatBaseAddr"`,
  `"CCAT function not exit on this device"`, `"Error get ccat base address"`,
  `"Error prepare the ccat device"`, `"No CCAT devices found on PCI bus."`, plus
  GPIO (`"Null pointer gpio_address"`, `"Malloc gpio address"`), LEDs
  (`/sys/class/leds/%s/brightness`, ccat red/green/blue channel control), MTD
  (`/dev/mtd0`), and CCAT tap devices (`/dev/net/tun`, `tap_open: open ccat tap
  device`). `libTcSystemUm.so` even names the SoM model string `CX9240-M910`.
- **ARM CPU part decoder**: `"Unknown ARM CPU part: 0x%03X"` (rodata `0xd5fe`,
  ref `0x4c9bc`), analogous to the Intel name decoder; cosmetic.

Takeaway for a *fake CX*: clearing the `compatible` gate is not enough. The PAL
then expects a Beckhoff CCAT FPGA on the PCI bus (see CCAT IDs below), fixed MMIO
via `/dev/mem`, an I²C EEPROM at a specific bus/address, and GPIO/LED lines. On a
Mac VM none of these exist; faking them means writing device models (route 6),
which is reverse-engineering-grade work against undocumented register semantics.

### The CCAT interface (what an emulation would have to implement)

Beckhoff's open-source CCAT Linux driver documents the register door the PAL
drives. From `Beckhoff/CCAT` (`module.c`):

```
#define PCI_VENDOR_ID_BECKHOFF       0x15EC
#define PCI_DEVICE_ID_BECKHOFF_CCAT  0x5000
static const struct pci_device_id pci_ids[] = {
    {PCI_DEVICE(PCI_VENDOR_ID_BECKHOFF, PCI_DEVICE_ID_BECKHOFF_CCAT)}, {0,} };
```

CCAT is a PCIe-attached FPGA whose BAR exposes an *info block* table of function
blocks, each with a `type`: `CCATINFO_ETHERCAT_NODMA`, `CCATINFO_ETHERCAT_MASTER_DMA`,
`CCATINFO_GPIO`, `CCATINFO_EPCS_PROM`, `CCATINFO_SRAM`, `CCATINFO_SYSTEMTIME`
(read via `memcpy_fromio(&next->info, addr, …)`). The driver README lists supported
devices `CX50xx, CX51xx, CX20xx`, the CCAT is an x86-CX (and higher CX) part; the
CX82xx/CX9240 arm64 boards reach equivalent function blocks through the PAL's own
MMIO/`/dev/mem` path rather than this driver, but the register model is the CCAT
family. A QEMU device model would have to reproduce the info-block layout and per
function-block registers (EtherCAT DMA, systime, GPIO, EEPROM/EPCS) well enough
that the closed PAL is satisfied, no public register spec exists, so this is
reverse engineering, not integration.

---

## Route-by-route evidence

### Route 1: Docker Desktop / Rosetta (baseline)
Already measured in `README.md`. The forensics above pin the two independent
failures: (a) the CPUID model byte is unrecognized → cosmetic
`Unknown Intel CPU model`; (b) `/dev/mem` `mmap` is refused by the LinuxKit VM's
`STRICT_DEVMEM` → fatal `Mapping memory failed … Operation not permitted`. Rosetta
preserves x86 TSO (see route 4/7), so memory ordering is *not* the Docker blocker,
the missing PC is.

### Route 2: Full-system x86 VM presenting a complete fake PC (best amd64 bet)
A full-system emulator (QEMU `qemu-system-x86_64` with TCG; UTM's QEMU backend;
Parallels' x86 preview) presents a synthetic-but-complete PC: SeaBIOS/OVMF, SMBIOS/DMI,
a q35/i440fx PCI bus, LAPIC/HPET/TSC, and, crucially, a RAM address space over
which the guest kernel's `/dev/mem` behaves like real hardware. Inside that guest
you run ordinary x86 Debian + the amd64 `tc31-xar-um` **user-mode** runtime.

Why it can clear the identity wall the forensics describe:
- CPUID is fully configurable: QEMU `-cpu <model>` (named Intel/AMD models) sets
  family/model/stepping/vendor; the `host` passthrough model is *not* usable under
  TCG (it needs KVM/HVF), but a named model is. This removes the "Unknown Intel CPU
  model" path.
- `/dev/mem`: with a normal guest kernel you control `CONFIG_STRICT_DEVMEM`. Even
  with `STRICT_DEVMEM=y`, the kernel help text says `/dev/mem` "only allows
  userspace access to PCI space and the BIOS code and data regions"; with it `=n`
  you allow all of memory. Either way the guest is a real kernel on a real (virtual)
  PC, unlike Docker's locked VM.
- SMBIOS/DMI: QEMU `-smbios` lets you populate DMI; `/sys/class/dmi/id/*` then
  answers.

Hard limits that remain:
- **No hardware acceleration for x86 on Apple Silicon.** QEMU's HVF accelerator on
  macOS runs guests of the host architecture; on Apple Silicon that is arm64 only.
  x86_64 guests therefore run under **TCG** (pure JIT emulation): "purely emulated"
  per QEMU docs. UTM confirms x86 on Apple Silicon uses QEMU/TCG. Parallels' own
  x86 emulator preview (Desktop 20.2+) is explicitly a technology preview that is
  "slow, *really* slow" (2-7 min boots), UEFI-only, **1 vCPU**, no USB, no nested
  virtualization, ≤8 GB RAM, unsuitable for anything but light poking.
- **No EtherCAT / real-time.** No `vfio-pci` NIC, no IOMMU passthrough of a Beckhoff
  NIC; the user-mode runtime has "no access to EtherCAT" by design regardless.
- **Correctness is unwarranted.** TCG is a best-effort emulator; Beckhoff does not
  support it. Fine for TcUnit / logic simulation, not for anything timing-sensitive.

Net: gets the amd64 **user-mode** runtime to start and register ADS for offline
simulation/TcUnit, at TCG speed and with heavy jitter. This was the "only offline
straw" the README named; the install test below confirms it end to end.

### Route 3: CPUID / SMBIOS spoofing alone
The forensics show the "Unknown Intel CPU model" string is a microarchitecture
*name* decoder, not a licence check. Spoofing CPUID (QEMU `-cpu`) or DMI (`-smbios`)
clears the cosmetic messages but does nothing about the `/dev/mem` mapping, which is
the actual abort. Useful only *inside* route 2, never on its own atop Docker.

### Route 4: QEMU-user / Windows-on-ARM x64 layer (no full VM)
Already measured to fail: the ADS router relies on x86 Total Store Order, and a
user-space translation layer without hardware TSO breaks it. QEMU's own MTTCG
documentation is explicit: for "a strongly ordered guest architecture … emulated on
a weakly ordered host the scope for a heavy performance impact is quite high," and
multi-threaded TCG is only enabled when "the host memory model is able to accommodate
the guest." x86-on-arm needs inserted barriers (single-thread TCG or `dmb`-heavy
codegen), which is why QEMU-user / the Windows-on-ARM emulator do not preserve the
ordering the router assumes. Rosetta *does* preserve TSO (Apple's translator sets
the CPU into a TSO mode), which is why route 1 fails on hardware, not ordering.

### Route 5: arm64-native XAR on a plain arm64 Linux VM
Runs natively (no emulation) under any Apple-Virtualization guest (Lima, Tart,
UTM-Apple, Docker arm64). Discovery answers, but ADS state → error 6, and spoofing
`/sys/firmware/devicetree/base/compatible` to `beckhoff,cx9240` clears the gate and
then segfaults; the forensics explain exactly why: the CX9240 branch immediately
reaches for `/sys/bus/i2c/devices/3-0050/eeprom`, a fixed MMIO window, CCAT on PCI,
and GPIO/LEDs that a Mac VM does not have; unmatched devices hit "Device type not
found in the address array". Fundamental without real Beckhoff silicon.

### Route 6: arm64 VM + emulated CCAT + fake CX device tree
Theoretically the "clean" arm64 path: a QEMU aarch64 machine with a hand-written DT
node set (`compatible = "beckhoff,cx9240"`, the expected reg/MMIO nodes, an I²C
EEPROM device at bus3/0x50) plus a **synthetic CCAT PCI device** (VID `0x15EC`, DID
`0x5000`) whose BAR implements the info-block table and function blocks the PAL
reads. This is a large reverse-engineering effort: the CCAT register semantics
beyond the open driver's enums are undocumented, and the PAL will drive systime,
DMA, EEPROM and GPIO blocks expecting believable behaviour. Even if completed it
would be sim-only (emulated timing) and unsupported. Low-to-medium confidence that
it is even tractable; certainly many weeks.

### Route 7: Rosetta-for-Linux in a self-controlled Virtualization.framework VM
Apple's Rosetta-for-Linux translates **user-space** x86_64 binaries inside an
**arm64** Linux guest (mounted via a virtiofs `rosetta` share + `binfmt_misc`); the
guest *kernel* is arm64. So `/dev/mem`, `/dev/cpu/*/msr` (arm64 kernels don't build
the x86 `msr` driver), SMBIOS/DMI and PCI are the arm64 host VM's, not a PC's, the
same wall as Docker (route 1), just outside Docker (Lima/Tart/UTM-Apple can host the
same thing). Rosetta reports a fixed synthetic CPUID to translated code
(`vendor_id VirtualApple`, `cpu family 6`, `model 142`, `stepping 10`, a hardcoded
`/proc/cpuinfo`), which is not user-configurable, so you cannot even present a
"known Intel model" the way QEMU `-cpu` can. Rosetta preserves TSO, so this is
strictly better than route 4 for ordering but still blocked by the missing PC.
Conclusion: self-hosting Rosetta buys nothing over Docker for the XAR.

### Route 8: Windows XAR (x64) under Parallels/UTM x86 emulation
Windows TwinCAT real-time (`XarMode: KM`) requires kernel-mode direct hardware
access and exclusive VT-x/AMD-V for shared cores, and Beckhoff explicitly states
"the real-time runtime environment cannot be started within a Hyper-V environment"
and that on emulated/virtualized hosts only engineering is possible. Emulated x86 on
Apple Silicon offers no nested VT-x (Parallels preview: "nested virtualization isn't
available", 1 vCPU). Beckhoff's own answer for such hosts is the **user-mode
runtime** (`XarMode: UM`): for "Windows on Arm® systems … User mode runtime (Default);
Real-time runtime: Not possible." So the *only* Windows path that could run at all
is UM, and UM is the same no-RT, 1 ms-minimum, no-EtherCAT sim environment as the
Linux user-mode runtime, but now stacked on top of "really slow" x86 emulation.
Worse than route 2, same ceiling.

---

## Real-time consequences (all routes)

Even where a runtime *starts* (routes 2 and 8, user-mode only), it is the TwinCAT
**Usermode Runtime**, whose documented limits are decisive for a 1 ms PLC task:

- "no guaranteed deterministic execution properties. The operating system is able
  to interrupt the Usermode Runtime at any time."
- "minimum base time of 1 ms", tasks configured faster than 1 ms are clamped to
  1 ms (others scaled), so sub-ms cycles are impossible.
- "no access to EtherCAT. The I/O part of the configuration is therefore normally
  disabled"; "CCAT-based network cards cannot be used."

Layer TCG emulation under that (routes 2/8) and jitter grows further, but for
**simulation, logic test, and TcUnit**, where the task just needs to execute
cyclically and answer ADS, not meet a deadline, that is tolerable. For any
hardware-in-the-loop, EtherCAT, motion, or timing-sensitive test it is not usable.
Beckhoff is unambiguous that deterministic RT needs "a complete system (hardware,
BIOS, operating system, driver software…)" and that on third-party PCs "flawless
real-time behavior cannot be guaranteed", Apple Silicon under emulation is far
outside that envelope.

Community evidence corroborates: TwinCAT RT in KVM/Proxmox works only with
`host-passthrough` CPU (real VT-x) and even then is fragile across config↔run
transitions (`RTIME: enter real-time mode fails!`, isolated-core startup failures);
those reports are on **x86 KVM with real virtualization extensions**, which Apple
Silicon emulation cannot provide. TwinCAT/BSD-in-a-VM reports are likewise all x86
hosts. No primary report of TwinCAT RT under QEMU-TCG or on Apple Silicon exists.

---

## Recommended experiment order (cheapest decisive test first)

1. **Confirm the `/dev/mem` wall is the amd64 blocker, not CPUID** (minutes, on the
   existing Docker amd64 image): run the container with
   `--cap-add SYS_RAWIO --device /dev/mem` (or `--privileged`) and re-check whether
   `TcSystemServiceUm` still logs `Mapping memory failed … Operation not permitted`.
   If it still fails, the LinuxKit kernel's `STRICT_DEVMEM` + absent physical ranges
   are confirmed as fundamental to Docker, decisive that no Docker flag fixes it.
2. **Full-system x86 user-mode VM (route 2)**: done; see the measured result
   below. Reproduce with `apple-silicon-qemu/install-vm.sh` + `start-vm.sh`. Do not
   use the open-source `adstool` as the success probe: it reports ADS error 6
   against this runtime even with routes in place, while the Windows TwinCAT router
   / `TwinCAT.Ads` talks to it fine.
3. **Only if a supported target is acceptable**: skip local emulation entirely and
   put the XAR on a real x86_64 engine over the network (the README's "Simulating
   against a real x86_64 engine" topology), the sole path that yields a supported,
   RT-capable runtime.
4. **Do not invest in routes 6/7 first.** Route 7 (self-hosted Rosetta) is provably
   equivalent to Docker; route 6 (emulated CCAT) is a multi-week reverse-engineering
   project with sim-only payoff and no support. They are last resorts, not
   experiments.

## Measured result (2026-09-16, route 2 on an M3 Max)

Host: MacBook Pro M3 Max, macOS 26.6, QEMU 11.1.1 (Homebrew), Parallels 26.4.1
with a Windows 11 ARM VM that has TwinCAT 4026 XAE (x64 under Windows' emulation).
Scripts: `apple-silicon-qemu/` next to this note. VM files: `~/VMs/beckhoff-rt-linux-qemu/`.

### What was run

1. `Beckhoff-RT-Linux-306707-installer-amd64.img` (repo root) booted in
   `qemu-system-x86_64 -machine q35 -accel tcg,thread=single -cpu Skylake-Client-v4
   -device intel-iommu -smbios type=1,manufacturer=Beckhoff,product=C6015` with OVMF.
   The installer TUI ("Beckhoff RT Linux Install" → disk → password → no LUKS) took
   about 5 minutes. Guest kernel: `6.19.10-rt1-bhf2 #1 SMP PREEMPT_RT`.
2. `sudo apt install adstool bhfinfo libadscomm tc31-orderno tc31-xar-um tcsysconf`
   with `/etc/apt/auth.conf.d/bhf.conf` (myBeckhoff credentials; the preinstalled
   `bhf.list` already points at `deb.beckhoff.com/debian trixie-stable`). Installed
   `tc31-xar-um 4026.28.0-1`.
3. `TcSystemServiceUm` journal on first start:
   `TwinCAT system start completed. AdsState: >15<`, `license validation status is
   Valid(3)`. Warnings only: EFI vars `Flags-4f74e256…`/`SetupOverrideActive-…`
   missing (Beckhoff BIOS), `RTE driver not found … libtcrte` (real-time Ethernet
   lib, not installed), `BBAPI device '/dev/bbapi' not present` (Beckhoff BIOS API),
   `TcSysConf: Running in a hypervisor environment. Core optimizations not applicable.`
   Compare Docker/Rosetta on the same Mac: never reaches "start completed", loops on
   `Opening file '/dev/mem' failed` and `Unknown Intel CPU model: 0x2C`.
4. Routing: `/etc/TwinCAT/3.1/Target/StaticRoutes.xml` on the guest with the XAE
   NetId `10.211.55.3.1.1` at address `10.0.2.2` (QEMU user-net gateway); on Windows
   4026 `C:\ProgramData\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml` (created) with
   `0.18.52.86.1.1` at `10.211.55.2` (the Mac's Parallels bridge IP, where QEMU's
   `hostfwd` listens), then `Restart-Service TcSysSrv`. The guest NetId is derived
   from the virtual NIC MAC (`52:54:00:12:34:56` → `0.18.52.86.1.1`).
5. Beckhoff RT Linux's nftables (`/etc/nftables.conf.d/`) drops plain ADS TCP 48898
   by default; only 8016 (Secure ADS), 22, 443 and UDP 48899 are open. Added
   `10-ads.conf` accepting 48898 for the plain-ADS route (or use a Secure ADS route).
6. From Windows, `TwinCAT.Ads.dll` 4.3.32 in 32-bit PowerShell (`Common32\TcAdsDll.dll`):
   port 10000 → `AdsState=Config`, ports 200 (TcRTime) and 300 (TcIo) → Config.
   `WriteControl(Run)` on 10000 is refused (`0x701` not supported); RUN needs an
   activated configuration, as on every target.
7. XAE Automation Interface (`TcXaeShell.DTE.17.0`, run in the user's desktop
   session via a scheduled task because SYSTEM/session-0 has no TwinCAT project
   support): new solution, `SetTargetNetId('0.18.52.86.1.1')`, `CreateChild` with
   `Standard PLC Template.plcproj`, MAIN = `nCounter := nCounter + 1;`,
   `ActivateConfiguration()`, `StartRestartTwinCAT()`; no errors. Guest journal:

   ```
   Activate configuration performed from 'PATRICKDAHLDDAA' (10.211.55.3.1.1) by 'patdhlk'
   TwinCAT System Start: AdsState: 5 NumProc: 2
   License Violation: License 'TC3 PLC' not found, Requested by 'QemuPlc Instance'
   TwinCAT system start completed. AdsState: >5<
   Error: >> license not found << checking TwinCAT Licenses!
   TwinCAT System Start: AdsState: 15
   ```

   `/etc/TwinCAT/3.1/Boot/CurrentProjectInfo.json` shows platform
   `"TwinCAT OS (x64-E)"` and `Plc/Port_851.app` (50 KB) was downloaded; XAE picked
   the Linux toolchain by itself. The runtime therefore **compiled, downloaded,
   loaded and started a PLC program under emulation on Apple Silicon**; it fell back
   to CONFIG within 300 ms purely because the fresh install has no TC3 PLC licence.
   A 7-day trial licence (XAE → System → License → captcha) is the remaining step
   and needs a human.

### Timing under TCG

`cyclictest -m -p 90 -i 1000 -l 5000 -t 1` inside the guest (2 vCPUs, single-thread
TCG, host otherwise idle):

| Min | Avg | Max |
|-----|-----|-----|
| 46 µs | 900 µs | 5246 µs |

At a 1 ms interval the average wake-up latency is almost the whole cycle and the
worst case is five cycles. A 1 ms PLC task will log cycle overruns continuously;
10 ms tasks are workable for logic simulation and TcUnit. QEMU refuses multi-threaded
TCG for a TSO guest on an ARM host by default (`thread=multi` can be forced, at the
cost of exactly the memory-ordering guarantee the ADS router needs). No HVF for x86.

### Residual gotchas

- `adstool` (open-source AdsLib) gets ADS error 6 on every port from this runtime
  even with matching routes and local NetIds; the .NET client over the Windows router
  works. Do not treat error 6 from `adstool` as "runtime dead".
- `TcSysConf` sees the hypervisor CPUID bit and skips core isolation; `-cpu
  Skylake-Client-v4,-hypervisor` is untested.
- Parallels' route to the VM goes through the Mac (`10.211.55.2`) because QEMU
  user-mode networking has no inbound path; a bridged/vmnet QEMU NIC would let XAE
  discover the target by broadcast.
- Everything here is unsupported by Beckhoff and for offline simulation only.

---

## Sources

Primary: runtime binaries (local, package `tc31-xar-um 4026.27.8-1`; paths inside
the extracted images):
- `/usr/lib/libTcPalDrvUm.so`: `open("/dev/mem",0x101002)`+`mmap` and
  `"Mapping memory failed: %s (%d) (pPhysAddr=0x%lx, nMemSize=%u)"` at disasm
  `0x30c10`-`0x30d33` (rodata `0xe54e`, `/dev/mem` rodata `0x11982`); `cpuid`
  vendor/family checks at `0x43a3a`, `0x43a9e`, `0x5e809`; Intel microarch name
  table around `0x43ba7`-`0x43e9e` with default `"Unknown Intel CPU model: 0x%02X"`
  (rodata `0xdd61`); arm64 build: DT `compatible` `strstr` of `cx8200`/`cx9240` at
  `0x3da94`/`0x3daa0`, CX9240 branch → `/sys/bus/i2c/devices/3-0050/eeprom`
  (`0x3dac4`, rodata `0xd2a9`), `"Device type not found in the address array"`
  (rodata `0x11d21`, refs `0x6e828`,`0x6e9d0`), `"Unknown ARM CPU part: 0x%03X"`
  (`0x4c9bc`).
- `/usr/bin/TcSysConf`: MSR probes `/dev/cpu/0/msr`, `"MSR interface is not
  available…"`, `"Running in a hypervisor environment. Core optimizations not
  applicable."`
- `/usr/lib/libTcOsSys.so`: hypervisor vendor strings (`KVMKVMKVM`, `VMwareVMware`,
  `Microsoft Hyper-V`, `VirtualBox`, `VirtualApple`, `BSD Hypervisor`), CCAT/EEPROM
  strings, `CX9240`.
- `/usr/lib/libTcSystemUm.so`: `CX9240-M910`, `/dev/tcpaldrv`, CCAT registry paths.

Beckhoff InfoSys (primary):
- System requirements (XAR): https://infosys.beckhoff.com/content/1033/tc3_overview/6162419083.html,
 "Beckhoff RT Linux®: Supported from TwinCAT 3.1 Build 4026"; Hyper-V: "The
  real-time runtime environment cannot be started within a Hyper-V environment";
  VT-x exclusivity for shared cores; third-party PC RT caveat.
- Real-Time fundamentals: https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6828869003.html,
 direct hardware access; user-mode RT extension on Beckhoff RT Linux.
- Runtime configuration / XarMode: https://infosys.beckhoff.com/content/1033/tc3_installation/20830884491.html,
 KM/UM/KMWithUM; "Windows on Arm®: Real-time runtime Not possible; User mode
  runtime Default"; UM min cycle 1 ms.
- Usermode Runtime limitations: https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11319889035.html,
 non-deterministic; 1 ms min base time; "no access to EtherCAT"; "CCAT-based
  network cards cannot be used."
- Simulink target platforms: https://infosys.beckhoff.com/content/1033/te1400_tc3_target_simulink/17663521675.html,
 "TwinCAT OS (ARMV8-A) … Currently explicitly for the devices CX82xx and CX9240."
- Container overview: https://infosys.beckhoff.com/content/1033/tf6100_tc3_opcua_server/20600281099.html,
 TwinCAT runtime for Linux + Docker on Beckhoff controllers.
- Repo installer README (local): `Beckhoff-RT-Linux_installer-amd64/Readme.txt`
  ("testing only" licence); German manual `Beckhoff_RT_Linux_de.pdf` §2.2 (ARM install
  images "für CX82x0"/"für CX9240"), §10 (Docker sample), §10.6 (vfio-pci for RT
  Ethernet, "nur auf den neuesten Beckhoff IPCs").

Beckhoff hardware & CCAT:
- CX8290 (Cortex-A53 dual-core 1.2 GHz): https://www.beckhoff.com/en-us/products/ipc/embedded-pcs/cx8200-arm-r-cortex-r-a53/cx8290.html
- CX9240 (Cortex-A53 quad-core 1.2 GHz, 2 GB LPDDR4): https://www.beckhoff.com/en-us/products/ipc/embedded-pcs/cx9240-arm-r-cortex-r-a53/cx9240.html
- CCAT Linux driver (VID 0x15EC / DID 0x5000, function-block enums): https://github.com/Beckhoff/CCAT
- Container sample prerequisites: https://github.com/Beckhoff/TC_XAR_Container_Sample

Virtualization primary sources:
- QEMU accelerators (HVF = macOS host, x86+Arm guests; TCG "purely emulated"):
  https://www.qemu.org/docs/master/system/introduction.html
- QEMU multi-threaded TCG / memory ordering (strong-guest-on-weak-host):
  https://www.qemu.org/docs/master/devel/multi-thread-tcg.html
- QEMU x86 CPU models (`-cpu` named models; `host` requires KVM/HVF):
  https://www.qemu.org/docs/master/system/i386/cpu.html
- MTTCG "Guest expects a stronger memory ordering than the host provides" report:
  https://github.com/beringresearch/macpine/issues/43
- Apple Rosetta for Linux (user-space x86_64 translation in arm64 guest; virtiofs
  share + binfmt): https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms-with-rosetta
- Rosetta Linux CPUID internals (VirtualApple, family 6 model 142 stepping 10,
  hardcoded /proc/cpuinfo): https://blog.inoki.cc/2026/02/28/Apple-Rosetta-Linux-VM-Secret-en/
- Parallels x86 emulator on Apple silicon (preview; slow; UEFI-only; 1 vCPU; no
  USB; no nested virt): https://kb.parallels.com/en/130217
- Parallels 20.2 x86 preview coverage: https://appleinsider.com/articles/25/01/13/parallels-202-trials-x86-vms-on-apple-silicon-bringing-linux-windows-11-support
- UTM x86-on-Apple-Silicon = QEMU/TCG, "Force multicore" for strong-on-weak:
  https://mac.getutm.app/ ; https://docs.getutm.app/

Linux kernel semantics:
- `STRICT_DEVMEM` / `IO_STRICT_DEVMEM` help text and `default y … X86 || ARM64`
  (`lib/Kconfig.debug`), `X86_MSR` (`arch/x86/Kconfig`), `devmem_is_allowed()`
  (`arch/x86/mm/init.c`), fetched from
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git (mainline).

Community (secondary, clearly labelled):
- TwinCAT RT in Proxmox/KVM (host-passthrough needed; config↔run fragility):
  https://forum.proxmox.com/threads/problems-with-twincat-proxmox-and-isolated-cores-on-windows.97493/
- TwinCAT/BSD in a VM (x86 hosts only): https://alltwincat.com/2021/12/13/tc-bsd-in-a-virtual-machine/
- TwinCAT/BSD VirtualBox/ESXi tooling: https://github.com/r9guy/TwinCAT-BSD-VM-creator

Unverified / not directly confirmed:
- Whether the amd64 user-mode runtime *actually starts and registers ADS* inside a
  full-system x86 TCG VM (route 2), not tested here (parent session owns that
  experiment); the analysis shows only that the identity probes *can* be satisfied.
- Exact CCAT function-block register semantics beyond the open driver's enums,
  undocumented; route 6 tractability is therefore an estimate, not a measurement.
- The precise CPUID model byte Docker Desktop's vCPU presents vs. Rosetta's
  (measured `0x2C` in the repo vs. Rosetta's documented model 142); the discrepancy
  is noted but not root-caused, and does not affect the conclusion.

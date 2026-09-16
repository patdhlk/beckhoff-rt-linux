# TwinCAT XAR on Apple Silicon: QEMU recipe

Runbook to rebuild the working setup from a fresh Mac. Why it works, what was
measured, and the limits are in
[../apple-silicon-xar-feasibility.md](../apple-silicon-xar-feasibility.md)
(section "Measured result"). Short version: Beckhoff RT Linux + `tc31-xar-um`
runs in a full-system x86 QEMU VM (software emulation, no HVF), XAE in a
Parallels Windows VM attaches over ADS, PLC projects activate and enter RUN.
Unsupported by Beckhoff; simulation/TcUnit only; use 10 ms tasks.

## 1. Host prerequisites

```bash
brew install qemu sshpass          # qemu 11.x; sshpass is only for vmssh.sh
```

Download `Beckhoff-RT-Linux-<build>-installer-amd64.img` from the Beckhoff
download area (myBeckhoff login). Not in git: the repo `.gitignore` excludes
`Beckhoff-RT-Linux_installer-*/`.

## 2. Install the guest (one time, about 10 minutes)

```bash
./install-vm.sh /path/to/Beckhoff-RT-Linux-306707-installer-amd64.img   # VM dir: ~/VMs/beckhoff-rt-linux-qemu
```

The VM shows its console on VNC display `:5` (`open vnc://127.0.0.1:5905`),
or drive it headless from the VM dir with `vm.py`:

```bash
python3 vm.py shot s1        # screenshot -> s1.png
python3 vm.py keys ret       # Enter
python3 vm.py type 1         # type text
python3 vm.py mon quit       # stop QEMU
```

Installer sequence: "Beckhoff RT Linux Install" → OK, disk `sdb` (the 16 GB
`target.qcow2`) → OK, "all data lost" → Yes, Administrator password twice,
LUKS → No, wait ~5 min, OK, then Reboot → `python3 vm.py mon quit`.

Copy `start-vm.sh`, `vm.py`, `vmssh.sh` into the VM dir if you installed
somewhere else. `vmssh.sh` assumes password `1`; edit it otherwise.

## 3. Boot and install the runtime

```bash
cd ~/VMs/beckhoff-rt-linux-qemu && ./start-vm.sh &     # ~1 min to SSH
./vmssh.sh 'uname -a'                                    # 6.19.x-rt PREEMPT_RT
```

Inside the guest (`ssh -p 2222 Administrator@127.0.0.1`):

```bash
sudo install -m 600 /dev/stdin /etc/apt/auth.conf.d/bhf.conf <<'EOF'
machine deb.beckhoff.com
login <myBeckhoff e-mail>
password <myBeckhoff password>

machine deb-mirror.beckhoff.com
login <myBeckhoff e-mail>
password <myBeckhoff password>
EOF
sudo apt update
sudo apt install -y --no-install-recommends adstool bhfinfo libadscomm tc31-orderno tc31-xar-um tcsysconf
sudo journalctl -u TcSystemServiceUm | grep "start completed"     # AdsState: >15<
```

## 4. Routing to XAE (Parallels Windows VM)

Guest side. The guest NetId derives from the virtual MAC: `0.18.52.86.1.1`.
Windows reaches the guest through the Mac, so its traffic arrives from the
QEMU gateway `10.0.2.2`:

```bash
sudo install -m 644 StaticRoutes.xml /etc/TwinCAT/3.1/Target/StaticRoutes.xml   # edit NetId to the XAE router's (<windows-ip>.1.1)
sudo install -m 644 10-ads.conf /etc/nftables.conf.d/10-ads.conf                 # opens plain ADS 48898 (default: only Secure ADS 8016)
sudo systemctl reload nftables && sudo systemctl restart TcSystemServiceUm
```

Windows side (TwinCAT 4026 XAE). Either add the route in XAE's route dialog
(address = the Mac's Parallels bridge IP, usually `10.211.55.2`, NetId
`0.18.52.86.1.1`), or run `windows/add-route.ps1` as admin, which writes
`C:\ProgramData\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml` and restarts
`TcSysSrv`. From the Mac you can run any of the `windows/*.ps1` scripts with

```bash
prlctl exec "Windows 11" powershell -NoProfile -ExecutionPolicy Bypass -File '\\Mac\Home\<path under your home>\ads-state.ps1'
```

`ads-state.ps1` / `ads-verify.ps1` need the 32-bit PowerShell with
`C:\Program Files (x86)\Beckhoff\TwinCAT\Common32` on `PATH` (see
`add-route.ps1` for the wrapper). Expected: `OK AdsState=Config`.

Do not use `adstool` as the health probe: it returns ADS error 6 against this
runtime even when XAE works.

## 5. Run a PLC

In XAE pick the route, activate a project, restart in RUN. First time on a
fresh guest: System → License → request the 7-day trial (captcha), otherwise
the runtime logs `License 'TC3 PLC' not found` and drops back to CONFIG.
`windows/ai-activate.ps1` is the headless Automation Interface version (run it
in the desktop session via `ai-task.ps1`; it needs the user's session, not
SYSTEM).

## Files

| File | Purpose |
|------|---------|
| `install-vm.sh` | boot the installer image with a blank `target.qcow2` |
| `start-vm.sh` | boot the installed guest; forwards 2222 (ssh), 48898/8016 (ADS), 48899/udp |
| `vm.py` | QEMU monitor helper: screenshots, key presses, monitor commands |
| `vmssh.sh` | password SSH wrapper into the guest |
| `StaticRoutes.xml` | guest route file template (XAE router NetId via `10.0.2.2`) |
| `10-ads.conf` | nftables drop-in that admits plain ADS on 48898 |
| `windows/add-route.ps1` | write the Windows static route, restart the router, read state |
| `windows/ads-state.ps1`, `ads-verify.ps1` | .NET ADS probes (state, `MAIN.nCounter`, task cycle info) |
| `windows/ai-activate.ps1`, `ai-task.ps1` | XAE Automation Interface: create, activate and start a test PLC |

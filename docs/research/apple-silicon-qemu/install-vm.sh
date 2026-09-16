#!/bin/sh
# One-time: boot the Beckhoff RT Linux installer image in QEMU TCG and install onto target.qcow2.
# Usage: ./install-vm.sh <path-to-Beckhoff-RT-Linux-*-installer-amd64.img> [vm-dir]
# Drive the TUI over VNC (:5) or with `python3 vm.py keys ...` / `python3 vm.py shot name` (see vm.py).
# Sequence used on 2026-09-16: OK -> disk sdb -> Yes -> password x2 -> LUKS: No -> ~5 min -> OK -> Reboot,
# then `python3 vm.py mon quit` and boot with start-vm.sh (no installer attached).
set -eu
IMG="$1"; DIR="${2:-$HOME/VMs/beckhoff-rt-linux-qemu}"
mkdir -p "$DIR"; cd "$DIR"
cp "$IMG" installer.img                      # the installer rewrites its own partition table
cp /opt/homebrew/share/qemu/edk2-i386-vars.fd vars.fd
qemu-img create -f qcow2 target.qcow2 16G
rm -f mon.sock
exec qemu-system-x86_64 \
  -machine q35,kernel-irqchip=split -accel tcg,thread=single -cpu Skylake-Client-v4 -smp 2 -m 4096 \
  -device intel-iommu,intremap=on \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=installer.img,format=raw,if=none,id=inst -device ide-hd,drive=inst,bus=ide.0 \
  -drive file=target.qcow2,format=qcow2,if=none,id=tgt -device ide-hd,drive=tgt,bus=ide.1 \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device e1000e,netdev=n0 \
  -smbios type=1,manufacturer=Beckhoff,product=C6015,version=1.0 \
  -display vnc=:5 -monitor unix:mon.sock,server,nowait -serial file:serial.log

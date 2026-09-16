#!/bin/sh
# Boot the installed Beckhoff RT Linux + TwinCAT XAR (tc31-xar-um) in QEMU TCG on Apple Silicon.
# Ports on the Mac: 2222 -> ssh (Administrator / 1), 48898+8016 tcp + 48899 udp -> ADS.
# Stop with:  python3 vm.py mon quit   (or ssh in and `sudo systemctl poweroff`).
cd "$(dirname "$0")"
rm -f mon.sock
exec qemu-system-x86_64 \
  -machine q35,kernel-irqchip=split -accel tcg,thread=single -cpu "${CPU:-Skylake-Client-v4}" -smp "${SMP:-2}" -m "${MEM:-4096}" \
  -device intel-iommu,intremap=on \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=target.qcow2,format=qcow2,if=none,id=tgt -device ide-hd,drive=tgt,bus=ide.1 \
  -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::48898-:48898,hostfwd=tcp::8016-:8016,hostfwd=udp::48899-:48899 -device e1000e,netdev=n0 \
  -smbios type=1,manufacturer=Beckhoff,product=C6015,version=1.0 \
  -display vnc=:5 -monitor unix:mon.sock,server,nowait -serial file:serial.log

#!/usr/bin/env python3
# Tiny QEMU monitor helper: vm.py mon "<cmd>" | vm.py shot name | vm.py keys k1 k2 ... | vm.py type "text"
import socket, sys, time, subprocess, os
os.chdir(os.path.dirname(os.path.abspath(__file__))); SOCK = "mon.sock"
def mon(cmd, wait=0.3):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK); s.settimeout(2)
    try: s.recv(4096)
    except Exception: pass
    s.sendall((cmd + "\n").encode()); time.sleep(wait)
    out = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk: break
            out += chunk
            if len(chunk) < 65536: break
    except Exception: pass
    s.close(); return out.decode(errors="replace")
KEYMAP = {' ':'spc','.':'dot','-':'minus','_':'shift-minus','/':'slash',',':'comma','=':'equal',':':'shift-semicolon',';':'semicolon',
          '@':'shift-2','!':'shift-1','#':'shift-3','$':'shift-4','%':'shift-5','&':'shift-7','*':'shift-8','(':'shift-9',')':'shift-0',
          '+':'shift-equal','?':'shift-slash','"':'shift-apostrophe',"'":'apostrophe','\n':'ret','\t':'tab','~':'shift-grave_accent','|':'shift-backslash','\\':'backslash','<':'shift-comma','>':'shift-dot','[':'bracket_left',']':'bracket_right','{':'shift-bracket_left','}':'shift-bracket_right','`':'grave_accent','^':'shift-6'}
def type_text(t):
    for ch in t:
        if ch in KEYMAP: k = KEYMAP[ch]
        elif ch.isupper(): k = "shift-" + ch.lower()
        else: k = ch
        mon("sendkey " + k, 0.08)
if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "mon": print(mon(" ".join(a[1:]), 1.0))
    elif a[0] == "shot":
        ppm = os.path.abspath(a[1] + ".ppm"); mon("screendump " + ppm, 1.5)
        subprocess.run(["sips","-s","format","png",ppm,"--out",a[1]+".png"],capture_output=True); os.remove(ppm); print(a[1]+".png")
    elif a[0] == "keys":
        for k in a[1:]: mon("sendkey " + k, 0.15)
    elif a[0] == "type": type_text(" ".join(a[1:]))

#!/bin/zsh
# Protocol test: runs the app's VNC code against a mock macOS Screen Sharing
# server (Apple DH auth + every encoding) and compares the framebuffer pixel by pixel.
set -e
cd "$(dirname "$0")"
V=../../ScreenLink/VNC
T=$(mktemp -d)
xcrun swiftc -O -o $T/harness main.swift $V/Socket.swift $V/Auth.swift $V/ZStream.swift $V/Framebuffer.swift $V/Decoders.swift $V/RFBConnection.swift $V/Keysyms.swift ../../ScreenLink/Models/ConnLog.swift 2>/dev/null
python3 server.py $T/port $T/expected.bin > $T/server.log 2>&1 &
while [ ! -f $T/port ]; do sleep 0.1; done
$T/harness $(cat $T/port) $T/actual.bin 41
sleep 1.5; cat $T/server.log
python3 - $T <<'PY'
import sys,struct
d=sys.argv[1]; a=open(d+"/actual.bin","rb").read(); e=open(d+"/expected.bin","rb").read()
bad=sum(1 for i in range(8,len(e),4) if a[i:i+3]!=e[i:i+3])
print("mismatched pixels:",bad); sys.exit(1 if bad else 0)
PY

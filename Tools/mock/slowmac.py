# Mock Mac that behaves like a busy screensharingd: it streams large screen
# updates continuously and is slow to process client input. Its writes block
# if the client stops reading (like the real server), so a client that stalls
# freezes it. Prints frames-sent per second; a freeze shows as 0s.
import socket, struct, zlib, threading, time, sys, os
W,H=1920,1080
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(("127.0.0.1",0)); srv.listen(1)
open(sys.argv[1],"w").write(str(srv.getsockname()[1]))
s,_=srv.accept()
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 64*1024)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024)
def rd(n):
    b=b""
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c: raise SystemExit
        b+=c
    return b
s.sendall(b"RFB 003.889\n"); rd(12); s.sendall(bytes([1,1])); rd(1); s.sendall(struct.pack(">I",0)); rd(1)
s.sendall(struct.pack(">HH",W,H)+bytes(16)+struct.pack(">I",4)+b"Slow")
import queue
requests=queue.Queue(); stats={"frames":0,"inputs":0}
def reader():
    while True:
        t=rd(1)[0]
        if t==0: rd(19)
        elif t==2: n=struct.unpack(">H",rd(3)[1:])[0]; rd(4*n)
        elif t==3:
            m=rd(9); inc=m[0]; x,y,w,h=struct.unpack(">HHHH",m[1:])
            requests.put(("ping",x,y) if (not inc and w==1 and h==1) else ("frame",))
        elif t==4: rd(7); stats["inputs"]+=1; time.sleep(0.002)
        elif t==5: rd(5); stats["inputs"]+=1; time.sleep(0.002)   # slow input injection
        elif t==6: l=struct.unpack(">I",rd(7)[3:])[0]; rd(l)
threading.Thread(target=reader,daemon=True).start()
def frame(i):
    raw=os.urandom(W*200*4)          # incompressible: big update
    return struct.pack(">BBH",0,0,1)+struct.pack(">HHHHi",0,(i*200)%(H-200),W,200,0)+raw
def ticker():
    last=(0,0)
    while True:
        time.sleep(1); f,n=stats["frames"],stats["inputs"]
        print(f"frames/s={f-last[0]} inputs/s={n-last[1]}",flush=True); last=(f,n)
threading.Thread(target=ticker,daemon=True).start()
i=0
while True:
    r=requests.get()
    if r[0]=="ping":
        s.sendall(struct.pack(">BBH",0,0,1)+struct.pack(">HHHHi",r[1],r[2],1,1,0)+bytes(4)); continue
    s.sendall(frame(i)); i+=1; stats["frames"]+=1

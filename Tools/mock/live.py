# Live mock desktop: 2560x1440, no auth. Draws a marker where the pointer is.
import socket, struct, zlib, threading, math, sys
REALMAC = "--realmac" in sys.argv   # dual + macOS's real habit: one rect per display, filler never sent
DUAL = "--dual" in sys.argv or REALMAC
MACLIKE = "--maclike" in sys.argv or REALMAC
# Single: one 2560x1440 display. Dual: adds a 1920x1080 display to the right,
# vertically centred, with black filler above/below (as macOS does).
W,H=(2560+1920,1440) if DUAL else (2560,1440)
fb=bytearray(W*H*4)
for y in range(H):
    for x in range(0,2560):
        r=int(30+40*y/H); g=int(60+80*x/2560); b=int(140+100*y/H)
        if (x//160+y//160)%2==0: r+=15;g+=15;b+=15
        i=(y*W+x)*4; fb[i]=b; fb[i+1]=g; fb[i+2]=r
if DUAL:
    for y in range(180,180+1080):
        for x in range(2560,W):
            r=int(150+80*(x-2560)/1920); g=int(60+40*(y-180)/1080); b=110
            i=(y*W+x)*4; fb[i]=b; fb[i+1]=g; fb[i+2]=r
# menu bar + windows
def rect(x,y,w,h,c):
    row=bytes([c[2],c[1],c[0],0])*w
    for yy in range(y,y+h): fb[(yy*W+x)*4:(yy*W+x+w)*4]=row
rect(0,0,2560,48,(235,235,240)); rect(300,200,1200,800,(250,250,252)); rect(300,200,1200,56,(220,220,226))
for i,c in enumerate([(255,95,87),(255,189,46),(40,200,64)]): rect(330+i*44,220,24,24,c)
for k in range(14): rect(360,320+k*48,900-(k*37)%400,22,(70,70,80))
rect(1650,400,700,600,(30,30,36)); rect(1650,400,700,56,(50,50,58))
for k in range(9): rect(1690,500+k*50,300+(k*71)%300,20,(90,220,120))
rect(800,1330,960,90,(240,240,245))
# a text field (pointer shows the I-beam over it)
TF=(360,266,700,40); rect(*TF,(200,200,210)); rect(TF[0]+2,TF[1]+2,TF[2]-4,TF[3]-4,(255,255,255))
if DUAL:
    rect(2560,180,1920,40,(230,230,236))
    rect(2800,400,1300,700,(252,252,252)); rect(2800,400,1300,50,(215,215,222))
    for k in range(10): rect(2850,500+k*55,1100-(k*83)%500,24,(200,60,60))
for k in range(10): rect(830+k*92,1342,66,66,[(255,80,80),(80,160,255),(255,200,0),(120,220,120),(180,120,255)][k%5])
lock=threading.Lock()
def serve(s):
    def rd(n):
        b=b""
        while len(b)<n:
            c=s.recv(n-len(b))
            if not c: raise EOFError
            b+=c
        return b
    s.sendall(b"RFB 003.889\n"); rd(12)
    s.sendall(bytes([1,1])); rd(1); s.sendall(struct.pack(">I",0)); rd(1)
    name=b"Mock Mac Studio (2 displays)" if DUAL else b"Mock Mac Studio"
    s.sendall(struct.pack(">HH",W,H)+bytes(16)+struct.pack(">I",len(name))+name)
    zc=zlib.compressobj(1)
    def send_rect(x,y,w,h):
        data=bytearray()
        for ty in range(y,y+h,64):
            for tx in range(x,x+w,64):
                tw=min(64,x+w-tx); th=min(64,y+h-ty)
                data.append(0)
                for yy in range(ty,ty+th):
                    row=fb[(yy*W+tx)*4:(yy*W+tx+tw)*4]
                    data+=bytes(b for i in range(0,len(row),4) for b in row[i:i+3])
        z=zc.compress(bytes(data))+zc.flush(zlib.Z_SYNC_FLUSH)
        return struct.pack(">HHHHi",x,y,w,h,16)+struct.pack(">I",len(z))+z
    # cursor shape: 16x16 arrow-ish triangle
    cw,ch=16,24; cur=b""; mask=b""
    for yy in range(ch):
        m=0
        for xx in range(cw):
            inside = xx<=yy*0.6 and yy<20
            edge = inside and (xx==0 or xx>=int(yy*0.6) or yy==19)
            cur+= bytes([255,255,255,0]) if edge else bytes([0,0,0,0])
            if inside: m|=1<<(15-xx)
        mask+=struct.pack(">H",m)
    arrow=struct.pack(">HHHHi",0,0,cw,ch,-239)+cur+mask
    # I-beam: 9x18, serifs on rows 0-1 and 16-17, stem on columns 3-5, hotspot (4,9)
    iw,ih=9,18; icur=b""; imask=b""
    for yy in range(ih):
        m=0
        for xx in range(iw):
            on = (yy<2 or yy>=ih-2) or 3<=xx<=5
            icur+= bytes([0,0,0,0]) if (on and (xx==4 or yy in (0,ih-1))) else bytes([255,255,255,0])
            if on: m|=1<<(15-xx)
        imask+=struct.pack(">H",m)
    ibeam=struct.pack(">HHHHi",4,9,iw,ih,-239)+icur+imask
    shape=["arrow"]
    pending=[True]
    first=[True]
    turn=[0]
    moves=[0,__import__("time").time()]
    while True:
        t=rd(1)[0]
        if t==0: rd(19)
        elif t==2: n=struct.unpack(">H",rd(3)[1:])[0]; rd(4*n)
        elif t==3:
            m=rd(9)
            inc=m[0]; rx,ry,rw,rh=struct.unpack(">HHHH",m[1:])
            if REALMAC and not (rw==1 and rh==1): print("req", "inc" if inc else "full", rx,ry,rw,rh, flush=True)
            if not first[0] and not inc and rw==1 and rh==1:
                # Answer flow-control pings immediately, like the real server; the real Mac
                # never answers for filler that isn't on any display.
                on_display = not REALMAC or any(dx<=rx<dx+dw and dy<=ry<dy+dh for dx,dy,dw,dh in [(0,0,2560,1440),(2560,180,1920,1080)])
                if on_display: s.sendall(struct.pack(">BBH",0,0,1)+send_rect(rx,ry,1,1))
                else: print("ping in filler ignored",rx,ry,flush=True)
            if first[0]:
                first[0]=False
                if MACLIKE:
                    # Like macOS: the first reply can carry only the cursor, no pixels.
                    s.sendall(struct.pack(">BBH",0,0,1)+arrow)
                else:
                    rects=[send_rect(0,0,W,H), arrow]
                    s.sendall(struct.pack(">BBH",0,0,len(rects))+b"".join(rects))
            elif MACLIKE and not inc and rw*rh>1:
                print("full frame requested",flush=True)
                if REALMAC:   # alternate displays, as the real Mac Studio log shows
                    d=[(0,0,2560,1440),(2560,180,1920,1080)][turn[0]%2]; turn[0]+=1
                    s.sendall(struct.pack(">BBH",0,0,1)+send_rect(*d))
                else:
                    s.sendall(struct.pack(">BBH",0,0,1)+send_rect(0,0,W,H))
        elif t==4: m=rd(7); print("key",m[0],hex(struct.unpack(">I",m[3:])[0]),flush=True)
        elif t==5:
            m=rd(5); btn=m[0]; x,y=struct.unpack(">HH",m[1:])
            moves[0]+=1
            import time as _t
            if _t.time()-moves[1]>=2: print("moves/s",round(moves[0]/(_t.time()-moves[1]),1),flush=True); moves[0]=0; moves[1]=_t.time()
            want="ibeam" if TF[0]<=x<TF[0]+TF[2] and TF[1]<=y<TF[1]+TF[3] else "arrow"
            if want!=shape[0]:
                shape[0]=want; print("cursor",want,flush=True)
                s.sendall(struct.pack(">BBH",0,0,1)+(ibeam if want=="ibeam" else arrow))
            if btn: 
                print("ptr",btn,x,y,flush=True)
                rx,ry=max(0,min(W-24,x-12)),max(0,min(H-24,y-12))
                rect(rx,ry,24,24,(255,60,60) if btn&1 else (60,60,255))
                s.sendall(struct.pack(">BBH",0,0,1)+send_rect(rx,ry,24,24))
        elif t==6: l=struct.unpack(">I",rd(7)[3:])[0]; print("cut",rd(l),flush=True)
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); srv.bind(("127.0.0.1",5995 if REALMAC else 5996 if MACLIKE else 5998 if DUAL else 5999)); srv.listen(4)
print("listening",flush=True)
while True:
    c,_=srv.accept()
    threading.Thread(target=lambda: (lambda s: (serve(s) if True else None))(c), daemon=True).start()

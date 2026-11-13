import socket, struct, random, zlib, hashlib, subprocess, sys, os
random.seed(7)
P = int("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF",16)
USER, PASS = b"tester", b"s3cret pw!"

W, H = 200, 150
def mkimg(w, h):
    img = [[(0,0,0)]*w for _ in range(h)]
    for by in range(0, h, 16):
        for bx in range(0, w, 16):
            kind = random.choice(["solid","two","five","noise"])
            pal = [(random.randrange(256),random.randrange(256),random.randrange(256)) for _ in range(5)]
            for y in range(by, min(h,by+16)):
                for x in range(bx, min(w,bx+16)):
                    if kind=="solid": c=pal[0]
                    elif kind=="two": c=pal[(x+y)%2]
                    elif kind=="five": c=pal[(x*3+y)%5]
                    else: c=(random.randrange(256),random.randrange(256),random.randrange(256))
                    img[y][x]=c
    return img

model = [[(32,32,32)]*W for _ in range(H)]
def region(img,x,y,w,h): return [img[yy][x:x+w] for yy in range(y,y+h)]
def put(rows,x,y):
    for i,r in enumerate(rows): model[y+i][x:x+len(r)] = r

def px(c): return bytes([c[2],c[1],c[0],0])      # BGRX
def cpx(c): return bytes([c[2],c[1],c[0]])       # ZRLE CPIXEL
def tpx(c): return bytes([c[0],c[1],c[2]])       # Tight TPIXEL
def hdr(x,y,w,h,enc): return struct.pack(">HHHHi",x,y,w,h,enc)

def enc_raw(rows): return b"".join(px(c) for r in rows for c in r)

def enc_rre(rows):
    bg = rows[0][0]; subs=[]
    for y,r in enumerate(rows):
        for x,c in enumerate(r):
            if c!=bg: subs.append(px(c)+struct.pack(">HHHH",x,y,1,1))
    return struct.pack(">I",len(subs))+px(bg)+b"".join(subs)

def enc_hextile(rows):
    h=len(rows); w=len(rows[0]); out=b""
    for ty in range(0,h,16):
        for tx in range(0,w,16):
            t=[r[tx:tx+16] for r in rows[ty:ty+16]]
            cols=set(c for r in t for c in r)
            mode=random.choice(["raw","sub"]) if len(cols)>2 else ("mono" if len(cols)==2 else "solid")
            if mode=="raw": out+=bytes([1])+enc_raw(t)
            elif mode=="solid": out+=bytes([2])+px(t[0][0])
            elif mode=="mono":
                bg=t[0][0]; fg=[c for c in cols if c!=bg][0]
                subs=[bytes([(x<<4)|y,0]) for y,r in enumerate(t) for x,c in enumerate(r) if c==fg]
                if len(subs)>255: out+=bytes([1])+enc_raw(t); continue
                out+=bytes([2|4|8])+px(bg)+px(fg)+bytes([len(subs)])+b"".join(subs)
            else:
                bg=t[0][0]
                subs=[px(c)+bytes([(x<<4)|y,0]) for y,r in enumerate(t) for x,c in enumerate(r) if c!=bg]
                if len(subs)>255: out+=bytes([1])+enc_raw(t); continue
                out+=bytes([2|8|16])+px(bg)+bytes([len(subs)])+b"".join(subs)
    return out

zrle_c = zlib.compressobj()
def runlen(n):
    n-=1; b=b""
    while n>=255: b+=bytes([255]); n-=255
    return b+bytes([n])
def enc_zrle(rows):
    h=len(rows); w=len(rows[0]); out=b""
    for ty in range(0,h,64):
        for tx in range(0,w,64):
            t=[c for r in rows[ty:ty+64] for c in r[tx:tx+64]]
            tw=min(64,w-tx)
            pal=list(dict.fromkeys(t))
            if len(pal)==1: out+=bytes([1])+cpx(pal[0]); continue
            choices=["raw","rle"]
            if len(pal)<=16: choices.append("packed")
            if len(pal)<=127: choices.append("prle")
            m=random.choice(choices)
            if m=="raw": out+=bytes([0])+b"".join(cpx(c) for c in t)
            elif m=="packed":
                bits=1 if len(pal)==2 else (2 if len(pal)<=4 else 4)
                out+=bytes([len(pal)])+b"".join(cpx(c) for c in pal)
                for r in range(len(t)//tw):
                    row=t[r*tw:(r+1)*tw]; acc=0; n=0; bs=b""
                    for c in row:
                        acc=(acc<<bits)|pal.index(c); n+=bits
                        if n==8: bs+=bytes([acc]); acc=0; n=0
                    if n: bs+=bytes([acc<<(8-n)])
                    out+=bs
            else:
                runs=[]; i=0
                while i<len(t):
                    j=i
                    while j<len(t) and t[j]==t[i]: j+=1
                    runs.append((t[i],j-i)); i=j
                if m=="rle":
                    out+=bytes([128])+b"".join(cpx(c)+runlen(n) for c,n in runs)
                else:
                    out+=bytes([128+len(pal)])+b"".join(cpx(c) for c in pal)
                    for c,n in runs:
                        out+= bytes([pal.index(c)]) if n==1 else bytes([pal.index(c)|128])+runlen(n)
    data=zrle_c.compress(out)+zrle_c.flush(zlib.Z_SYNC_FLUSH)
    return struct.pack(">I",len(data))+data

zlib_c = zlib.compressobj()
def enc_zlib(rows):
    data=zlib_c.compress(enc_raw(rows))+zlib_c.flush(zlib.Z_SYNC_FLUSH)
    return struct.pack(">I",len(data))+data

tight_c=[zlib.compressobj() for _ in range(4)]
def compact(n):
    b=bytes([n&0x7f | (0x80 if n>0x7f else 0)])
    if n>0x7f:
        b+=bytes([(n>>7)&0x7f | (0x80 if n>0x3fff else 0)])
        if n>0x3fff: b+=bytes([(n>>14)&0xff])
    return b
def tight_data(sid, raw):
    if len(raw)<12: return raw
    d=tight_c[sid].compress(raw)+tight_c[sid].flush(zlib.Z_SYNC_FLUSH)
    return compact(len(d))+d
def enc_tight(rows, mode):
    h=len(rows); w=len(rows[0]); flat=[c for r in rows for c in r]
    pal=list(dict.fromkeys(flat))
    if mode=="fill" or len(pal)==1: return bytes([0x80])+tpx(flat[0])
    sid=random.randrange(4)
    if mode=="palette" and len(pal)<=256:
        ctl=bytes([(sid|4)<<4, 1, len(pal)-1])+b"".join(tpx(c) for c in pal)
        if len(pal)==2:
            raw=b""
            for r in rows:
                acc=0;n=0
                for c in r:
                    acc=(acc<<1)|pal.index(c); n+=1
                    if n==8: raw+=bytes([acc]); acc=0;n=0
                if n: raw+=bytes([acc<<(8-n)])
        else: raw=bytes(pal.index(c) for c in flat)
        return ctl+tight_data(sid,raw)
    if mode=="gradient":
        out=bytearray()
        for y in range(h):
            for x in range(w):
                for ch in range(3):
                    left=rows[y][x-1][ch] if x>0 else 0
                    up=rows[y-1][x][ch] if y>0 else 0
                    ul=rows[y-1][x-1][ch] if x>0 and y>0 else 0
                    est=min(255,max(0,left+up-ul))
                    out.append((rows[y][x][ch]-est)&0xff)
        return bytes([(sid|4)<<4, 2])+tight_data(sid,bytes(out))
    return bytes([sid<<4])+tight_data(sid,b"".join(tpx(c) for c in flat))

def run(port_file, expected_file):
    srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
    srv.bind(("127.0.0.1",0)); srv.listen(1)
    open(port_file,"w").write(str(srv.getsockname()[1]))
    s,_=srv.accept()
    def rd(n):
        b=b""
        while len(b)<n:
            c=s.recv(n-len(b))
            if not c: raise SystemExit("client closed")
            b+=c
        return b
    s.sendall(b"RFB 003.889\n"); assert rd(12)==b"RFB 003.008\n"
    s.sendall(bytes([3,30,2,35]))
    assert rd(1)==bytes([30]), "client did not pick type 30"
    priv=random.getrandbits(512); pub=pow(2,priv,P)
    s.sendall(struct.pack(">HH",2,128)+P.to_bytes(128,"big")+pub.to_bytes(128,"big"))
    resp=rd(256); enc,cpub=resp[:128],int.from_bytes(resp[128:],"big")
    key=hashlib.md5(pow(cpub,priv,P).to_bytes(128,"big")).hexdigest()
    dec=subprocess.run(["openssl","enc","-d","-aes-128-ecb","-nopad","-K",key],input=enc,capture_output=True).stdout
    u=dec[:64].split(b"\0")[0]; p=dec[64:].split(b"\0")[0]
    print("server decrypted creds:",u,p)
    if (u,p)!=(USER,PASS): s.sendall(struct.pack(">I",1)); raise SystemExit("AUTH MISMATCH")
    s.sendall(struct.pack(">I",0))
    assert rd(1)==b"\x01"
    s.sendall(struct.pack(">HH",W,H)+bytes(16)+struct.pack(">I",8)+b"MockMac!")
    m=rd(20); assert m[0]==0 and m[4]==32 and m[5]==24, m
    m=rd(4); n=struct.unpack(">H",m[2:])[0]; encs=struct.unpack(">%di"%n,rd(4*n)); print("client encodings:",encs)
    assert rd(10)[0]==3

    updates=0
    def send(rects):
        nonlocal updates
        s.sendall(struct.pack(">BBH",0,0,len(rects))+b"".join(rects)); updates+=1

    A=mkimg(W,H); put(region(A,0,0,W,H),0,0)
    send([hdr(0,0,W,H,0)+enc_raw(region(A,0,0,W,H))])
    for it in range(40):
        B=mkimg(W,H)
        rects=[]
        for _ in range(random.randint(1,4)):
            w=random.randint(1,120); h=random.randint(1,90); x=random.randrange(W-w+1); y=random.randrange(H-h+1)
            kind=random.choice(["raw","rre","hextile","zrle","zrle","zlib","copy","tight-basic","tight-palette","tight-gradient","tight-fill"])
            r=region(B,x,y,w,h)
            if kind=="raw": rects.append(hdr(x,y,w,h,0)+enc_raw(r))
            elif kind=="rre": rects.append(hdr(x,y,w,h,2)+enc_rre(r))
            elif kind=="hextile": rects.append(hdr(x,y,w,h,5)+enc_hextile(r))
            elif kind=="zrle": rects.append(hdr(x,y,w,h,16)+enc_zrle(r))
            elif kind=="zlib": rects.append(hdr(x,y,w,h,6)+enc_zlib(r))
            elif kind=="copy":
                sx=random.randrange(W-w+1); sy=random.randrange(H-h+1)
                r=region(model,sx,sy,w,h)
                rects.append(hdr(x,y,w,h,1)+struct.pack(">HH",sx,sy))
            elif kind=="tight-fill":
                c=B[y][x]; r=[[c]*w for _ in range(h)]
                rects.append(hdr(x,y,w,h,7)+enc_tight(r,"fill"))
            else:
                mode=kind.split("-")[1]
                if mode=="palette":
                    pal=[B[y][x],B[y+h-1][x+w-1],(1,2,3)][:random.choice([2,3])]
                    r=[[pal[(xx*yy)%len(pal)] for xx in range(w)] for yy in range(h)]
                rects.append(hdr(x,y,w,h,7)+enc_tight(r,mode))
            put(r,x,y)
        if it==5:
            cw,ch=7,5
            cur=[(random.randrange(256),random.randrange(256),random.randrange(256)) for _ in range(cw*ch)]
            mask=bytes([0b10101010]*ch)
            rects.append(hdr(2,3,cw,ch,-239)+b"".join(px(c) for c in cur)+mask)
            print("cursor px0", cur[0], "px5", cur[5])
        send(rects)
    rows=[]
    for r in model:
        rows.append(b"".join(bytes([c[2],c[1],c[0],0]) for c in r))
    open(expected_file,"wb").write(struct.pack("<II",W,H)+b"".join(rows))
    open(port_file+".count","w").write(str(updates))
    # read some client messages to verify input encoding
    import time; time.sleep(1.0)
    s.settimeout(0.5)
    buf=b""
    try:
        while True:
            c=s.recv(65536)
            if not c: break
            buf+=c
    except Exception: pass
    i=0; seen=set()
    while i<len(buf):
        t=buf[i]
        if t==3: i+=10
        elif t==5: seen.add(("ptr",buf[i+1],struct.unpack(">HH",buf[i+2:i+6]))); i+=6
        elif t==4: seen.add(("key",buf[i+1],hex(struct.unpack(">I",buf[i+4:i+8])[0]))); i+=8
        elif t==6: l=struct.unpack(">I",buf[i+4:i+8])[0]; seen.add(("cut",buf[i+8:i+8+l])); i+=8+l
        else: print("unknown client msg",t); break
    print("client input seen:",seen)

run(sys.argv[1], sys.argv[2])

import os
DATA_DIR = os.environ.get('SLEEP_DATA', 'sleep-export')  # raw files + Huawei screenshots (never commit them)
import struct,datetime as dt
TZ=dt.timezone(dt.timedelta(hours=8))
def decode_ppg(d):
    t=struct.unpack('<I',d[:4])[0]; n=d[4]; i=5
    def series(i):
        tag=d[i];i+=1;out=[]
        if tag==0xaa:
            for _ in range(n): out.append(struct.unpack('<h',d[i:i+2])[0]);i+=2
        elif tag==0xbb:
            w=struct.unpack('<h',d[i:i+2])[0];i+=2;out.append(w)
            for _ in range(n-1):
                c=d[i];i+=1
                if c==0xff: w=struct.unpack('<h',d[i:i+2])[0];i+=2
                else: w+= c-256 if c>127 else c
                out.append(w)
        else: raise ValueError(hex(tag))
        return out,i
    peak,i=series(i); amp,i=series(i)
    return t,peak,amp
def parse(path):
    b=open(path,'rb').read();i=0;acc=[];ppg=[]
    while i<len(b):
        c=b[i];i+=1
        if c==1:
            L=b[i];i+=1;d=b[i:i+L];i+=L
            acc.append((struct.unpack('<I',d[:4])[0],list(d[4:])))
        elif c==2:
            L=struct.unpack('<H',b[i:i+2])[0];i+=2;d=b[i:i+L];i+=L
            try: ppg.append(decode_ppg(d))
            except Exception as e: pass
    return acc,ppg
if __name__=='__main__':
    acc,ppg=parse(DATA_DIR+'/sleep_data_2026-10-29T205000.bin')
    for a in acc[:5]+acc[200:205]: print(dt.datetime.fromtimestamp(a[0],TZ).strftime('%H:%M:%S'),a[1])
    print(len(ppg))
    for t,p,a in ppg[:3]+ppg[400:402]: print(dt.datetime.fromtimestamp(t,TZ).strftime('%H:%M:%S'),len(p),p[:8],a[:8])

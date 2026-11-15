import os
DATA_DIR = os.environ.get('SLEEP_DATA', 'sleep-export')  # raw files + Huawei screenshots (never commit them)
from PIL import Image
REF={'deep':(138,43,221),'light':(198,75,228),'rem':(230,140,140),'awake':(253,194,34)}
def cls(c):
    best=None;bd=1e9
    for k,v in REF.items():
        d=sum((a-b)**2 for a,b in zip(c,v))
        if d<bd: bd,best=d,k
    return best if bd<3500 else None
def chart_rows(im):
    # rows that contain hypnogram colours (the chart band), found automatically
    W,H=im.size; small=im.resize((W//4,H//4)); rows=[]
    for y in range(small.size[1]):
        n=sum(1 for x in range(small.size[0]) if cls(small.getpixel((x,y))))
        if n>=3: rows.append(y*4)
    # largest contiguous band
    best=(0,0);start=prev=None
    for y in rows+[10**9]:
        if prev is None or y-prev>40:
            if start is not None and prev-start>best[1]-best[0]: best=(start,prev)
            start=y
        prev=y
    return best[0]-4,best[1]+8
def digitize(path,y0=None,y1=None):
    im=Image.open(path).convert('RGB');W=im.size[0]
    if y0 is None: y0,y1=chart_rows(im)
    cols=[]
    for x in range(W):
        cnt={}
        for y in range(y0,y1):
            k=cls(im.getpixel((x,y)))
            if k: cnt[k]=cnt.get(k,0)+1
        cols.append(max(cnt,key=cnt.get) if cnt and max(cnt.values())>=12 else None)
    xs=[i for i,c in enumerate(cols) if c]
    a,b=xs[0],xs[-1]
    return cols[a:b+1]
if __name__=='__main__':
    import sys
    for name,f,start,end,ref in [('11/10','c9953d32',(6,33),(14,31),{'deep':171,'light':199,'rem':74}),
                                 ('11/11','494f6f59',(4,37),(10,44),{'deep':79,'light':136,'rem':58}),
                                 ('11/15','c448893b',(4,32),(9,46),{'deep':101,'light':137,'rem':76})]:
        c=digitize(DATA_DIR+'/'+f+'-image.jpg')
        total=(end[0]*60+end[1])-(start[0]*60+start[1])
        n=len(c); share={k:sum(1 for x in c if x==k)/n for k in REF}
        print(name,'cols',n,'total',total,{k:round(v*total) for k,v in share.items()},'ref',ref)

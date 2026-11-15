import os
DATA_DIR = os.environ.get('SLEEP_DATA', 'sleep-export')  # raw files + Huawei screenshots (never commit them)
import numpy as np,datetime as dt
from sleep_an import parse
from digit import digitize
TZ=dt.timezone(dt.timedelta(hours=8))
def ts(y,mo,d,h,mi): return int(dt.datetime(y,mo,d,h,mi,tzinfo=TZ).timestamp())
# night -> (Huawei Health screenshot in DATA_DIR/"Huawei Health", bed time, wake time)
NIGHTS={
 '11/10':('Nov 10.JPG',ts(2026,11,10,6,33),ts(2026,11,10,14,31)),
 '11/11':('Nov 11.JPG',ts(2026,11,11,4,37),ts(2026,11,11,10,44)),
 '11/12':('Nov 12.JPG',ts(2026,11,12,1,36),ts(2026,11,12,10,57)),
 '11/13':('Nov 13.JPG',ts(2026,11,13,7,44),ts(2026,11,13,16,8)),
 '11/15':('Nov 15.JPG',ts(2026,11,15,4,32),ts(2026,11,15,9,46)),
}
LAB={'awake':0,'rem':1,'light':2,'deep':3}
def minute_features(acc,ppg,start,end):
    mins=(end-start)//60
    act=np.full((mins,3),np.nan)
    for t,v in acc:
        m=(t-start)//60
        if 0<=m<mins: act[m]=v[:3]
    beats=[]  # absolute beat times (s)
    for t,peak,amp in ppg:
        p=np.array(peak,float)
        # peaks are offsets in 10 ms; sign may flip in compressed form
        p=np.abs(p-p[0])+abs(p[0]) if len(p) else p
        beats += list(t+np.sort(p)/100.0)
    beats=np.array(sorted(set(beats)))
    ibi=np.diff(beats); bt=beats[1:]
    ok=(ibi>0.33)&(ibi<2.0); ibi=ibi[ok]; bt=bt[ok]
    F=[]
    for m in range(mins):
        a=act[m]
        sel=(bt>=start+m*60)&(bt<start+(m+1)*60)
        x=ibi[sel]
        hr=60/np.mean(x) if len(x)>5 else np.nan
        rmssd=np.sqrt(np.mean(np.diff(x)**2))*1000 if len(x)>5 else np.nan
        sd=np.std(x)*1000 if len(x)>5 else np.nan
        F.append([a[0],a[1],a[2],hr,rmssd,sd,len(x)])
    return np.array(F)
def labels(img,mins):
    c=digitize(os.path.join(DATA_DIR,'Huawei Health',img))
    out=[]
    for m in range(mins):
        k=c[min(len(c)-1,int(m*len(c)/mins))]
        out.append(LAB.get(k,-1))
    return np.array(out)
def raw_records():
    """All sleep_data*.bin under DATA_DIR merged; the watch returns its whole buffer per download,
    so files overlap and records are de-duplicated by timestamp."""
    import glob
    acc={};ppg={}
    for f in sorted(glob.glob(os.path.join(DATA_DIR,'**','sleep_data*.bin'),recursive=True)):
        a,p=parse(f)
        for r in a: acc[r[0]]=r
        for r in p: ppg[r[0]]=r
    return sorted(acc.values()),sorted(ppg.values())
def load():
    acc,ppg=raw_records()
    data={}
    for n,(img,s,e) in NIGHTS.items():
        X=minute_features([r for r in acc if s<=r[0]<e],[r for r in ppg if s-60<=r[0]<e],s,e)
        y=labels(img,len(X))
        data[n]=(X,y)
    return data
if __name__=='__main__':
    d=load()
    for n,(X,y) in d.items():
        print(n,X.shape,'nan hr',np.isnan(X[:,3]).mean().round(2))
        for k,v in LAB.items():
            s=X[y==v]
            if len(s): print(f'  {k:6s} n={len(s):3d} act0={np.nanmean(s[:,0]):6.1f} act1={np.nanmean(s[:,1]):6.1f} act2={np.nanmean(s[:,2]):6.1f} hr={np.nanmean(s[:,3]):5.1f} rmssd={np.nanmean(s[:,4]):6.1f} beats={np.nanmean(s[:,6]):4.1f}')

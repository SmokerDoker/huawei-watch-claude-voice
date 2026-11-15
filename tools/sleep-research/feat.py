import os
DATA_DIR = os.environ.get('SLEEP_DATA', 'sleep-export')  # raw files + Huawei screenshots (never commit them)
import numpy as np,datetime as dt
from sleep_an import parse
from digit import digitize
TZ=dt.timezone(dt.timedelta(hours=8))
def ts(y,mo,d,h,mi): return int(dt.datetime(y,mo,d,h,mi,tzinfo=TZ).timestamp())
NIGHTS={
 '11/10':('sleep_data_2026-10-29T205000.bin','c9953d32',ts(2026,11,10,6,33),ts(2026,11,10,14,31)),
 '11/15':('sleep_data_2026-11-10T033500.bin','c448893b',ts(2026,11,15,4,32),ts(2026,11,15,9,46)),
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
    c=digitize(DATA_DIR+'/'+img+'-image.jpg')
    out=[]
    for m in range(mins):
        k=c[min(len(c)-1,int(m*len(c)/mins))]
        out.append(LAB.get(k,-1))
    return np.array(out)
def load():
    data={}
    for n,(f,img,s,e) in NIGHTS.items():
        acc,ppg=parse(DATA_DIR+'/'+f)
        X=minute_features(acc,ppg,s,e); y=labels(img,len(X))
        data[n]=(X,y)
    return data
if __name__=='__main__':
    d=load()
    for n,(X,y) in d.items():
        print(n,X.shape,'nan hr',np.isnan(X[:,3]).mean().round(2))
        for k,v in LAB.items():
            s=X[y==v]
            if len(s): print(f'  {k:6s} n={len(s):3d} act0={np.nanmean(s[:,0]):6.1f} act1={np.nanmean(s[:,1]):6.1f} act2={np.nanmean(s[:,2]):6.1f} hr={np.nanmean(s[:,3]):5.1f} rmssd={np.nanmean(s[:,4]):6.1f} beats={np.nanmean(s[:,6]):4.1f}')

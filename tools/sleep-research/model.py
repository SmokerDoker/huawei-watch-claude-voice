import numpy as np
from feat import load,LAB
from sklearn.ensemble import RandomForestClassifier
def ctx(X):
    n=len(X); act=np.nan_to_num(X[:,0]+X[:,1],nan=255)
    hr=X[:,3].copy(); hr[np.isnan(hr)]=np.nanmedian(hr)
    rm=X[:,4].copy(); rm[np.isnan(rm)]=np.nanmedian(rm)
    hrn=(hr-np.median(hr))/ (np.std(hr)+1e-6); rmn=(rm-np.median(rm))/(np.std(rm)+1e-6)
    def roll(v,w):
        k=np.ones(2*w+1)/(2*w+1); p=np.pad(v,w,mode='edge'); return np.convolve(p,k,'valid')
    pos=np.arange(n)/n
    F=[act,roll(act,2),roll(act,5),roll(act,10),hrn,roll(hrn,3),roll(hrn,10),rmn,roll(rmn,3),roll(rmn,10),pos,
       np.minimum.accumulate(act[::-1])[::-1]*0+roll((act<20).astype(float),7)]
    return np.column_stack(F)
d=load(); names=list(d)
inv={v:k for k,v in LAB.items()}
for test in names:
    tr=[n for n in names if n!=test]
    Xtr=np.vstack([ctx(d[n][0]) for n in tr]); ytr=np.concatenate([d[n][1] for n in tr])
    m=ytr>=0
    clf=RandomForestClassifier(300,min_samples_leaf=5,random_state=0).fit(Xtr[m],ytr[m])
    X,y=d[test]; p=clf.predict(ctx(X))
    # smooth predictions with 5-min majority
    ps=p.copy()
    for i in range(len(p)):
        w=p[max(0,i-2):i+3]; ps[i]=np.bincount(w,minlength=4).argmax()
    ok=y>=0
    print(test,'acc',round((ps[ok]==y[ok]).mean(),2),
          'pred',{inv[k]:int((ps==k).sum()) for k in range(4)},'huawei',{inv[k]:int((y==k).sum()) for k in range(4)})

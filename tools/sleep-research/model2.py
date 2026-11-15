"""Leave-one-night-out model v2: richer context features, balanced classes, totals error per phase."""
import numpy as np
from feat import load, LAB
from sklearn.ensemble import RandomForestClassifier

def roll(v, w, f=np.mean):
    p = np.pad(v, w, mode='edge')
    return np.array([f(p[i:i + 2 * w + 1]) for i in range(len(v))])

def ctx(X):
    n = len(X)
    act = np.nan_to_num(X[:, 0] + X[:, 1], nan=255.0)
    hr = X[:, 3].copy(); hr[np.isnan(hr)] = np.nanmedian(hr)
    rm = X[:, 4].copy(); rm[np.isnan(rm)] = np.nanmedian(rm)
    hrn = (hr - np.median(hr)) / (np.std(hr) + 1e-6)
    rmn = (rm - np.median(rm)) / (np.std(rm) + 1e-6)
    still = (act < 20).astype(float)
    pos = np.arange(n) / n
    mins = np.arange(n) / 60.0
    F = [act, roll(act, 2), roll(act, 5), roll(act, 10), roll(act, 5, np.max), roll(act, 15),
         hrn, roll(hrn, 3), roll(hrn, 10), roll(hrn, 5, np.std), roll(hrn, 15),
         rmn, roll(rmn, 3), roll(rmn, 10), roll(rmn, 5, np.std),
         roll(still, 7), roll(still, 20), pos, mins,
         np.sin(2 * np.pi * mins / 1.5), np.cos(2 * np.pi * mins / 1.5)]
    return np.column_stack(F)

def smooth(p, w=2):
    out = p.copy()
    for i in range(len(p)):
        out[i] = np.bincount(p[max(0, i - w):i + w + 1], minlength=4).argmax()
    return out

if __name__ == '__main__':
    d = load(); names = list(d)
    inv = {v: k for k, v in LAB.items()}
    errs = []
    for test in names:
        tr = [n for n in names if n != test]
        Xtr = np.vstack([ctx(d[n][0]) for n in tr]); ytr = np.concatenate([d[n][1] for n in tr])
        m = ytr >= 0
        clf = RandomForestClassifier(400, min_samples_leaf=8, class_weight='balanced_subsample',
                                     random_state=0).fit(Xtr[m], ytr[m])
        X, y = d[test]; p = smooth(clf.predict(ctx(X)))
        ok = y >= 0
        pr = {inv[k]: int((p == k).sum()) for k in range(4)}
        hu = {inv[k]: int((y == k).sum()) for k in range(4)}
        err = {k: pr[k] - hu[k] for k in pr}
        errs.append([abs(err[k]) for k in ('deep', 'light', 'rem')])
        print(test, 'acc', round((p[ok] == y[ok]).mean(), 2), 'pred', pr, 'huawei', hu)
    print('mean abs total error min (deep, light, rem):', np.mean(errs, axis=0).round(0))

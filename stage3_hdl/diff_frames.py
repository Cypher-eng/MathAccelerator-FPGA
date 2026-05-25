import sys
def load(fn):
    o=[]
    for l in open(fn):
        p=l.split()
        if len(p)==3:
            try:o.append(tuple(int(v)for v in p))
            except:o.append((0,0,0))
    return o
a=load(sys.argv[1]); b=load(sys.argv[2])
n=min(len(a),len(b)); ms=[i for i in range(n) if a[i]!=b[i]]
print(f"compared {n} pixels, mismatches: {len(ms)}")
if not ms: print("*** BIT-EXACT MATCH ***")
else:
    for i in ms[:5]: print(f"  pixel {i}: A={a[i]} B={b[i]}")

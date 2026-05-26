# Parameterized low-res golden model (hardware-exact). Usage: python3 golden_lowres_gen.py W H
import sys, numpy as np
from PIL import Image
W=int(sys.argv[1]); H=int(sys.argv[2])
MAX_ITER=30; SCALE=4096; TOL=123
DRE=round(4.0*SCALE/(W-1)); DIM=round(3.0*SCALE/(H-1))
ZR0=round(-2.0*SCALE); ZI0=round(-1.5*SCALE)
ROOTS=[(4096,0),(-2048,3547),(-2048,-3547)]; COL=[[230,57,70],[42,157,143],[69,123,157]]
def tdiv(a,b):
    q=abs(a)//abs(b); return -q if (a<0)!=(b<0) else q
def mul(a,b): return tdiv(a*b,SCALE)
img=np.zeros((H,W,3),np.uint8); f=open('golden_lowres.txt','w')
for py in range(H):
  for px in range(W):
    zr=ZR0+px*DRE; zi=ZI0+py*DIM; which=3; it=0
    for it in range(MAX_ITER):
      zr2=mul(zr,zr)-mul(zi,zi); zi2=tdiv(2*zr*zi,SCALE)
      zr3=mul(zr2,zr)-mul(zi2,zi); zi3=mul(zr2,zi)+mul(zi2,zr)
      fr=zr3-SCALE; fi=zi3; fpr=3*zr2; fpi=3*zi2
      denom=mul(fpr,fpr)+mul(fpi,fpi)
      if denom==0: which=3; break
      numr=mul(fr,fpr)+mul(fi,fpi); numi=mul(fi,fpr)-mul(fr,fpi)
      zr-=tdiv(numr*SCALE,denom); zi-=tdiv(numi*SCALE,denom)
      c=-1
      for k,(rr,ri) in enumerate(ROOTS):
        if abs(zr-rr)<TOL and abs(zi-ri)<TOL: c=k; break
      if c>=0: which=c; break
      if it==MAX_ITER-1: which=3
    if which==3: r=g=b=0
    else:
      sh=max(64,256-(it*256)//MAX_ITER)
      r=(COL[which][0]*sh)>>8; g=(COL[which][1]*sh)>>8; b=(COL[which][2]*sh)>>8
    img[py,px]=(r,g,b); f.write(f"{r} {g} {b}\n")
f.close(); Image.fromarray(img).save('golden_lowres.png'); print(f"golden {W}x{H} done")

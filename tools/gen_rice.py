#!/usr/bin/env python3
"""Golomb-Rice 压缩 aether.nnue -> aether.nnue.rice(内嵌产物,自校验)。

布局(LER1):
  u32 magic "1REA"(0x31524541) | u32 ver=1 | u32 arch | u32 qa | u32 qv | u32 n_exc
  u32 n_blk_ftw | u8 k_ftw[n_blk_ftw](每 256 值一块) | u8 k_ftb, k_outw, k_outb
  异常表原样 (u32 idx + i16 val) × n_exc
  u32 len_ftw, len_ftb, len_outw, len_outb(各段字节数,段间字节对齐)
  ft_w 位流(连续,块内同 k)| ft_b | out_w | out_b
值映射 zigzag;Rice(v, k):一元商(0×q 后跟 1)+ k 位余数,MSB 优先。
"""
import struct

SRC, DST = 'src/aether.nnue', 'src/aether.nnue.rice'
MAGIC, VER, BLK = 0x31524541, 1, 256
INPUTS, HIDDEN, BUCKETS = 768, 64, 8

def zz(v): return (v << 1) ^ (v >> 31) if v >= 0 else (-v) * 2 - 1

class BW:
    def __init__(self): self.out = bytearray(); self.acc = 0; self.nb = 0
    def wbit(self, b):
        self.acc = (self.acc << 1) | b; self.nb += 1
        if self.nb == 8: self.out.append(self.acc); self.acc = 0; self.nb = 0
    def rice(self, v, k):
        u = zz(v); q = u >> k
        for _ in range(q): self.wbit(0)
        self.wbit(1)
        for i in range(k - 1, -1, -1): self.wbit((u >> i) & 1)
    def done(self):
        if self.nb: self.out.append((self.acc << (8 - self.nb)) & 0xFF); self.acc = 0; self.nb = 0
        return bytes(self.out)

def bits_of(vals, k): return sum((zz(v) >> k) + 1 + k for v in vals)

d = open(SRC, 'rb').read()
magic, ver, arch, qa, qv, n_exc = struct.unpack_from('<6I', d, 0)
assert magic == 0x4E4E4541 and ver == 4, "源网格式漂移"
ft = INPUTS * HIDDEN
off = 24 + n_exc * 6
ft_w = list(struct.unpack_from(f'<{ft}b', d, off)); off += ft
ft_b = list(struct.unpack_from(f'<{HIDDEN}b', d, off)); off += HIDDEN
out_w = list(struct.unpack_from(f'<{BUCKETS*HIDDEN*2}h', d, off)); off += BUCKETS*HIDDEN*2*2
out_b = list(struct.unpack_from(f'<{BUCKETS}h', d, off)); off += BUCKETS*2
assert off == len(d)

nblk = (ft + BLK - 1) // BLK
ks = []
for b in range(nblk):
    chunk = ft_w[b*BLK:(b+1)*BLK]
    ks.append(min(range(17), key=lambda k: bits_of(chunk, k)))
w = BW()
for b in range(nblk):
    for v in ft_w[b*BLK:(b+1)*BLK]: w.rice(v, ks[b])
s_ftw = w.done()
def enc(vals):
    k = min(range(17), key=lambda k: bits_of(vals, k))
    w2 = BW()
    for v in vals: w2.rice(v, k)
    return k, w2.done()
k_ftb, s_ftb = enc(ft_b)
k_outw, s_outw = enc(out_w)
k_outb, s_outb = enc(out_b)

blob = struct.pack('<6I', MAGIC, VER, arch, qa, qv, n_exc)
blob += struct.pack('<I', nblk) + bytes(ks) + bytes([k_ftb, k_outw, k_outb])
blob += d[24:24+n_exc*6]
blob += struct.pack('<4I', len(s_ftw), len(s_ftb), len(s_outw), len(s_outb))
blob += s_ftw + s_ftb + s_outw + s_outb
open(DST, 'wb').write(blob)
print(f"{len(d)}B -> {len(blob)}B({len(blob)*100//len(d)}%)  ft_w {len(s_ftw)}B(ft_b {len(s_ftb)} / out_w {len(s_outw)} / out_b {len(s_outb)})")

# ---- 独立解码器往返校验 ----
class BR:
    def __init__(self, s): self.s = s; self.p = 0; self.acc = 0; self.nb = 0
    def bit(self):
        if self.nb == 0: self.acc = self.s[self.p]; self.p += 1; self.nb = 8
        self.nb -= 1
        return (self.acc >> self.nb) & 1
    def rice(self, k):
        q = 0
        while self.bit() == 0: q += 1
        r = 0
        for _ in range(k): r = (r << 1) | self.bit()
        u = (q << k) | r
        return (u >> 1) ^ -(u & 1)

h = struct.unpack_from('<6I', blob, 0)
p = 24; nblk2 = struct.unpack_from('<I', blob, p)[0]; p += 4
ks2 = blob[p:p+nblk2]; p += nblk2
k3 = blob[p:p+3]; p += 3
exc = blob[p:p+h[5]*6]; p += h[5]*6
lens = struct.unpack_from('<4I', blob, p); p += 16
r = BR(blob[p:p+lens[0]])
dec = []
for b in range(nblk2):
    for _ in range(min(BLK, ft - b*BLK)): dec.append(r.rice(ks2[b]))
assert dec == ft_w, "ft_w 往返失败"
for (vals, k, ln) in [(ft_b, k3[0], lens[1]), (out_w, k3[1], lens[2]), (out_b, k3[2], lens[3])]:
    r2 = BR(blob[p+lens[0]:])  # placeholder, redone below
# 逐段接续解码
base = p + lens[0]
for si, (vals, k) in enumerate([(ft_b, k3[0]), (out_w, k3[1]), (out_b, k3[2])]):
    r2 = BR(blob[base:base+lens[1+si]])
    got = [r2.rice(k) for _ in vals]
    assert got == vals, f"段{si}往返失败"
    base += lens[1+si]
print("往返校验:全部一致")

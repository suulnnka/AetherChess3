#!/usr/bin/env python3
"""结构化压缩 book.bin -> book.bin.rice(BKE1)。

方案(依实测熵:H(from)=5.26b,H(to|from)=1.56b,flags 可拆三子字段):
  from: 6 位定长打包(近均匀,Rice 无益)
  to:   每 from 词典(首现序去重)+ 词典下标 Rice
  hasFam: 1 位定长 | pop: Rice | nKids: Rice | fam: Rice
  名字区/计数前缀原样(文本,交给传输层 gzip)
布局: u32 magic"1EKB" | u32 ver | u32 raw_len | u32 n_nodes | u32 prefix_len |
  前缀原样 | 词典(u8 cnt[64] + 去重 to 串) | u8 k[4] | u32 len[5] | 五段位流。
自校验:内置独立解码器,往返必须与源逐字节一致。
"""
import struct

SRC, DST = 'src/book.bin', 'src/book.bin.rice'
MAGIC, VER = 0x3145424B, 1

def zz(v): return (v << 1) ^ (v >> 31) if v >= 0 else (-v) * 2 - 1

class BW:
    def __init__(self): self.out = bytearray(); self.acc = 0; self.nb = 0
    def wbit(self, b):
        self.acc = (self.acc << 1) | b; self.nb += 1
        if self.nb == 8: self.out.append(self.acc); self.acc = 0; self.nb = 0
    def wfix(self, v, n):
        for i in range(n - 1, -1, -1): self.wbit((v >> i) & 1)
    def rice(self, v, k):
        u = v  # 本格式各流均为非负值(下标/档位/计数),不做 zigzag
        q = u >> k
        for _ in range(q): self.wbit(0)
        self.wbit(1)
        self.wfix(u & ((1 << k) - 1), k)
    def done(self):
        if self.nb: self.out.append((self.acc << (8 - self.nb)) & 0xFF)
        return bytes(self.out)

def bits_rice(vals, k): return sum((v >> k) + 1 + k for v in vals)
def best_k(vals): return min(range(17), key=lambda k: bits_rice(vals, k))

d = open(SRC, 'rb').read()
n_fam = struct.unpack_from('<H', d, 0)[0]
off = 2
for _ in range(n_fam):
    en = struct.unpack_from('<H', d, off)[0]; off += 2 + en
    zh = struct.unpack_from('<H', d, off)[0]; off += 2 + zh
off += 5
prefix_len = off
froms, tos, hasfams, pops, kids, fams = [], [], [], [], [], []
p = off
while p < len(d):
    froms.append(d[p]); tos.append(d[p+1]); f = d[p+2]; p += 3
    pops.append((f >> 5) & 3); kids.append(f & 31); hasfams.append(1 if f & 0x80 else 0)
    if f & 0x80: fams.append(d[p]); p += 1
n_nodes = len(froms)

# 每 from 词典(首现序)
dicts = [dict() for _ in range(64)]
for f, t in zip(froms, tos):
    if t not in dicts[f]: dicts[f][t] = len(dicts[f])
toidx = [dicts[f][t] for f, t in zip(froms, tos)]

wf = BW()
for v in froms: wf.wfix(v, 6)
s_from = wf.done()
def riced(vals):
    k = best_k(vals); w = BW()
    for v in vals: w.rice(v, k)
    return k, w.done()
k_ti, s_ti = riced(toidx)
wh = BW()
for v in hasfams: wh.wbit(v)
s_hf = wh.done()
k_pop, s_pop = riced(pops)
k_kid, s_kid = riced(kids)
k_fam, s_fam = riced(fams)

dict_tab = bytes(len(dicts[f]) for f in range(64)) + b''.join(bytes(dicts[f]) for f in range(64))
blob = struct.pack('<5I', MAGIC, VER, len(d), n_nodes, prefix_len)
blob += d[:prefix_len] + dict_tab + bytes([k_ti, k_pop, k_kid, k_fam])
blob += struct.pack('<5I', len(s_from), len(s_ti), len(s_hf), len(s_pop), len(s_kid)) + struct.pack('<I', len(s_fam))
blob += s_from + s_ti + s_hf + s_pop + s_kid + s_fam
open(DST, 'wb').write(blob)
print(f"{len(d)}B -> {len(blob)}B({len(blob)*100//len(d)}%):from {len(s_from)} to {len(s_ti)}(k={k_ti},词典 {len(dict_tab)}B) hasFam {len(s_hf)} pop {len(s_pop)} nKids {len(s_kid)} fam {len(s_fam)} 前缀 {prefix_len}")

# ---- 独立解码往返校验 ----
class BR:
    def __init__(self, s): self.s = s; self.p = 0; self.acc = 0; self.nb = 0
    def bit(self):
        if self.nb == 0: self.acc = self.s[self.p]; self.p += 1; self.nb = 8
        self.nb -= 1
        return (self.acc >> self.nb) & 1
    def fix(self, n):
        v = 0
        for _ in range(n): v = (v << 1) | self.bit()
        return v
    def rice(self, k):
        q = 0
        while self.bit() == 0: q += 1
        r = self.fix(k)
        return (q << k) | r

h = struct.unpack_from('<5I', blob, 0)
n_nodes2, plen = h[3], h[4]
p = 20 + plen
cnts = blob[p:p+64]; p += 64
dict2 = []
for f in range(64):
    dict2.append(list(blob[p:p+cnts[f]])); p += cnts[f]
ks = blob[p:p+4]; p += 4
lens = struct.unpack_from('<5I', blob, p); p += 20
lens += struct.unpack_from('<I', blob, p); p += 4
# 逐流解码
base = p
rF = BR(blob[base:base+lens[0]]); base += lens[0]
rT = BR(blob[base:base+lens[1]]); base += lens[1]
rH = BR(blob[base:base+lens[2]]); base += lens[2]
rP = BR(blob[base:base+lens[3]]); base += lens[3]
rK = BR(blob[base:base+lens[4]]); base += lens[4]
rM = BR(blob[base:base+lens[5]])
out = bytearray(blob[20:20+plen])
for _ in range(n_nodes2):
    f = rF.fix(6)
    t = dict2[f][rT.rice(ks[0])]
    hf = rH.bit()
    pop = rP.rice(ks[1]); kid = rK.rice(ks[2])
    flag = (hf << 7) | (pop << 5) | kid
    out += bytes([f, t, flag])
    if hf: out.append(rM.rice(ks[3]))
assert bytes(out) == d, "往返失败"
print("往返校验:与源逐字节一致")

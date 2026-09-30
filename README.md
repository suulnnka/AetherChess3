# AetherChess3

AetherChess v3,Zig 单线程 UCI 引擎。以 4ku(commit `917a087`)的逐位复刻为底座起家,
2026-09-27 起独立迭代:移除 SMP,估值替换为 AetherChess2 的 v7 NNUE(内嵌 v7_s1_D 网络,
增量 accumulator);棋盘改为绝对坐标表示。

## 构建

```bash
zig build-exe src/main.zig -O ReleaseFast -mcpu=native -femit-bin=aether3
./aether3          # UCI 协议;bench 子命令为固定深度基准
```

## NPS(同机实测)

| 引擎 | eval 方式 | NPS |
| --- | --- | --- |
| AetherChess2(Rust) | v7 NNUE,增量 accumulator | 1.34M / 1.46M(两轮) |
| AetherChess3(Zig) | v7 NNUE,全量刷新 | 0.89M |
| AetherChess3(Zig) | 4ku HCE(已移除) | 2.0M |
| **AetherChess3(Zig,当前)** | v7 NNUE,增量 acc(per-ply 栈)+ make/unmake + 增量 Zobrist | **~2.25M bench** |

注:各引擎 bench 负载不同,NPS 跨引擎仅量级可比。

## 世代阶梯(2026-09-30 定档,master 分支六个代表版本)

Elo 为 15 对两两对战(各 100 局 movetime 100ms)的最小二乘拟合,基线 = 最弱代;
NPS 为同机 bench 实测(同日、同编译参数):

| 版本 | 定位 | bench 节点 | NPS | 拟合 Elo |
| --- | --- | --- | --- | --- |
| `cdb264c` | 基线:4ku 复刻 + v7 NNUE + 协议修复 | 3,534,745 | 2.63M | +10 |
| `17e2570` | 纯底座终版:健壮性修复(qsearch 绽放/粘性 stopped) | 3,534,745 | 2.62M | +14 |
| `6cb9ba5` | 全特性装配(带病):SEE/conthist/TT2/SE,四 bug 未修 | 6,137,752 | 2.35M | 0 |
| `72beea8` | 修复解锁:SEE 幻影/幽灵、LMR 时序、TT2 条件四 bug 修复 | 5,901,753 | 2.21M | +24 |
| `5048a56` | 收官定型:qsearch SEE 剪枝 + 数值修正 + 清理(§九-十四) | 5,323,945 | 2.26M | +25 |
| **`6d27296`(HEAD)** | **定案版:坏吃子降级排序合入(§十七-十九)** | 4,632,407 | 2.25M | **+42** |

外部坐标:HEAD vs 4ku 原版 = **+301 ± 34**(1s+0.1,200 局);vs minifish(SF17 系)=
−350 ± 38(movetime 100,200 局;按 v7 网强于 HL64 的前提,引擎侧差距 ≥350)。
要点:①带病特性版(6cb)弱于干净基线——四 bug 修复前 exp 特性净贡献为负;
②NPS 从 2.63M 降至 2.25M(−14%,SEE/SE/conthist 每节点成本),换回代际 +32~+42;
③100 局/种子读数的种子间摆幅可达 ±40(同对引擎跨种子 −17→+63),比较须固定协议或多
种子合并(HEAD vs 基线合并 300 局 = +36 ± 20)。
原始数据:`/home/a/chess/save/a3_roundrobin/`;全程门控与裁决:`../docs/AetherChess3.md`。

复刻方法、保真度证据链、性能与对抗数据:`../docs/AetherChess3.md`。

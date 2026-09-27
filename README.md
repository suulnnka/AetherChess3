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
| **AetherChess3(Zig,当前)** | v7 NNUE,增量 acc(per-ply 栈)+ make/unmake + 增量 Zobrist | **~1.8M(空载峰值 2.07M)** |

注:各引擎 bench 负载不同,NPS 跨引擎仅量级可比。

复刻方法、保真度证据链、性能与对抗数据:`../docs/AetherChess3.md`。

# AetherChess3

## 在线体验

- **AetherWebOS**:桌面级 Web 操作系统,[github](https://github.com/suulnnka/AetherWebOS) ——
  在线体验 <https://suulnnka.github.io/AetherWebOS/>
- **AetherChess3 对弈页**:
  <https://suulnnka.github.io/AetherChess3/> —— NNUE 引擎 + 开局谱库全在 wasm 里

## 简介

Zig 单线程 UCI 国际象棋引擎。**在 [4ku](https://github.com/kz04px/4ku) 的基础上修改而来**:
棋盘/走法生成与剪枝骨架复刻自 4ku,估值换为自训 NNUE,并在此之上独立迭代。

### 前代项目

- [AetherChess](https://github.com/suulnnka/AetherChess)(v1):Zig/wasm 单实现,规则/评估/
  搜索/开局谱库全在 wasm,WebOS 宿主;
- AetherChess2(v2):Rust 重写,HCE → NNUE,v5~v7 网的训练管线出自它;
  **已淘汰的未公开项目**;
- [4ku](https://github.com/kz04px/4ku):本仓库的搜索骨架来源。

## 技术

NNUE | 增量 accumulator | PVS | 迭代加深 | aspiration windows | 两层置换表 | 静态搜索 |
LMR | Singular Extension | 将军延伸 | IIR | SEE 剪枝 | NMP | RFP | FFP | LMP |
razoring | delta 剪枝 | mate distance pruning | 坏吃子降级排序 | MVV-LVA |
continuation history | countermove | killer moves | history heuristic |
50 步规则 | 三次重复检测 | 开局库 | Rice 编码 | SPSA 调参

## 训练数据与方式(v7_s1_D)

- **数据**:公开 bullet 数据集 `linrock/bullet-training-data`,
  混合镜像特征;WDL 前置标注;
- **方式**:从零训练,`tools/training/trainer2.rs`(本仓库已附,自 AetherChess2 归档,
  依赖其 crate 结构;`datagen.rs` 为数据生成参考)——
  768→64×2 SCReLU→8 材料桶,SigmoidMPE(2.6)损失,engine-faithful sigmoid,
  AdamW(wd 0.01、clamp ±1.98)、batch 16384、lr 线性衰减,S1 蒸馏 λ=0;
  量化 int8 FT + 无损异常表(v4 格式),产物 51,952B,经 `tools/gen_rice.py` 压缩内嵌。

## 打包与体积

```bash
# 原生 UCI 引擎
zig build-exe src/main.zig -O ReleaseFast -mcpu=native -femit-bin=aether3

# wasm 对弈页产物(→ wasm/chess.wasm)
./tools/build-wasm.sh
```

wasm 产物 ~118KB(gzip ~67KB)

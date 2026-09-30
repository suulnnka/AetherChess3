// NNUE trainer v2 — recipe ported from linrock's minifish (Kaggle 1st, see
// docs/minifish.mhtml + minifish/training/HL64-q96-q144-*.rs):
//   * SigmoidMPE(2.6) loss — power loss on sigmoid-space error (bullet Loss::SigmoidMPE)
//   * WDL blending on the target probability: S1 constant 0, S2 linear 0 -> 0.1
//   * AdamW (decoupled decay 0.01) with hard weight clip +-1.98 (bullet AdamWParams)
//   * linear LR decay to 0, batch 16384, no warmup (bullet LinearDecayLR)
// Deliberate differences (documented in docs/AetherChess2-v6-training.md):
//   * scores rescaled at load so the net outputs this engine's cp (pawn=100):
//     UHO pawn ~= 190 raw units (--score-scale 0.5263), T77/79 ~= 250 (0.4)
//   * engine-faithful sigmoid: p = sigmoid((400*dot + c)/400), matching the
//     saved net exactly (old trainer trained sigmoid(dot + c) — exact only
//     when c ~ 0)
//   * FT weight clip is a flag (--maxw 1.98 replaces the old hard +-0.8)
//
// Net formats (see src/nnue.rs): default export is v3 (all-i16, QA=255/QV=64).
// --quant i8 exports v4: FT layer int8 @ QA=101 + lossless exception list,
// output i16 @ QV=160 (minifish shipped constants) — halves the net file.
// --ckpt <path> saves the full-precision master at end of training (f32,
// "AECK" format, ~201KB) — the bullet/minifish workflow: training and
// quantization are separate steps, and requant/resume from the checkpoint
// quantize with a single rounding instead of dequantize-requantize.
// --requant <net.nnue|.ckpt> skips training and re-exports any loadable net
// or checkpoint in the --quant format. With --probe-data <file.aet2> instead
// of --out, it evaluates the full-precision master (NO quantization — the
// stage-A f32 screening probe) and prints one engine-cp per line, output
// shaped like eval_dump so tools/spearman_check.py works unchanged.
//
// Data format (.aet2, 72 bytes/record): see trainer.rs. Records with score == -1
// (missing eval sentinel) are skipped.
//
// Usage:
//   trainer2 --data <file.aet2...> --out <net.nnue> [--epochs 16] [--lr 0.0015]
//            [--batch 16384] [--val-frac 0.01] [--probe 32768] [--seed 7]
//            [--resume <net.nnue>] [--wd 0.01] [--maxw 1.98]
//            [--score-scale 0.5263] [--wdl-start 0.0] [--wdl-end 0.0]
//            [--quant i16|i8] [--requant <net.nnue|.ckpt>] [--ckpt <path>] [--keep-last]

use aether2::nnue::{
    feat, parse_net, ARCH_M0, ARCH_M1, NET_BYTES, NET_VERSION, NET_VERSION_I8, QA, QA_I8, QV,
    QV_I8, SCALE,
};
use std::io::{BufRead, BufReader, Read, Write};

const HIDDEN: usize = 64;
const INPUTS: usize = 768;
const BUCKETS: usize = 8;
const REC: usize = 72;
const POW: f32 = 2.6;

type BB = u64;

struct Sample {
    feats: [[u16; 33]; 2], // 32 max pieces + count in [32]
    side: u8,
    score: f32,  // net-cp (rescaled), stm POV
    result: f32, // 0/0.5/1 stm POV
    bucket: u8,
}

fn board_from(bits: &[u64; 8], color: usize) -> [BB; 6] {
    let (w, b, p, n, bi, r, q, k) = (bits[0], bits[1], bits[2], bits[3], bits[4], bits[5], bits[6], bits[7]);
    let own = if color == 0 { w } else { b };
    [p & own, n & own, bi & own, r & own, q & own, k & own]
}

fn load_file(path: &str, out: &mut Vec<Sample>, score_scale: f32, arch: u32) {
    let n = (std::fs::metadata(path).expect("data path").len() as usize) / REC;
    out.reserve(n);
    let mut f = BufReader::with_capacity(1 << 22, std::fs::File::open(path).expect("open data"));
    let mut rec = [0u8; REC];
    let mut skipped = 0usize;
    let mut i = 0usize;
    while f.read_exact(&mut rec).is_ok() {
        let score_raw = i16::from_le_bytes(rec[66..68].try_into().unwrap());
        if score_raw == -1 {
            skipped += 1;
            i += 1;
            continue;
        }
        let mut bits = [0u64; 8];
        for j in 0..8 {
            bits[j] = u64::from_le_bytes(rec[j * 8..j * 8 + 8].try_into().unwrap());
        }
        let result = match rec[68] {
            0 => 0.0f32,
            1 => 0.5,
            _ => 1.0,
        };
        // M1 mirror flags from the record's king squares: white view flips on
        // the white king's file, black view on the black king's file as seen
        // after the 180° perspective rotation (see nnue::feat).
        let (m0, m1) = if arch == ARCH_M1 {
            let wk = (bits[7] & bits[0]).trailing_zeros() as u8;
            let bk = (bits[7] & bits[1]).trailing_zeros() as u8;
            (wk % 8 > 3, bk % 8 < 4)
        } else {
            (false, false)
        };
        let mut feats = [[0u16; 33]; 2];
        for persp in 0..2usize {
            let mir = if persp == 0 { m0 } else { m1 };
            let mut cnt = 0usize;
            for color in 0..2usize {
                let pcs = board_from(&bits, color);
                for (ty, &bset) in pcs.iter().enumerate() {
                    let mut b = bset;
                    while b != 0 {
                        let sq = b.trailing_zeros() as u8;
                        b &= b - 1;
                        feats[persp][cnt] = feat(persp as u8, color as u8, ty as u8, sq, mir) as u16;
                        cnt += 1;
                    }
                }
            }
            feats[persp][32] = cnt as u16;
        }
        let n_all = (bits[0] | bits[1]).count_ones() as usize;
        let bucket = ((n_all.saturating_sub(2)) * (BUCKETS - 1) / 30).min(BUCKETS - 1);
        out.push(Sample {
            feats,
            side: rec[64],
            score: score_raw as f32 * score_scale,
            result,
            bucket: bucket as u8,
        });
        i += 1;
    }
    eprintln!("loaded {} records from {} (skipped {} score==-1, total {})", i, path, skipped, out.len());
}

struct Rng(u64);
impl Rng {
    fn next_f32(&mut self) -> f32 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        ((x.wrapping_mul(0x2545F4914F6CDD1D) >> 40) as f32) / (1u64 << 24) as f32
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next_f32() * n as f32) as usize % n.max(1)
    }
}

#[derive(Clone)]
struct Master {
    arch: u32, // ARCH_M0 / ARCH_M1 — written to v4/ckpt headers, drives feat indexing
    w: Vec<f32>, // INPUTS x HIDDEN, feature-major
    b: [f32; HIDDEN],
    v: Vec<[f32; HIDDEN * 2]>, // BUCKETS
    c: [f32; BUCKETS],
}

fn init_master(seed: u64, arch: u32) -> Master {
    let mut rng = Rng(seed);
    let s1 = (2.0 / INPUTS as f32).sqrt() * 1.4;
    let s2 = (2.0 / (HIDDEN * 2) as f32).sqrt() * 1.4;
    let mut m = Master {
        arch,
        w: vec![0.0; INPUTS * HIDDEN],
        b: [0.0; HIDDEN],
        v: vec![[0.0; HIDDEN * 2]; BUCKETS],
        c: [0.0; BUCKETS],
    };
    for x in m.w.iter_mut() {
        *x = (rng.next_f32() * 2.0 - 1.0) * s1;
    }
    for bkt in m.v.iter_mut() {
        for x in bkt.iter_mut() {
            *x = (rng.next_f32() * 2.0 - 1.0) * s2;
        }
    }
    m
}

// ---- f32 checkpoint ("AECK") -------------------------------------------
// Full-precision master on disk so quantization (--requant, single rounding
// from f32) and S2 resume can run later as separate steps. Layout:
// u32 magic "AECK" | u32 ver=1 | u32 arch | u32 epochs | f32 best val_loss
// | f32 w[768*64] | f32 b[64] | f32 v[8][128] | f32 c[8].
fn ckpt_bytes() -> usize {
    20 + (INPUTS * HIDDEN + HIDDEN + BUCKETS * HIDDEN * 2 + BUCKETS) * 4
}

fn write_ckpt(m: &Master, path: &str, epochs_trained: u32, val_loss: f32) {
    let mut bytes = Vec::with_capacity(ckpt_bytes());
    bytes.extend_from_slice(b"AECK");
    bytes.extend_from_slice(&1u32.to_le_bytes());
    bytes.extend_from_slice(&m.arch.to_le_bytes());
    bytes.extend_from_slice(&epochs_trained.to_le_bytes());
    bytes.extend_from_slice(&val_loss.to_le_bytes());
    for &x in &m.w {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for &x in m.b.iter() {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for bk in 0..BUCKETS {
        for k in 0..HIDDEN * 2 {
            bytes.extend_from_slice(&m.v[bk][k].to_le_bytes());
        }
    }
    for bk in 0..BUCKETS {
        bytes.extend_from_slice(&m.c[bk].to_le_bytes());
    }
    std::fs::write(path, &bytes).expect("write ckpt");
    eprintln!("f32 checkpoint written to {} ({} bytes)", path, bytes.len());
}

/// Load an f32 checkpoint ("AECK") or a quantized net (v3/v4) as an f32 master.
/// Checkpoints restore exactly; nets are dequantized (one extra rounding).
fn load_master(path: &str) -> Master {
    let bytes = std::fs::read(path).expect("read net/checkpoint");
    if bytes.len() >= 4 && bytes[0..4] == *b"AECK" {
        assert_eq!(bytes.len(), ckpt_bytes(), "checkpoint size mismatch");
        let rd_u32 = |o: usize| u32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        let rd_f32 = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        let arch = rd_u32(8);
        assert!(arch == ARCH_M0 || arch == ARCH_M1, "checkpoint arch mismatch");
        let epochs = rd_u32(12);
        let val = rd_f32(16);
        let mut off = 20;
        let mut m = Master {
            arch,
            w: vec![0.0; INPUTS * HIDDEN],
            b: [0.0; HIDDEN],
            v: vec![[0.0; HIDDEN * 2]; BUCKETS],
            c: [0.0; BUCKETS],
        };
        for x in m.w.iter_mut() {
            *x = rd_f32(off);
            off += 4;
        }
        for x in m.b.iter_mut() {
            *x = rd_f32(off);
            off += 4;
        }
        for bk in 0..BUCKETS {
            for k in 0..HIDDEN * 2 {
                m.v[bk][k] = rd_f32(off);
                off += 4;
            }
        }
        for bk in 0..BUCKETS {
            m.c[bk] = rd_f32(off);
            off += 4;
        }
        eprintln!("loaded f32 checkpoint {} (arch M{}, {} epochs, best val {:.6})", path, arch, epochs, val);
        return m;
    }
    let net = parse_net(&bytes).expect("parse net");
    let m = Master {
        arch: net.arch,
        w: net.ft_w.iter().map(|&x| x as f32 / net.qa as f32).collect(),
        b: std::array::from_fn(|k| net.ft_b[k] as f32 / net.qa as f32),
        v: net
            .out_w
            .iter()
            .map(|row| row.map(|x| x as f32 / net.qv as f32))
            .collect(),
        c: std::array::from_fn(|bk| {
            net.out_b[bk] as f32 * SCALE as f32 / (net.qa * net.qv) as f32
        }),
    };
    eprintln!("loaded net {} (qa {} qv {}, arch M{}, dequantized to f32)", path, net.qa, net.qv, net.arch);
    m
}

struct BatchGrads {
    gw: Vec<f32>,
    gb: [f32; HIDDEN],
    gv: Vec<f32>,
    gc: [f32; BUCKETS],
}

impl BatchGrads {
    fn new() -> Self {
        BatchGrads {
            gw: vec![0f32; INPUTS * HIDDEN],
            gb: [0f32; HIDDEN],
            gv: vec![0f32; BUCKETS * HIDDEN * 2],
            gc: [0f32; BUCKETS],
        }
    }
}

// Forward + backward for one sample. SigmoidMPE gradient:
//   z = (400*dot + c)/400   (engine cp / SCALE — exactly the sigmoid the engine sees)
//   e = sigmoid(z) - target
//   dL/dz = POW * |e|^(POW-1) * sign(e) * sigmoid'(z)
// dL/d(dot) = dL/dz (the 400 cancels), dL/dc = dL/dz / 400.
fn forward_sample(
    s: &Sample,
    wdl: f32,
    m: &Master,
    g: &mut BatchGrads,
    loss_acc: &mut f64,
    probe: Option<(&mut Vec<f32>, &mut Vec<f32>)>,
) {
    let mut acc = [[0.0f32; HIDDEN]; 2];
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let row = &m.w[f * HIDDEN..(f + 1) * HIDDEN];
            let a = &mut acc[persp];
            for i in 0..HIDDEN {
                a[i] += row[i];
            }
        }
        for i in 0..HIDDEN {
            acc[persp][i] += m.b[i];
        }
    }
    let bk = s.bucket as usize;
    let (pa, pb) = (s.side as usize, 1 - s.side as usize);
    let mut act = [0.0f32; HIDDEN * 2];
    for i in 0..HIDDEN {
        let x0 = acc[pa][i].clamp(0.0, 1.0);
        let x1 = acc[pb][i].clamp(0.0, 1.0);
        act[i] = x0 * x0;
        act[HIDDEN + i] = x1 * x1;
    }
    let mut dot = 0f32;
    for i in 0..HIDDEN * 2 {
        dot += m.v[bk][i] * act[i];
    }
    let c = m.c[bk];
    let z = dot + c / SCALE as f32;
    let pr = 1.0 / (1.0 + (-z).exp());
    let target = (1.0 - wdl) * (1.0 / (1.0 + (-(s.score / SCALE as f32)).exp())) + wdl * s.result;
    let err = pr - target;
    *loss_acc += (err.abs() as f64).powf(POW as f64);
    if let Some((preds, labels)) = probe {
        preds.push(SCALE as f32 * dot + c); // engine cp
        labels.push(s.score);
    }
    let sgn = if err > 0.0 { 1.0 } else if err < 0.0 { -1.0 } else { 0.0 };
    let dz = POW * err.abs().powf(POW - 1.0) * sgn * pr * (1.0 - pr);
    for i in 0..HIDDEN * 2 {
        g.gv[bk * HIDDEN * 2 + i] += dz * act[i];
    }
    g.gc[bk] += dz / SCALE as f32;
    let dacc_off = |persp: usize| if persp == pa { 0 } else { HIDDEN };
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        let mut daccp = [0.0f32; HIDDEN];
        let off = dacc_off(persp);
        for i in 0..HIDDEN {
            let x = acc[persp][i];
            // SCReLU'(x) = 2x only inside the clamp window (0,1); saturated
            // units must receive zero gradient, else weights drift outward
            // forever (the "eval degeneration" root cause).
            if x > 0.0 && x < 1.0 {
                daccp[i] = 2.0 * x * dz * m.v[bk][off + i];
            }
        }
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let gr = &mut g.gw[f * HIDDEN..(f + 1) * HIDDEN];
            for i in 0..HIDDEN {
                gr[i] += daccp[i];
            }
        }
        for i in 0..HIDDEN {
            g.gb[i] += daccp[i];
        }
    }
}

fn spearman(preds: &[f32], labels: &[f32]) -> f64 {
    fn ranks(x: &[f32]) -> Vec<f64> {
        let mut idx: Vec<usize> = (0..x.len()).collect();
        idx.sort_by(|&a, &b| x[a].partial_cmp(&x[b]).unwrap());
        let mut r = vec![0f64; x.len()];
        let mut i = 0usize;
        while i < idx.len() {
            let mut j = i;
            while j + 1 < idx.len() && x[idx[j + 1]] == x[idx[i]] {
                j += 1;
            }
            let avg = (i + j) as f64 / 2.0 + 1.0;
            for k in i..=j {
                r[idx[k]] = avg;
            }
            i = j + 1;
        }
        r
    }
    let (rp, rl) = (ranks(preds), ranks(labels));
    let n = rp.len() as f64;
    let (mp, ml) = (rp.iter().sum::<f64>() / n, rl.iter().sum::<f64>() / n);
    let mut num = 0f64;
    let (mut dp, mut dl) = (0f64, 0f64);
    for k in 0..rp.len() {
        let a = rp[k] - mp;
        let b = rl[k] - ml;
        num += a * b;
        dp += a * a;
        dl += b * b;
    }
    num / (dp.sqrt() * dl.sqrt()).max(1e-12)
}

// Full-precision forward, no gradients: identical math to forward_sample's
// forward pass (clamp(0,1)^2 SCReLU, cp = SCALE*dot + c) so the stage-A f32
// probe and the eventual quantized engine eval differ only by quantization.
fn forward_cp(s: &Sample, m: &Master) -> f32 {
    let mut acc = [[0.0f32; HIDDEN]; 2];
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let row = &m.w[f * HIDDEN..(f + 1) * HIDDEN];
            let a = &mut acc[persp];
            for i in 0..HIDDEN {
                a[i] += row[i];
            }
        }
        for i in 0..HIDDEN {
            acc[persp][i] += m.b[i];
        }
    }
    let bk = s.bucket as usize;
    let (pa, pb) = (s.side as usize, 1 - s.side as usize);
    let mut dot = 0f32;
    for i in 0..HIDDEN {
        let x0 = acc[pa][i].clamp(0.0, 1.0);
        let x1 = acc[pb][i].clamp(0.0, 1.0);
        dot += m.v[bk][i] * (x0 * x0) + m.v[bk][HIDDEN + i] * (x1 * x1);
    }
    SCALE as f32 * dot + m.c[bk]
}

/// Stage-A screening probe: f32 master vs held-out labels, one cp per line on
/// stdout (eval_dump-compatible) + a summary on stderr. Screening only —
/// loss != Elo; recipe decisions still come from stage-C matches.
fn probe_master(m: &Master, data_path: &str, score_scale: f32) {
    let mut samples = Vec::new();
    load_file(data_path, &mut samples, score_scale, m.arch);
    let n = samples.len();
    let mut preds = Vec::with_capacity(n);
    let mut labels = Vec::with_capacity(n);
    for s in &samples {
        preds.push(forward_cp(s, m));
        labels.push(s.score);
    }
    let mae = preds
        .iter()
        .zip(labels.iter())
        .map(|(p, l)| (p - l).abs() as f64)
        .sum::<f64>()
        / n.max(1) as f64;
    let mp = preds.iter().sum::<f32>() / n.max(1) as f32;
    let ml = labels.iter().sum::<f32>() / n.max(1) as f32;
    let (mut cov, mut vp, mut vl) = (0f64, 0f64, 0f64);
    for (p, l) in preds.iter().zip(labels.iter()) {
        cov += ((p - mp) * (l - ml)) as f64;
        vp += ((p - mp) * (p - mp)) as f64;
        vl += ((l - ml) * (l - ml)) as f64;
    }
    eprintln!(
        "f32 probe: {} records  spearman {:.4}  pearson {:.4}  mae {:.0} cp  (label scale {})",
        n,
        spearman(&preds, &labels),
        cov / (vp.sqrt() * vl.sqrt()).max(1e-12),
        mae,
        score_scale
    );
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    for p in &preds {
        writeln!(out, "{}", p).expect("write probe");
    }
}

fn eval_val(val: &[Sample], wdl: f32, master: &Master, probe_n: usize) -> (f64, f64) {
    let vn = val.len().min(probe_n);
    let mut preds = Vec::with_capacity(vn);
    let mut labels = Vec::with_capacity(vn);
    let mut g = BatchGrads::new();
    let mut vloss = 0f64;
    for s in val.iter().take(vn) {
        forward_sample(s, wdl, master, &mut g, &mut vloss, Some((&mut preds, &mut labels)));
    }
    (vloss / vn.max(1) as f64, spearman(&preds, &labels))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut data_paths: Vec<String> = Vec::new();
    let mut out_path = String::from("v7.nnue");
    let mut epochs = 16usize;
    let mut lr = 0.0015f32;
    let mut batch = 16384usize;
    let mut val_frac = 0.01f32;
    let mut probe_n = 32768usize;
    let mut seed = 7u64;
    let mut resume = String::new();
    let mut wd = 0.01f32;
    let mut maxw = 1.98f32;
    let mut score_scale = 1.0f32;
    let mut wdl_start = 0.0f32;
    let mut wdl_end = 0.0f32;
    let mut keep_last = false;
    let mut quant = String::from("i16");
    let mut requant = String::new();
    let mut ckpt = String::new();
    let mut probe_data = String::new();
    let mut beta1 = 0.9f32;
    let mut arch_arg = String::from("m1");
    let mut arch_given = false;
    let mut i = 1;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--data" => data_paths.push(args[i + 1].clone()),
            "--out" => out_path = args[i + 1].clone(),
            "--epochs" => epochs = args[i + 1].parse().unwrap_or(epochs),
            "--lr" => lr = args[i + 1].parse().unwrap_or(lr),
            "--batch" => batch = args[i + 1].parse().unwrap_or(batch),
            "--val-frac" => val_frac = args[i + 1].parse().unwrap_or(val_frac),
            "--probe" => probe_n = args[i + 1].parse().unwrap_or(probe_n),
            "--seed" => seed = args[i + 1].parse().unwrap_or(seed),
            "--resume" => resume = args[i + 1].clone(),
            "--wd" => wd = args[i + 1].parse().unwrap_or(wd),
            "--maxw" => maxw = args[i + 1].parse().unwrap_or(maxw),
            "--score-scale" => score_scale = args[i + 1].parse().unwrap_or(score_scale),
            "--wdl-start" => wdl_start = args[i + 1].parse().unwrap_or(wdl_start),
            "--wdl-end" => wdl_end = args[i + 1].parse().unwrap_or(wdl_end),
            "--keep-last" => keep_last = true,
            "--quant" => quant = args[i + 1].clone(),
            "--requant" => requant = args[i + 1].clone(),
            "--ckpt" => ckpt = args[i + 1].clone(),
            "--probe-data" => probe_data = args[i + 1].clone(),
            "--beta1" => beta1 = args[i + 1].parse().unwrap_or(beta1),
            "--arch" => {
                arch_arg = args[i + 1].clone();
                arch_given = true;
            }
            _ => {}
        }
        i += 2;
    }
    let quant_i8 = match quant.as_str() {
        "i16" => false,
        "i8" => true,
        _ => {
            eprintln!("trainer2: --quant must be i16 or i8");
            std::process::exit(1);
        }
    };
    if !requant.is_empty() {
        if data_paths.is_empty() {
            let master = load_master(&requant);
            if !probe_data.is_empty() {
                probe_master(&master, &probe_data, score_scale);
                return;
            }
            write_net(&master, &out_path, quant_i8);
            return;
        }
        eprintln!("trainer2: --requant takes no --data");
        std::process::exit(1);
    }
    if data_paths.is_empty() {
        eprintln!("trainer2: no --data given");
        std::process::exit(1);
    }
    // Arch resolution: resume/requant inherit the source net's arch (an --arch
    // override that disagrees is refused — silent M0/M1 mixing mis-indexes
    // features); fresh training takes --arch (default M1, the v7 mirror arch).
    let src_arch: Option<u32> = if resume.is_empty() { None } else { Some(load_master(&resume).arch) };
    let arch = match src_arch {
        Some(a) => {
            let want = match arch_arg.as_str() {
                "m0" => ARCH_M0,
                "m1" => ARCH_M1,
                _ => a,
            };
            if arch_given && want != a {
                eprintln!("trainer2: --arch {} contradicts resumed source arch M{}", arch_arg, a);
                std::process::exit(1);
            }
            a
        }
        None => match arch_arg.as_str() {
            "m0" => ARCH_M0,
            "m1" => ARCH_M1,
            _ => {
                eprintln!("trainer2: --arch must be m0 or m1");
                std::process::exit(1);
            }
        },
    };
    eprintln!("arch M{} beta1 {} seed {}", arch, beta1, seed);

    // Shard directory mode (plan §四①): `--data <dir>/` streams one shard at a
    // time — shard memory, not dataset memory. Per pass: shard order reshuffled,
    // in-shard records reshuffled, val split re-drawn per shard. LR anneals over
    // the total multi-pass sample count (unknown shards estimated from file
    // sizes until first seen, then the schedule self-corrects).
    let shard_mode = data_paths.len() == 1 && std::path::Path::new(&data_paths[0]).is_dir();

    let t0 = std::time::Instant::now();
    let mut rng = Rng(seed.wrapping_mul(7919));
    let mut master = if resume.is_empty() { init_master(seed, arch) } else { load_master(&resume) };
    let n_w = INPUTS * HIDDEN;
    let n_v = BUCKETS * HIDDEN * 2;
    let mut am = [vec![0f32; n_w], vec![0f32; HIDDEN], vec![0f32; n_v], vec![0f32; BUCKETS]];
    let mut av = [vec![0f32; n_w], vec![0f32; HIDDEN], vec![0f32; n_v], vec![0f32; BUCKETS]];
    let mut step = 0usize;
    let mut best_val = f64::MAX;
    let mut best = master.clone();

    // AdamW decoupled update of every parameter block + the ±maxw hard clip.
    macro_rules! adamw_step {
        ($g:expr, $inv:expr, $cur_lr:expr) => {{
            let bc1 = 1.0 - beta1.powi(step as i32);
            let bc2 = 1.0 - 0.999f32.powi(step as i32);
            let upd = |p: &mut f32,
                       gr: f32,
                       m: &mut f32,
                       v: &mut f32,
                       lr: f32,
                       wd: f32,
                       bc1: f32,
                       bc2: f32| {
                *m = beta1 * *m + (1.0 - beta1) * gr;
                *v = 0.999 * *v + 0.001 * gr * gr;
                *p -= lr * ((*m / bc1) / ((*v / bc2).sqrt() + 1e-8) + wd * *p);
            };
            let inv: f32 = $inv;
            let cur_lr: f32 = $cur_lr;
            for k in 0..n_w {
                upd(&mut master.w[k], $g.gw[k] * inv, &mut am[0][k], &mut av[0][k], cur_lr, wd, bc1, bc2);
            }
            for k in 0..HIDDEN {
                upd(&mut master.b[k], $g.gb[k] * inv, &mut am[1][k], &mut av[1][k], cur_lr, wd, bc1, bc2);
            }
            for bk in 0..BUCKETS {
                for k in 0..HIDDEN * 2 {
                    upd(
                        &mut master.v[bk][k],
                        $g.gv[bk * HIDDEN * 2 + k] * inv,
                        &mut am[2][bk * HIDDEN * 2 + k],
                        &mut av[2][bk * HIDDEN * 2 + k],
                        cur_lr,
                        wd,
                        bc1,
                        bc2,
                    );
                }
            }
            for k in 0..BUCKETS {
                upd(&mut master.c[k], $g.gc[k] * inv, &mut am[3][k], &mut av[3][k], cur_lr, wd, bc1, bc2);
            }
            // bullet AdamWParams min_weight/max_weight hard clip on all params
            for x in master.w.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
            for x in master.b.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
            for bkt in master.v.iter_mut() {
                for x in bkt.iter_mut() {
                    *x = x.clamp(-maxw, maxw);
                }
            }
            for x in master.c.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
        }};
    }

    let mut total_steps = 1usize; // shard mode revises as exact counts become known
    if shard_mode {
        let mut shard_paths: Vec<String> = std::fs::read_dir(&data_paths[0])
            .expect("read shard dir")
            .filter_map(|e| {
                let p = e.ok()?.path();
                (p.extension()?.to_str()? == "aet2").then(|| p.to_string_lossy().into_owned())
            })
            .collect();
        shard_paths.sort();
        assert!(!shard_paths.is_empty(), "no .aet2 shards in {}", data_paths[0]);
        let est: Vec<usize> = shard_paths
            .iter()
            .map(|p| (std::fs::metadata(p).expect("shard size").len() as usize) / REC)
            .collect();
        let mut known: Vec<Option<usize>> = vec![None; shard_paths.len()];
        let mut skip_rate = 0.0f32;
        total_steps = est.iter().map(|&e| e.div_ceil(batch)).sum::<usize>() * epochs;
        eprintln!(
            "shard mode: {} shards, ~{} records total (est), {} passes",
            shard_paths.len(),
            est.iter().sum::<usize>(),
            epochs
        );
        for epoch in 0..epochs {
            let wdl = if epochs > 1 {
                wdl_start + (wdl_end - wdl_start) * (epoch as f32 / (epochs - 1) as f32)
            } else {
                wdl_end
            };
            let mut sorder: Vec<usize> = (0..shard_paths.len()).collect();
            for i in (1..sorder.len()).rev() {
                let j = rng.below(i + 1);
                sorder.swap(i, j);
            }
            for (sh_i, &si) in sorder.iter().enumerate() {
                let t_sh = std::time::Instant::now();
                let mut all: Vec<Sample> = Vec::new();
                load_file(&shard_paths[si], &mut all, score_scale, arch);
                let n_rec = (std::fs::metadata(&shard_paths[si]).unwrap().len() as usize) / REC;
                if n_rec > 0 {
                    skip_rate = (n_rec - all.len()) as f32 / n_rec as f32;
                }
                known[si] = Some(all.len());
                // Each shard contributes ceil(count/batch) chunks per pass.
                let steps_per_pass: usize = known
                    .iter()
                    .zip(est.iter())
                    .map(|(k, &e)| {
                        let n = k.unwrap_or((e as f32 * (1.0 - skip_rate)) as usize);
                        n.div_ceil(batch)
                    })
                    .sum();
                total_steps = steps_per_pass * epochs;
                for i in (1..all.len()).rev() {
                    let j = rng.below(i + 1);
                    all.swap(i, j);
                }
                let n_val = (all.len() as f32 * val_frac) as usize;
                let (train, val) = all.split_at(all.len() - n_val);
                let mut loss_sum = 0f64;
                let mut loss_n = 0usize;
                for chunk in train.chunks(batch) {
                    let prog = step as f32 / total_steps as f32;
                    let cur_lr = lr * (1.0 - prog);
                    let mut g = BatchGrads::new();
                    let mut l2 = 0f64;
                    for s in chunk {
                        forward_sample(s, wdl, &master, &mut g, &mut l2, None);
                    }
                    loss_sum += l2;
                    loss_n += chunk.len();
                    let inv = 1.0 / chunk.len() as f32;
                    step += 1;
                    adamw_step!(g, inv, cur_lr);
                }
                let (vloss, sp) = eval_val(val, wdl, &master, probe_n);
                if vloss < best_val {
                    best_val = vloss;
                    best = master.clone();
                }
                eprintln!(
                    "epoch {} shard {}/{} loss {:.6} val {:.6} sp {:.4} lr {:.6} {} ({:.1}s load+train, total {:.1}m)",
                    epoch,
                    sh_i + 1,
                    shard_paths.len(),
                    loss_sum / loss_n.max(1) as f64,
                    vloss,
                    sp,
                    lr * (1.0 - step as f32 / total_steps as f32),
                    shard_paths[si].rsplit('/').next().unwrap_or(""),
                    t_sh.elapsed().as_secs_f64(),
                    t0.elapsed().as_secs_f64() / 60.0
                );
            }
        }
    } else {
        let mut all: Vec<Sample> = Vec::new();
        for p in &data_paths {
            load_file(p, &mut all, score_scale, arch);
        }
        eprintln!("dataset: {} samples in {:.1}s", all.len(), t0.elapsed().as_secs_f64());
        for i in (1..all.len()).rev() {
            let j = rng.below(i + 1);
            all.swap(i, j);
        }
        let n_val = (all.len() as f32 * val_frac) as usize;
        let (train, val) = all.split_at(all.len() - n_val);
        eprintln!("train {} val {}", train.len(), val.len());
        total_steps = (train.len() / batch + 1) * epochs;
        for epoch in 0..epochs {
            // bullet LinearWDL over the stage (per-epoch here)
            let wdl = if epochs > 1 {
                wdl_start + (wdl_end - wdl_start) * (epoch as f32 / (epochs - 1) as f32)
            } else {
                wdl_end
            };
            let mut order: Vec<usize> = (0..train.len()).collect();
            for i in (1..order.len()).rev() {
                let j = rng.below(i + 1);
                order.swap(i, j);
            }
            let mut loss_sum = 0f64;
            let mut loss_n = 0usize;
            let t_ep = std::time::Instant::now();
            for chunk in order.chunks(batch) {
                // bullet LinearDecayLR: initial -> 0 over the whole stage, no warmup
                let prog = step as f32 / total_steps as f32;
                let cur_lr = lr * (1.0 - prog);
                let mut g = BatchGrads::new();
                let mut l2 = 0f64;
                for &si in chunk {
                    forward_sample(&train[si], wdl, &master, &mut g, &mut l2, None);
                }
                loss_sum += l2;
                loss_n += chunk.len();
                if std::env::var("TRACE").is_ok() && loss_n % (batch * 25) == 0 {
                    let (vl, sp) = eval_val(val, wdl, &master, 8192);
                    eprintln!(
                        "  step {} loss {:.6} val {:.6} sp {:.4} max|w| {:.3}",
                        step,
                        l2 / chunk.len() as f64,
                        vl,
                        sp,
                        master.w.iter().fold(0f32, |a, &x| a.max(x.abs()))
                    );
                }
                let inv = 1.0 / chunk.len() as f32;
                step += 1;
                adamw_step!(g, inv, cur_lr);
            }
            let (vloss, sp) = eval_val(val, wdl, &master, probe_n);
            let max_w = master.w.iter().fold(0f32, |a, &x| a.max(x.abs()));
            let max_b = master.b.iter().fold(0f32, |a, &x| a.max(x.abs()));
            eprintln!(
                "epoch {} wdl {:.3} loss {:.6} val {:.6} spearman {:.4} max|w| {:.3} max|b| {:.3} lr {:.6} {:.1}s",
                epoch,
                wdl,
                loss_sum / loss_n.max(1) as f64,
                vloss,
                sp,
                max_w,
                max_b,
                lr * (1.0 - step as f32 / total_steps as f32),
                t_ep.elapsed().as_secs_f64()
            );
            if vloss < best_val {
                best_val = vloss;
                best = master.clone();
            }
        }
    }
    if keep_last {
        best = master; // minifish ships the final S2 checkpoint (lr->0, WDL at end)
    }
    master = best;
    eprintln!("best val {:.6}", best_val);
    if !ckpt.is_empty() {
        write_ckpt(&master, &ckpt, epochs as u32, best_val as f32);
    }
    write_net(&master, &out_path, quant_i8);
}

// Quantize & save. i16 mode = NET_VERSION 3 layout (identical bytes to the
// old inline exporter); i8 mode = NET_VERSION 4: FT weights+biases int8 at
// QA_I8 with the overflow weights carried in a lossless exception list,
// output layer i16 at QV_I8. cp contract unchanged: SCALE cancels qa*qv.
fn write_net(master: &Master, out_path: &str, i8_mode: bool) {
    if !i8_mode {
        if master.arch != ARCH_M0 {
            // v3 headers carry no arch field; an M1 net read back would be
            // silently indexed M0 (wrong evals). Ship M1 as v4 i8 only.
            eprintln!("refusing v3 i16 export of an M1 (mirror) master — use --quant i8");
            std::process::exit(1);
        }
        let mut bytes = Vec::with_capacity(NET_BYTES);
        bytes.extend_from_slice(&0x4E4E4541u32.to_le_bytes());
        bytes.extend_from_slice(&NET_VERSION.to_le_bytes());
        let qa_max = 32000.0 / QA as f32;
        for k in 0..INPUTS * HIDDEN {
            let x = master.w[k].clamp(-qa_max, qa_max);
            bytes.extend_from_slice(&((x * QA as f32).round() as i16).to_le_bytes());
        }
        for k in 0..HIDDEN {
            let x = master.b[k].clamp(-qa_max, qa_max);
            bytes.extend_from_slice(&((x * QA as f32).round() as i16).to_le_bytes());
        }
        for bk in 0..BUCKETS {
            for k in 0..HIDDEN * 2 {
                bytes.extend_from_slice(&((master.v[bk][k] * QV as f32).round() as i16).to_le_bytes());
            }
        }
        for bk in 0..BUCKETS {
            let cb = master.c[bk] * (QA * QV) as f32 / SCALE as f32;
            bytes.extend_from_slice(&(cb.round() as i16).to_le_bytes());
        }
        std::fs::write(out_path, &bytes).expect("write net");
        eprintln!("net written to {} ({} bytes, v3 i16)", out_path, bytes.len());
        return;
    }
    // v4: exceptions hold the true QA_I8-scaled value for anything beyond i8.
    let q8 = |x: f32| (x * QA_I8 as f32).round() as i32;
    let mut qw = Vec::with_capacity(INPUTS * HIDDEN);
    let mut qb = [0i8; HIDDEN];
    let mut except: Vec<(u32, i16)> = Vec::new();
    for k in 0..INPUTS * HIDDEN {
        let q = q8(master.w[k]);
        if q > 127 || q < -128 {
            except.push((k as u32, q as i16));
        }
        qw.push(q.clamp(-128, 127) as i8);
    }
    for k in 0..HIDDEN {
        let q = q8(master.b[k]);
        if q > 127 || q < -128 {
            except.push(((INPUTS * HIDDEN + k) as u32, q as i16));
        }
        qb[k] = q.clamp(-128, 127) as i8;
    }
    let mut bytes = Vec::with_capacity(aether2::nnue::net_bytes_i8(except.len()));
    bytes.extend_from_slice(&0x4E4E4541u32.to_le_bytes());
    bytes.extend_from_slice(&NET_VERSION_I8.to_le_bytes());
    bytes.extend_from_slice(&master.arch.to_le_bytes());
    bytes.extend_from_slice(&(QA_I8 as u32).to_le_bytes());
    bytes.extend_from_slice(&(QV_I8 as u32).to_le_bytes());
    bytes.extend_from_slice(&(except.len() as u32).to_le_bytes());
    for (idx, val) in &except {
        bytes.extend_from_slice(&idx.to_le_bytes());
        bytes.extend_from_slice(&val.to_le_bytes());
    }
    for &x in &qw {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for &x in qb.iter() {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for bk in 0..BUCKETS {
        for k in 0..HIDDEN * 2 {
            bytes.extend_from_slice(&((master.v[bk][k] * QV_I8 as f32).round() as i16).to_le_bytes());
        }
    }
    for bk in 0..BUCKETS {
        let cb = master.c[bk] * (QA_I8 * QV_I8) as f32 / SCALE as f32;
        bytes.extend_from_slice(&(cb.round() as i16).to_le_bytes());
    }
    std::fs::write(out_path, &bytes).expect("write net");
    eprintln!(
        "net written to {} ({} bytes, v4 i8: {} FT exceptions)",
        out_path,
        bytes.len(),
        except.len()
    );
}

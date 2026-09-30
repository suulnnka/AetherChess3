#!/usr/bin/env python3
"""Joint SPSA over ALL tunable surfaces of AetherChess3 (30 params):

  A3_SEARCH_PARAMS (15)  round-1 4ku constants   (rfp/razoring/qs_delta/ffp/
                         nmp/lmr/hist_gravity/lmp/asp)
  A3_STACK_PARAMS  (9)  exp-series feature knobs (SEE quiets/captures,
                         conthist threshold, SE, MVV scale, LMR cond mag,
                         qs futility margin)
  A3_MAT_PARAMS    (6)   max_material P/N/B/R/Q + conthist gravity

Same chunked/resumable paired-SPSA machinery as spsa_search3/spsa_stack,
with fishtest-style per-param calibration: c_i = c_ratio*(hi-lo) (floor 1),
a_i = r0*(hi-lo)*2*c_i, a_k = a_i/(1+k/K)^0.602 with K = iters/10.
Theta checkpointed every iteration (atomic tmp+rename), chunk summary every
--chunk iterations into tune.log; step cap and bounds are safety rails.

Usage:
  spsa_all.py --state /tmp/a3_spsa_all/state.json --iters 800 --chunk 20 \
      --pairs 8 --movetime 100 --workers 12
"""
import argparse, json, os, random, sys, time

A2TOOLS = os.environ.get('A2TOOLS', '../AetherChess2/tools')  # 对局器依赖未公开的 AetherChess2,见文件头
sys.path.insert(0, A2TOOLS)
import match as M  # noqa: E402

# (env-var, name, default, c_rel, lo, hi) — order within each env-var group
# MUST MATCH src/tunables.zig defs/defs2/defs3. c_rel is historical (c is now
# c_ratio * range, built in main()); kept so the table documents old scales.
GROUPS = [
    ('A3_SEARCH_PARAMS', [
        ("rfp_margin",     71, 0.08,  30,  140),
        ("rfp_max_depth",   8, 0.12,   2,   12),
        ("razoring",      238, 0.08, 100,  450),
        ("qs_delta",       50, 0.10,   0,  120),
        ("ffp_margin",    105, 0.08,  40,  220),
        ("ffp_max_depth",   8, 0.12,   3,   12),
        ("nmp_base",        4, 0.15,   0,    7),
        ("nmp_div",         5, 0.15,   3,    8),
        ("nmp_eval_div",  196, 0.08,  80,  400),
        ("nmp_cap",         3, 0.20,   1,    6),
        ("lmr_move_div",   13, 0.08,   8,   22),
        ("lmr_depth_div",  14, 0.08,   4,   24),
        ("hist_gravity",  512, 0.10, 256, 1024),
        ("lmp_base",        1, 0.35,   0,    4),
        ("asp_base",       28, 0.12,  10,   80),
    ]),
    ('A3_STACK_PARAMS', [
        ("sq_coef",        18, 0.12,   6,   40),
        ("sq_cap",         12, 0.15,   6,   26),
        ("se_depth",        7, 0.15,   4,   10),
        ("se_margin",      32, 0.15,   4,   48),
        ("se_vdiv",         2, 0.25,   2,    6),
        ("mvv_scale",      16, 0.12,   8,   32),
                ("qs_fut_margin", 155, 0.12,  60,  350),
    ]),
    ('A3_MAT_PARAMS', [
        ("mat_p",         147, 0.12,  80,  220),
        ("mat_n",         521, 0.12, 250,  700),
        ("mat_b",         521, 0.12, 250,  700),
        ("mat_r",         956, 0.12, 350, 1200),
        ("mat_q",        1782, 0.12, 600, 2200),
        ("ch_gravity",    512, 0.10, 256, 1024),
    ]),
]
PARAMS = [(g[0], *p) for g in GROUPS for p in g[1]]
NAMES = [p[1] for p in PARAMS]
DEFS = [float(p[2]) for p in PARAMS]
LO = [float(p[4]) for p in PARAMS]
HI = [float(p[5]) for p in PARAMS]
# c_i / a_i are built in main() from --c-ratio / --r0 (fishtest-style,
# anchored to each param's range width, not its default value).


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def env_assignments(theta):
    """theta vector -> the three env var strings, each in defs order."""
    out = []
    for gname, rows in GROUPS:
        vals = []
        for row in rows:
            i = NAMES.index(row[0])
            t, l, h = theta[i], LO[i], HI[i]
            vals.append(str(int(round(clamp(t, l, h)))))
        out.append((gname, ','.join(vals)))
    return out


def engine_cmd(engine, workdir, vec, tag):
    wrapper = os.path.join(workdir, f'eng_{tag}.sh')
    envs = ' '.join('%s="%s"' % (n, v) for n, v in env_assignments(vec))
    with open(wrapper, 'w') as f:
        f.write('#!/bin/sh\nexec env %s %s "$@"\n' % (envs, os.path.abspath(engine)))
    os.chmod(wrapper, 0o755)
    return wrapper


def save_state(path, k, theta, meta):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({'k': k, 'theta': theta, 'meta': meta}, f)
    os.replace(tmp, path)


def load_state(path):
    with open(path) as f:
        st = json.load(f)
    return st['k'], st['theta'], st.get('meta', {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--engine', default='./aether3')
    ap.add_argument('--state', default='/tmp/a3_spsa_all/state.json')
    ap.add_argument('--iters', type=int, default=800, help='total target k (resume-safe)')
    ap.add_argument('--chunk', type=int, default=20, help='summary cadence')
    ap.add_argument('--pairs', type=int, default=8, help='paired comparisons per iteration')
    ap.add_argument('--movetime', type=int, default=100)
    ap.add_argument('--workers', type=int, default=12)
    ap.add_argument('--seed', type=int, default=97531)
    ap.add_argument('--c-ratio', type=float, default=0.15,
                    help='perturbation c_i as fraction of (hi-lo), floored at 1')
    ap.add_argument('--r0', type=float, default=0.002,
                    help='initial step per unit signal as fraction of (hi-lo)')
    ap.add_argument('--alpha', type=float, default=0.602,
                    help='a_k = a_i / (1 + k/K)^alpha with K = iters/10 (Spall)')
    ap.add_argument('--hash', type=int, default=16,
                    help='per-engine Hash MB via setoption (0 = engine default)')
    args = ap.parse_args()

    workdir = os.path.dirname(os.path.abspath(args.state))
    os.makedirs(workdir, exist_ok=True)
    C = [max(1.0, args.c_ratio * (h - l)) for l, h in zip(LO, HI)]
    A = [args.r0 * (h - l) * 2.0 * c for l, h, c in zip(LO, HI, C)]
    K = max(1.0, args.iters / 10.0)
    pairs_csv = os.path.join(workdir, 'pairs.csv')
    log = os.path.join(workdir, 'tune.log')

    k, theta, meta = 0, list(DEFS), {}
    if os.path.exists(args.state):
        k, theta, meta = load_state(args.state)
        print(f'resumed from {args.state}: k={k}', flush=True)
    if len(theta) != len(PARAMS):
        print('state theta size mismatch — refusing to run', file=sys.stderr)
        sys.exit(1)
    if k >= args.iters:
        print(f'k={k} >= --iters {args.iters}; current params:')
        for n, v in env_assignments(theta):
            print(f'{n}={v}')
        return

    print(f'SPSA {len(PARAMS)} params, iters {k}->{args.iters}, '
          f'pairs={args.pairs} movetime={args.movetime}ms workers={args.workers} '
          f'c_ratio={args.c_ratio} r0={args.r0} alpha={args.alpha} K={K:.0f}', flush=True)
    for n_, l, h, c, a_ in zip(NAMES, LO, HI, C, A):
        print(f'  {n_:>15s} range [{l:.0f},{h:.0f}] c={c:5.1f} '
              f'unit-step@k0={a_ / (2.0 * c):6.3f}', flush=True)
    t0 = time.time()
    chunk_start, chunk_sig, chunk_games = k, [], 0
    try:
        while k < args.iters:
            rng = random.Random(args.seed * 1_000_003 + k)  # deterministic per k
            deltas = [1 if rng.random() < 0.5 else -1 for _ in PARAMS]
            vp = [clamp(t + ci * d, l, h) for t, ci, d, l, h in zip(theta, C, deltas, LO, HI)]
            vm = [clamp(t - ci * d, l, h) for t, ci, d, l, h in zip(theta, C, deltas, LO, HI)]

            cmd_p = engine_cmd(args.engine, workdir, vp, 'p')
            cmd_m = engine_cmd(args.engine, workdir, vm, 'm')
            w, l, d, _, _ = M.run_pairing(
                cmd_p, 'plus', cmd_m, 'minus', 2 * args.pairs, (5000, 50),
                args.workers, args.seed * 1_000_003 + k, pairs_csv,
                movetime=args.movetime,
                a_opts=({'Hash': args.hash} if args.hash else None),
                b_opts=({'Hash': args.hash} if args.hash else None))
            n = w + l + d
            yp = (w + 0.5 * d) / n
            dy = yp - (1.0 - yp)

            decay = (1.0 + k / K) ** args.alpha
            for i in range(len(PARAMS)):
                step = (A[i] / decay) * dy / (2.0 * C[i] * deltas[i])
                theta[i] = clamp(theta[i] + clamp(step, -C[i], C[i]), LO[i], HI[i])
            k += 1
            chunk_sig.append(dy)
            chunk_games += n
            save_state(args.state, k, theta,
                       {'seed': args.seed, 'movetime': args.movetime,
                        'pairs': args.pairs, 'engine': args.engine,
                        'c_ratio': args.c_ratio, 'r0': args.r0,
                        'alpha': args.alpha})

            if k % args.chunk == 0 or k == args.iters:
                el = time.time() - t0
                drift = sorted(
                    ((n_, (t - d_) / d_) for n_, t, d_ in zip(NAMES, theta, DEFS)),
                    key=lambda x: -abs(x[1]))[:6]
                msg = (f'[chunk {chunk_start}->{k}] {el/60:.1f}min games={chunk_games} '
                       f'signal={sum(chunk_sig)/len(chunk_sig):+.3f} '
                       f'theta: ' +
                       ' '.join(f'{n_}={int(round(t))}' for n_, t in zip(NAMES, theta)) +
                       ' | top drift: ' +
                       ' '.join(f'{n_}{p_*100:+.0f}%' for n_, p_ in drift))
                print(msg, flush=True)
                with open(log, 'a') as f:
                    f.write(msg + '\n')
                chunk_start, chunk_sig, chunk_games = k, [], 0
    except KeyboardInterrupt:
        print(f'\ninterrupted (state saved through k={k}); rerun same command to resume', flush=True)
        return

    print('final params:')
    for n, v in env_assignments(theta):
        print(f'{n}={v}')
    print('verify: fixed-node gate + timed gate vs current master before adopting', flush=True)


if __name__ == '__main__':
    main()

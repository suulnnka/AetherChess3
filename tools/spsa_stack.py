#!/usr/bin/env python3
"""SPSA tuner for AetherChess3 search constants (A3_STACK_PARAMS hook).

Chunked and resumable: state (iteration k + theta) is checkpointed after
EVERY iteration (atomic tmp+rename), and a compact summary is printed every
--chunk iterations (default 20). Stop any time (Ctrl-C / kill); rerun with
the same --state to continue from the last completed iteration, or raise
--iters on a later invocation to extend the annealing schedule.

Per iteration k: perturb all params +/-c_i, play 2*--pairs games
(+arm vs -arm, colors paired) via AetherChess2's match.py, then
    theta_i += a_k * (Y+ - Y-) / (2 c_i delta_i)
Fishtest-style per-param calibration (cf. sunfish tools/tune/spsa):
    c_i = c_ratio * (hi_i - lo_i)          (floored at 1 for integer knobs)
    a_i = r0 * (hi_i - lo_i) * 2 c_i       (initial step = r0 * range per unit signal)
    a_k = a_i / (1 + k/K)^alpha,  K = iters/10, alpha = 0.602 (Spall)
The +/-c_i step cap and theta clamping to bounds are safety rails only —
a correct calibration should never hit the cap (it binds above |dy| ~ 75).

Usage:
  spsa_search3.py --state st.json --iters 500 --chunk 20 --pairs 5 \
      --movetime 200 --workers 12
"""
import argparse, json, os, random, sys, time

A2TOOLS = '/home/a/chess/AetherChess2/tools'
sys.path.insert(0, A2TOOLS)
import match as M  # noqa: E402

# (name, default, c_rel, lo, hi) — ORDER MUST MATCH src/tunables.zig defs2.
# c_rel is historical (c is now c_ratio * range, built in main()); kept so the
# table still documents the old relative scales.
PARAMS = [
    ("sq_coef",    18, 0.12,   6,   40),
    ("sq_cap",     12, 0.15,   6,   20),
    ("se_depth",    7, 0.15,   4,   10),
    ("se_margin",  32, 0.15,   4,   48),
    ("se_vdiv",     2, 0.25,   2,    4),
    ("mvv_scale",  16, 0.12,   8,   32),
    ("qs_fut_margin", 155, 0.12, 60, 350),
]
NAMES = [p[0] for p in PARAMS]
DEFS = [float(p[1]) for p in PARAMS]
LO = [float(p[3]) for p in PARAMS]
HI = [float(p[4]) for p in PARAMS]
# c_i / a_i are built in main() from --c-ratio / --r0 (fishtest-style,
# anchored to each param's range width, not its default value).


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def fmt_params(theta):
    return ','.join(str(int(round(clamp(t, l, h)))) for t, l, h in zip(theta, LO, HI))


def engine_cmd(engine, workdir, vec, tag):
    wrapper = os.path.join(workdir, f'eng_{tag}.sh')
    with open(wrapper, 'w') as f:
        f.write('#!/bin/sh\nexec env A3_STACK_PARAMS="%s" %s "$@"\n'
                % (fmt_params(vec), os.path.abspath(engine)))
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
    ap.add_argument('--engine', default='/tmp/a3_stack')
    ap.add_argument('--state', default='/tmp/a3_spsa_stack/state.json')
    ap.add_argument('--iters', type=int, default=500, help='total target k (resume-safe)')
    ap.add_argument('--chunk', type=int, default=20, help='summary cadence')
    ap.add_argument('--pairs', type=int, default=5, help='paired comparisons per iteration')
    ap.add_argument('--movetime', type=int, default=200)
    ap.add_argument('--workers', type=int, default=12)
    ap.add_argument('--seed', type=int, default=4242)
    ap.add_argument('--c-ratio', type=float, default=0.15,
                    help='perturbation c_i as fraction of (hi-lo), floored at 1')
    ap.add_argument('--r0', type=float, default=0.002,
                    help='initial step per unit signal as fraction of (hi-lo)')
    ap.add_argument('--alpha', type=float, default=0.602,
                    help='a_k = a_i / (1 + k/K)^alpha with K = iters/10 (Spall)')
    ap.add_argument('--hash', type=int, default=0,
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
        print('A3_STACK_PARAMS=' + fmt_params(theta))
        return

    print(f'SPSA {len(PARAMS)} params, iters {k}->{args.iters}, '
          f'pairs={args.pairs} movetime={args.movetime}ms workers={args.workers} '
          f'c_ratio={args.c_ratio} r0={args.r0} alpha={args.alpha} K={K:.0f}', flush=True)
    for n_, l, h, c, a_ in zip(NAMES, LO, HI, C, A):
        print(f'  {n_:>15s} range [{l:.0f},{h:.0f}] c={c:5.1f} '
              f'unit-step@k0={a_ / (2.0 * c):6.3f}', flush=True)
    t0 = time.time()
    chunk_start, chunk_sig = k, []
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
            save_state(args.state, k, theta,
                       {'seed': args.seed, 'movetime': args.movetime,
                        'pairs': args.pairs, 'engine': args.engine,
                        'c_ratio': args.c_ratio, 'r0': args.r0,
                        'alpha': args.alpha})

            if k % args.chunk == 0 or k == args.iters:
                el = time.time() - t0
                msg = (f'[chunk {chunk_start}->{k}] {el/60:.1f}min '
                       f'signal={sum(chunk_sig)/len(chunk_sig):+.3f} '
                       f'theta: ' +
                       ' '.join(f'{n_}={int(round(t))}' for n_, t in zip(NAMES, theta)))
                print(msg, flush=True)
                with open(log, 'a') as f:
                    f.write(msg + '\n')
                chunk_start, chunk_sig = k, []
    except KeyboardInterrupt:
        print(f'\ninterrupted at k={k - 1 if chunk_sig else k} '
              f'(state saved through k={k}); rerun same command to resume', flush=True)
        return

    print('A3_STACK_PARAMS=' + fmt_params(theta))
    print('verify: fixed-node gate + timed gate vs current master before adopting',
          flush=True)


if __name__ == '__main__':
    main()

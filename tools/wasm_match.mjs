// A3-wasm vs 参照 wasm 的进程内对打(冒烟)。
// 用法:AEther_REF=/path/to/ref.wasm node tools/wasm_match.mjs [games]
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const REF = process.env.AETHER_REF ?? '';
if (!REF || !existsSync(REF)) { console.log('需要 AETHER_REF 指向参照 wasm'); process.exit(2); }
const load = (p) => new WebAssembly.Instance(new WebAssembly.Module(readFileSync(p)), {}).exports;
const A = load(join(ROOT, 'wasm/chess.wasm'));
const B = load(REF);
const GAMES = parseInt(process.argv[2] ?? '10', 10);
const wire = (m) => ((m & 63) << 6) | ((m >> 6) & 63);
let w = 0, l = 0, d = 0;
for (let g = 0; g < GAMES; g++) {
  const engs = g % 2 === 0 ? [A, B] : [B, A];
  const moves = [];
  let seed = 1000 + g * 7919, result = null;
  for (let ply = 0; ply < 300 && !result; ply++) {
    const X = engs[ply % 2];
    const buf = new Int32Array(X.memory.buffer, X.engineMovesBuf(), 512);
    moves.forEach((m,i) => buf[i] = m);
    if (X.engineLoad(moves.length) !== 1) { result = 'load-err'; break; }
    X.engineState();
    if (X.engineOver() === 1) { result = X.engineResult() === 1 ? (ply % 2 === 1 ? 'W' : 'B') : 'D'; break; }
    let mv = X.engineBookMove(++seed, 0);
    if (!mv) mv = X.engineThink(0, 40000, 0, ++seed);
    if (!mv) { result = 'nomove'; break; }
    moves.push(wire(mv));
  }
  const aIsWhite = g % 2 === 0;
  const aWon = result === 'W' ? aIsWhite : result === 'B' ? !aIsWhite : false;
  if (result === 'D' || result == null) d++;
  else if (aWon) w++; else l++;
}
console.log(`aether3 vs ref: ${w}-${l}-${d}`);

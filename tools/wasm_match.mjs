// A3-wasm vs AetherChess-wasm, in-process match: book until exhausted, then think(0, 40k nodes)
import { readFileSync } from 'node:fs';
const load = (p) => new WebAssembly.Instance(new WebAssembly.Module(readFileSync(p)), {}).exports;
const A = load('/home/a/chess/AetherChess3/zig-out/bin/chess.wasm');
const B = load('/home/a/chess/AetherChess/wasm/chess.wasm');
const NAMES = ['aether3-wasm', 'aetherchess-wasm'];
const wire = (m) => ((m & 63) << 6) | ((m >> 6) & 63); // full code → line (from<<6|to)
let w=0,l=0,d=0;
for (let g = 0; g < 10; g++) {
  const engs = g % 2 === 0 ? [A, B] : [B, A];   // engs[0] plays White
  const moves = [];
  let seed = 1000 + g * 7919;
  let result = null;
  for (let ply = 0; ply < 300 && !result; ply++) {
    const X = engs[ply % 2];
    const buf = new Int32Array(X.memory.buffer, X.engineMovesBuf(), 512);
    moves.forEach((m,i) => buf[i] = m);
    if (X.engineLoad(moves.length) !== 1) { result = 'load-err'; break; }
    X.engineState();
    if (X.engineOver() === 1) {
      result = X.engineResult() === 1 ? (ply % 2 === 1 ? 'W' : 'B') : 'D';
      if (X.engineResult() !== 1) result += ['','mate','stale','material','threefold'][X.engineResult()];
      break;
    }
    let mv = X.engineBookMove(++seed, 0);
    if (!mv) mv = X.engineThink(0, 40000, 0, ++seed);
    if (!mv) { result = 'nomove'; break; }
    moves.push(wire(mv));
  }
  if (result === null || result === 'D' || (typeof result === 'string' && result.startsWith('D'))) d++;
  else if (result === 'W') w++; else l++;
  console.log(`game ${g+1}: ${result} @${moves.length}ply  [${NAMES[0]} white]`);
}
console.log(`\n${NAMES[0]} (aether3) vs ${NAMES[1]}: ${w}-${l}-${d}`);

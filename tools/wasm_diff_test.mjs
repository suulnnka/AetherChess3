// wasm 契约自检 + 可选差分对拍。
// 用法:node tools/wasm_diff_test.mjs
//   默认:对 wasm/chess.wasm 跑自检(合法性/终局/杀棋/perft 标准值/谱库确定性)。
//   对拍:AEATHER_REF=/path/to/reference.wasm node tools/wasm_diff_test.mjs
//     (参照引擎默认用 AetherChess 原版 wasm;提供时加跑状态/合法表/
//      perft/开局库的逐位一致性对拍)
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => new WebAssembly.Instance(new WebAssembly.Module(readFileSync(p)), {}).exports;
const sq = (s) => (8 - parseInt(s[1])) * 8 + (s.charCodeAt(0) - 97);   // algebraic → A8=0
const line = (m) => (sq(m.slice(0,2)) << 6) | sq(m.slice(2,4));
let fails = 0;
const chk = (name, ok, detail='') => { if (!ok) { fails++; console.log(`FAIL ${name} ${detail}`); } };

const A = load(join(ROOT, 'wasm/chess.wasm'));
const loadMoves = (X, moves) => {
  const buf = new Int32Array(X.memory.buffer, X.engineMovesBuf(), 512);
  moves.forEach((m,i) => buf[i] = line(m));
  return X.engineLoad(moves.length);
};
const state = (X) => {
  X.engineState();
  const legal = Array.from(new Int32Array(X.memory.buffer, X.engineLegalPtr(), X.engineLegalCount())).sort((a,b)=>a-b);
  const brd = Array.from(new Int8Array(X.memory.buffer, X.engineBoardPtr(), 64));
  return { stm: X.engineStm(), check: X.engineCheck(), over: X.engineOver(), legal, brd };
};

// ---------- 自检(始终执行) ----------
A.engineInit();
chk('init', A.engineInit() === 0);
const s0 = state(A);
chk('startpos 20 legal', s0.legal.length === 20, `${s0.legal.length}`);
chk('startpos 32 men', s0.brd.filter(p => p).length === 32);
chk('startpos white to move', s0.stm === 0 && s0.check === 0 && s0.over === 0);
for (const [d, want] of [[1,20],[2,400],[3,8902],[4,197281]]) {
  loadMoves(A, []);
  const n = BigInt(A.enginePerft(d) >>> 0) + BigInt(A.enginePerftHi() >>> 0) * 4294967296n;
  chk(`perft(${d})=${want}`, n === BigInt(want), `got ${n}`);
}
loadMoves(A, ['f2f3','e7e5','g2g4']);
const mv = A.engineThink(6, 0, 0, 1);
chk('mate-in-1 = d8h4', (mv & 63) === sq('d8') && ((mv >> 6) & 63) === sq('h4'));
chk('mate score', A.engineScore() > 25000, `${A.engineScore()}`);
loadMoves(A, ['f2f3','e7e5','g2g4','d8h4']); A.engineState();
chk('mate detected', A.engineOver() === 1 && A.engineResult() === 1 && A.engineWinner() === 1);
loadMoves(A, []);
const ev = A.engineEvalCp();
chk('eval sane', Math.abs(ev) < 100, `${ev}`);
loadMoves(A, []);
const b1 = A.engineBookMove(12345, 0), b2 = A.engineBookMove(12345, 0);
chk('book deterministic', b1 !== 0 && b1 === b2);
chk('book candidates>0', A.engineBookCands() > 0);
console.log(`自检: ${fails === 0 ? 'PASS' : fails + ' FAIL'}`);

// ---------- 差分对拍(提供参照时执行) ----------
const REF = process.env.AETHER_REF ?? '';
if (REF && existsSync(REF)) {
  const B = load(REF);
  B.engineInit();
  const lines = [[], ['e2e4'], ['e2e4','e7e5','g1f3'],
    ['d2d4','d7d5','c2c4','e7e6','b1c3','g8f6'], ['f2f3','e7e5','g2g4']];
  for (const l of lines) {
    loadMoves(A, l); loadMoves(B, l);
    const a = state(A), b = state(B);
    chk(`state@${l.length}`, JSON.stringify([a.stm,a.check,a.over,a.legal,a.brd]) === JSON.stringify([b.stm,b.check,b.over,b.legal,b.brd]));
  }
  let same = 0, total = 0;
  for (const l of [[], ['e2e4'], ['d2d4','d7d5'], ['e2e4','c7c5'], ['g1f3','g8f6','c2c4'],
                   ['e2e4','e7e5','g1f3','b8c6','f1b5'], ['d2d4','g8f6','c2g4']]) {
    loadMoves(A, l); loadMoves(B, l);
    const ca = A.engineBookCands(), cb = B.engineBookCands();
    const va = Array.from(new Int32Array(A.memory.buffer, A.engineBookCandPtr(), ca*3));
    const vb = Array.from(new Int32Array(B.memory.buffer, B.engineBookCandPtr(), cb*3));
    chk(`bookcands@${l.length}`, JSON.stringify(va) === JSON.stringify(vb));
    for (let seed = 1; seed <= 40; seed++) {
      total++;
      if (A.engineBookMove(seed, 0) === B.engineBookMove(seed, 0)) same++;
      else chk(`bookpick@${l.length}/s${seed}`, false);
    }
  }
  console.log(`对拍: 开局库 ${same}/${total} 同选, ${fails === 0 ? 'PASS' : fails + ' FAIL'}`);
} else {
  console.log('(未设 AETHER_REF,跳过差分对拍)');
}
process.exit(fails ? 1 : 0);

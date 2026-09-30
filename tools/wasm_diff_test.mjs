// Differential test: AetherChess3 wasm vs AetherChess wasm (same protocol)
import { readFileSync } from 'node:fs';
const load = (p) => {
  const mod = new WebAssembly.Module(readFileSync(p));
  return new WebAssembly.Instance(mod, {}).exports;
};
const A = load('/home/a/chess/AetherChess3/zig-out/bin/chess.wasm');   // new
const B = load('/home/a/chess/AetherChess/wasm/chess.wasm');           // reference
const sq = (s) => (8 - parseInt(s[1])) * 8 + (s.charCodeAt(0) - 97);   // algebraic → A8=0
const line = (m) => (sq(m.slice(0,2)) << 6) | sq(m.slice(2,4));
const loadMoves = (X, moves) => {
  const buf = new Int32Array(X.memory.buffer, X.engineMovesBuf(), 512);
  moves.forEach((m,i) => buf[i] = line(m));
  return X.engineLoad(moves.length);
};
let fails = 0;
const chk = (name, ok, detail='') => { if (!ok) { fails++; console.log(`FAIL ${name} ${detail}`); } };

// 1) startpos state
for (const [name, X] of [['A3', A], ['ref', B]]) X.engineInit();
const state = (X) => {
  X.engineState();
  const legal = Array.from(new Int32Array(X.memory.buffer, X.engineLegalPtr(), X.engineLegalCount())).sort((a,b)=>a-b);
  const brd = Array.from(new Int8Array(X.memory.buffer, X.engineBoardPtr(), 64));
  return { stm: X.engineStm(), check: X.engineCheck(), over: X.engineOver(), legal, brd };
};
const s0 = state(A), s1 = state(B);
chk('startpos-stm', s0.stm === s1.stm);
chk('startpos-legal', JSON.stringify(s0.legal) === JSON.stringify(s1.legal), `${s0.legal.length} vs ${s1.legal.length}`);
chk('startpos-board', JSON.stringify(s0.brd) === JSON.stringify(s1.brd));
console.log(`startpos: legal=${s0.legal.length} (ref ${s1.legal.length}), board ok=${JSON.stringify(s0.brd)===JSON.stringify(s1.brd)}`);

// 2) states after several lines
const lines = [
  [], ['e2e4'], ['e2e4','e7e5','g1f3'], ['d2d4','d7d5','c2c4','e7e6','b1c3','g8f6'],
  ['e2e4','c7c5','g1f3','d7d6','d2d4','c5d4','f3d4','g8f6','b1c3','a7a6'],
  ['f2f3','e7e5','g2g4'],
];
for (const mv of lines) {
  chk(`load ${mv.length}`, loadMoves(A, mv) === 1 && loadMoves(B, mv) === 1);
  const a = state(A), b = state(B);
  chk(`state@${mv.length}`, JSON.stringify([a.stm,a.check,a.over,a.legal]) === JSON.stringify([b.stm,b.check,b.over,b.legal]));
}
// 3) perft
for (const d of [1,2,3,4]) {
  loadMoves(A, []); loadMoves(B, []);
  const pa = BigInt(A.enginePerft(d) >>> 0) + BigInt(A.enginePerftHi() >>> 0) * 4294967296n;
  const pb = BigInt(B.enginePerft(d) >>> 0) + BigInt(B.enginePerftHi() >>> 0) * 4294967296n;
  chk(`perft(${d})`, pa === pb, `${pa} vs ${pb}`);
  console.log(`perft(${d}) = ${pa} (ref ${pb})`);
}
// 4) book parity: same seed → same move, many positions/seeds
let bookN = 0, bookSame = 0;
for (const mv of [[], ['e2e4'], ['d2d4','d7d5'], ['e2e4','c7c5'], ['g1f3','g8f6','c2c4'],
                  ['e2e4','e7e5','g1f3','b8c6','f1b5'],['d2d4','g8f6','c2g4']]) {
  loadMoves(A, mv); loadMoves(B, mv);
  const ca = A.engineBookCands(), cb = B.engineBookCands();
  const va = Array.from(new Int32Array(A.memory.buffer, A.engineBookCandPtr(), ca*3));
  const vb = Array.from(new Int32Array(B.memory.buffer, B.engineBookCandPtr(), cb*3));
  chk(`bookcands@${mv.length}`, JSON.stringify(va) === JSON.stringify(vb));
  for (let seed = 1; seed <= 40; seed++) {
    const ma = A.engineBookMove(seed, 0), mb = B.engineBookMove(seed, 0);
    bookN++;
    if (ma === mb) bookSame++;
    else chk(`bookmove@${mv.length}/s${seed}`, false, `A3=${ma} ref=${mb}`);
  }
}
console.log(`book: ${bookSame}/${bookN} identical picks`);
// 5) think: legality + mate in 1 (1.f3 e5 2.g4 → Qh4#)
loadMoves(A, ['f2f3','e7e5','g2g4']);
A.engineState();
const mv = A.engineThink(6, 0, 0, 1);
const mfrom = mv & 63, mto = (mv >> 6) & 63;
console.log(`think mate-in-1: move=${mv} (from=${mfrom} to=${mto}) score=${A.engineScore()} nodes=${A.engineNodesLo()>>>0} depth=${A.engineDepth()}`);
chk('mate-in-1 = Qh4#', mfrom === sq('d8') && mto === sq('h4'));
chk('mate score', A.engineScore() > 25000, `score=${A.engineScore()}`);
// after Qh4#: state should be mate
loadMoves(A, ['f2f3','e7e5','g2g4','d8h4']);
A.engineState();
chk('mate detected', A.engineOver() === 1 && A.engineResult() === 1 && A.engineWinner() === 1);
// 6) eval sane
loadMoves(A, []);
const ev = A.engineEvalCp();
chk('evalCp small', Math.abs(ev) < 100, `ev=${ev}`);
console.log(`evalCp startpos = ${ev}`);
console.log(fails === 0 ? '\nALL PASS' : `\n${fails} FAILURES`);
process.exit(fails ? 1 : 0);

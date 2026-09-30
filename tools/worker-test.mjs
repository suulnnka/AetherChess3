#!/usr/bin/env node
/* ============================================================
 * worker 契约测试:在 Node 里垫起 self/postMessage/fetch,完整驱动
 * src/worker.js(zig/wasm 通道)的消息链路 —— probe-wasm 对拍的是引擎 ABI,
 * 这里补的是**胶水层**:levels 不触发加载、state 的字段形状、think 的
 * 搜索回包、开局库命中路径(engineBind 绑定)。
 *
 * 用法:node tools/worker-test.mjs
 * ============================================================ */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/* ---- 浏览器环境垫片 ---- */
const queue = [];
const waiters = [];
globalThis.self = globalThis;
globalThis.postMessage = (msg) => {
  if (waiters.length) waiters.shift()(msg);
  else queue.push(msg);
};
/* Node 的 fetch 不认 file://,垫一层读盘(本测试只会取 wasm 一个 file URL) */
globalThis.fetch = async (url) => {
  const data = fs.readFileSync(fileURLToPath(String(url)));
  return { ok: true, status: 200, arrayBuffer: async () => data };
};

await import(pathToFileURL(path.join(ROOT, 'src/worker.js')).href);
const send = (data) => self.onmessage({ data });
const nextMsg = () => queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r));

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log('  ✓ ' + msg); }
  else { fail++; console.log('  ✗ ' + msg); }
};

/* ---- levels:纯声明,不加载 wasm ---- */
send({ type: 'levels' });
{
  const m = await nextMsg();
  ok(m.type === 'levels' && m.tag === 'aether3-engine-v1' && m.engine === 'wasm', 'levels 回包带 tag/engine');
  ok(Array.isArray(m.levels) && m.levels.length === 7 && m.default === 3, `难度表 ${m.levels.length} 档,默认 ${m.default}`);
}

/* ---- ping:强制加载 wasm ---- */
send({ type: 'ping' });
{
  const m = await nextMsg();
  ok(m.type === 'pong' && m.engine === 'wasm' && !m.error, `pong(wasm 就绪,起始评估 ${m.evalCp})`);
}

/* ---- state:起始局面 ---- */
send({ type: 'state', id: 1, moves: [] });
{
  const m = await nextMsg();
  ok(m.type === 'state' && m.id === 1 && !m.error, 'state 回包无错');
  ok(m.legal.length === 20 && m.stm === 0 && m.check === false && m.over === false, '起始:20 个合法着法,白行棋,无将军');
  ok(m.board.filter((p) => p).length === 32, '起始棋盘 32 子');
}

/* ---- state:走几步后的局面(e2e4 e7e5 g1f3 → 黑方 29 个着法)---- */
const sq = (s) => 'abcdefgh'.indexOf(s[0]) + (8 - +s[1]) * 8;
const line = (a, b) => (sq(a) << 6) | sq(b);
send({ type: 'state', id: 2, moves: [line('e2', 'e4'), line('e7', 'e5'), line('g1', 'f3')] });
{
  const m = await nextMsg();
  ok(m.id === 2 && m.stm === 1 && m.legal.length === 29, '三步后黑方 29 个着法');
}

/* ---- state:非法序列 ---- */
send({ type: 'state', id: 3, moves: [line('e2', 'e5')] });
{
  const m = await nextMsg();
  ok(m.id === 3 && m.error === 'illegal-sequence', '非法序列报错');
}

/* ---- think:开局库命中(e2e4 开局)---- */
send({ type: 'think', id: 10, moves: [], level: 2 });
{
  const m = await nextMsg();
  ok(m.id === 10 && m.book === true && typeof m.name === 'string', `开局库命中:${m.name ?? '(无名谱线)'} ${m.depth === 0 ? 'depth=0' : ''}`);
  ok(/[一-鿿]/.test(m.name || ''), '默认语言是中文(族名含汉字)');
  ok(m.move !== 0 && (m.move >> 6) !== (m.move & 63), '书着是完整编码');
}

/* lang:'en' → 英文族名 */
send({ type: 'think', id: 13, moves: [], level: 2, lang: 'en' });
{
  const m = await nextMsg();
  ok(m.id === 13 && m.book === true && !/[一-鿿]/.test(m.name || ''), `lang:'en' 回英文族名(${m.name})`);
}

/* ---- think:谱外进搜索(2.Ke2 王前冲,任何 ECO 谱线都不含)---- */
const opening = [line('e2', 'e4'), line('e7', 'e5'), line('e1', 'e2')];
send({ type: 'think', id: 11, moves: opening, level: 3 });
{
  const m = await nextMsg();
  ok(m.id === 11 && !m.book && m.move !== 0 && m.depth >= 3 && m.nodes > 1000, `搜索回包:depth=${m.depth} nodes=${m.nodes} ms=${m.ms}`);
}

/* ---- think:jitter 低档(easy)在池内随机 ---- */
send({ type: 'think', id: 12, moves: opening, level: 1 });
{
  const m = await nextMsg();
  ok(m.id === 12 && m.move !== 0, `easy 档回着(depth=${m.depth},score=${m.score})`);
}

console.log(`\nworker 契约测试:${pass} 通过,${fail} 失败`);
if (fail) process.exit(1);
console.log('✓ worker 胶水层契约全部符合');

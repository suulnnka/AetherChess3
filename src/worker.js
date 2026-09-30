/* ============================================================
 * AI Worker:引擎的唯一门面(UI 不 import 引擎源码,一切经消息)—— **zig/wasm**
 *
 *   ping                     → { type:'pong', tag, engine, evalCp }
 *                              (顺带强制加载 wasm:回包里能证明引擎真起来了)
 *   { type:'levels' }        → { type:'levels', tag, engine, default, levels }
 *                              纯声明难度表(内联数据),不触发任何加载
 *   { type:'state', id, moves }
 *                            → { type:'state', id, board, stm, legal, check,
 *                                over, result, winner }
 *                              规则查询的单一入口:重演序列后回报棋盘、行棋方全部
 *                              合法着法、将军态与终局判定。legal 编码 (from<<6|to),
 *                              升变只留升后
 *   { type:'think', id, moves, level }
 *                            → { id, move, depth, nodes, ms, score }
 *                            → 开局命中 { id, move, book: true, name, depth: 0, ... }
 *                              level 是**本引擎难度表的下标**(表由 levels 自报)
 *
 * moves 是 (from<<6|to) 的走法序列 —— 传序列而不是传棋盘:
 * 结构化克隆最省,编码只有一套,不存在两条解析路径。
 *
 * 分工:**规则/评估/搜索/开局谱库全在 wasm 里**(engineLoad 重演 →
 * engineState 查询 → engineThink 搜索 → engineBookMove 应谱)。JS 参照实现
 * (rules/eval/ai/book/levels)已于 2026-09 移除 —— 仓库里没有第二份引擎,
 * 不存在两条实现路径吵架;跨实现对拍闸门由 zig 原生测试接替
 * (zig build test / selftest,见 tools/build-wasm.mjs 的产物关卡)。
 * 谱库是编译期嵌入的二进制 blob(wasm/chess.wasm 数据段,src/zig/book.zig
 * @embedFile book.bin);JS 侧只剩本门面 + 内联难度表。
 *
 * wasm 没有墙钟,难度档的 ms 字段在 think 路径不生效 —— 节点预算是主约束,
 * wasm 下每档的耗时只会更短不会更长。
 *
 * 搜索是同步的,Worker 收到新消息只会排队;UI 侧用请求序号丢弃过期结果,
 * 需要真正中断时直接 terminate 再造一个(见 webos 应用的 abortEngine)。
 * ============================================================ */

/* 难度档:纯数据(节点预算按机器标定,见 git 历史里 src/levels.js 的口径注释)。
 * 原独立文件随 JS 参照实现一起移除 —— 本 worker 是 wasm 的唯一门面,直接内联。 */
/* AetherChess3(NNUE)难度表 —— 按 wasm 实测标定(~1.2M nps,无 jitter 概念,
 * 弱档靠深度/节点硬压)。实测(1.e4 e5):
 * d1/d2/d3 深度帽;15k≈d8(13ms)/ 60k≈d10(46ms)/ 250k≈d13(0.2s)/
 * 900k≈d16(0.7s)/ 3M≈d19(2.4s)。 */
const LEVELS = [
  { id: 'beginner', name: '入门', depth: 1, jitter: 0, nodes: 1000, ms: 100 },
  { id: 'easy', name: '初级', depth: 3, jitter: 0, nodes: 4000, ms: 200 },
  { id: 'normal', name: '中级', depth: 24, jitter: 0, nodes: 15000, ms: 400 },
  { id: 'strong', name: '高级', depth: 24, jitter: 0, nodes: 60000, ms: 700 },
  { id: 'hard', name: '大师', depth: 24, jitter: 0, nodes: 250000, ms: 1200 },
  { id: 'master', name: '宗师', depth: 24, jitter: 0, nodes: 900000, ms: 2500 },
  { id: 'gm', name: '特级大师', depth: 24, jitter: 0, nodes: 3000000, ms: 6000 },
];
const DEFAULT_LEVEL = 3; // 高级

/* ENGINE_TAG 让下游 webos 的体积闸门(check-size.mjs)能在 dist 里认出这个
 * chunk(字符串不会被压缩改名)。开局库数据内嵌在 wasm(book.bin)里,计入预算。 */
const ENGINE_TAG = 'aether3-engine-v1';
self.__engineTag = ENGINE_TAG;

/* 相对本文件的静态 URL:Vite 会改写成带 hash 的产物路径,原生浏览器
 * (直接跑模块 Worker)下也能按相对路径取到 —— 不写 ?url 是为了不把引擎
 * 仓库绑死在打包器上。 */
const WASM_URL = new URL('../wasm/chess.wasm', import.meta.url);

/* wasm 状态码 → UI/契约字符串(result 与 JS 版 describeState 同名同义) */
const RESULT_NAME = ['', 'mate', 'stale', 'material', 'threefold'];

let booting = null;

/** 懒加载 + 只实例化一次。引擎内部是全局状态,本来就是「一个 Worker 一个引擎」。 */
function boot() {
  if (!booting) {
    booting = (async () => {
      const res = await fetch(WASM_URL);
      if (!res.ok) throw new Error(`chess.wasm HTTP ${res.status}`);
      /* arrayBuffer + instantiate 而不是 instantiateStreaming:几十 KB 的产物
       * 流式编译省不下什么,却要对 Content-Type 提心吊胆(静态服务器/CDN
       * 常配错),失败回退还要再发一次请求。 */
      const { instance } = await WebAssembly.instantiate(await res.arrayBuffer(), {});
      const X = instance.exports;
      const st = X.engineInit();
      if (st !== 0) throw new Error(`engineInit 失败(码 ${st})`);
      return X;
    })().catch((err) => { booting = null; throw err; });   // 失败不缓存,下次可重试
  }
  return booting;
}

/** 把 (from<<6|to) 序列写进 wasm 输入缓冲并重演;false = 序列非法 */
function loadMoves(X, moves) {
  const view = new Int32Array(X.memory.buffer, X.engineMovesBuf(), moves.length);
  for (let i = 0; i < moves.length; i++) view[i] = moves[i];
  return X.engineLoad(moves.length) === 1;
}

function handle(d) {
  if (d && d.type === 'ping') {
    /* ping 走 boot():回包带上 wasm 就绪证据与起始评估,「Worker 活着」与
     * 「wasm 取到并初始化成功」一次问清。 */
    boot()
      .then((X) => {
        X.engineLoad(0);
        self.postMessage({ type: 'pong', tag: ENGINE_TAG, engine: 'wasm', evalCp: X.engineEvalCp() });
      })
      .catch((err) => self.postMessage({ type: 'pong', tag: ENGINE_TAG, engine: 'wasm', error: String((err && err.message) || err) }));
    return;
  }

  if (d.type === 'levels') {
    /* 故意不 boot():UI 建难度下拉不该被 wasm 取没取到绑住 —— 引擎起不来时
     * 下拉至少还在,报错交给 ping / think 那条路去报到状态栏。 */
    self.postMessage({
      type: 'levels', tag: ENGINE_TAG, engine: 'wasm',
      default: DEFAULT_LEVEL, levels: LEVELS,
    });
    return;
  }

  if (d.type === 'state') {
    boot().then((X) => {
      if (!loadMoves(X, d.moves)) {
        self.postMessage({ type: 'state', id: d.id, error: 'illegal-sequence' });
        return;
      }
      X.engineState();
      const board = Array.from(new Int8Array(X.memory.buffer, X.engineBoardPtr(), 64));
      const legal = Array.from(new Int32Array(X.memory.buffer, X.engineLegalPtr(), X.engineLegalCount()));
      self.postMessage({
        type: 'state', id: d.id, tag: ENGINE_TAG,
        board,                                   // p = 颜色<<3 | 型;0 = 空
        stm: X.engineStm(),
        legal,
        check: X.engineCheck() === 1,
        over: X.engineOver() === 1,
        result: X.engineOver() === 1 ? RESULT_NAME[X.engineResult()] : null,
        winner: X.engineWinner(),
      });
    }).catch((err) => self.postMessage({ type: 'state', id: d.id, error: String((err && err.message) || err) }));
    return;
  }

  /* think 是缺省分支:应用侧发 {id, moves, level}(不带 type),与 JS 版
   * worker 的「非 ping/levels/state 一律当 think」语义保持一致。 */
  const t0 = Date.now();
  boot().then((X) => {
    if (!loadMoves(X, d.moves)) {
      self.postMessage({ id: d.id, error: 'illegal-sequence' });
      return;
    }
    /* 开局库优先:命中谱着直接回着,不再搜索。谱库是**编译期嵌进 wasm 的
     * 二进制 blob**(src/zig/book.bin,book.zig @embedFile),
     * 走谱/加权抽取/绑定(升后优先)/开局族名全在引擎侧;谱着在当前局面
     * 不合法时引擎回 0,回落搜索。 */
    /* 开局族名双语:blob 每族存英/中两条,lang 选显示语言(0=英文 1=中文)。
     * 应用侧可在 think 请求里带 lang: 'en'|'zh',缺省中文(UI 中文为主)。 */
    const lang = d.lang === 'en' ? 0 : 1;
    const bm = X.engineBookMove((Math.random() * 4294967296) >>> 0, lang);
    if (bm) {
      const len = X.engineBookNameLen();
      const name = len > 0
        ? new TextDecoder().decode(new Uint8Array(X.memory.buffer, X.engineBookNamePtr(), len))
        : null;
      self.postMessage({ id: d.id, move: bm, book: true, name, depth: 0, nodes: 0, ms: Date.now() - t0, score: 0 });
      return;
    }
    const lv = LEVELS[d.level] ?? LEVELS[DEFAULT_LEVEL] ?? LEVELS[0];
    /* 难度的 nodes/depth/jitter 原样传入;ms 兜底在 wasm 里不存在(wasm 没有
     * 墙钟,节点预算是硬上限,耗时只会更短)。jitter 档的随机源在这里播种,
     * 每次调用不同 —— 弱得可控但不重复。 */
    const mv = X.engineThink(lv.depth, lv.nodes, lv.jitter | 0, (Math.random() * 4294967296) >>> 0);
    const nodes = (X.engineNodesLo() >>> 0) + (X.engineNodesHi() >>> 0) * 4294967296;
    self.postMessage({
      id: d.id,
      move: mv,
      depth: X.engineDepth(),
      nodes,
      ms: Date.now() - t0,
      score: X.engineScore(),
    });
  }).catch((err) => self.postMessage({ id: d.id, error: String((err && err.message) || err) }));
}

self.onmessage = (e) => handle(e.data);

/* ============================================================
 * 国际象棋在线对弈页 —— UI 移植自 AetherWebOS 国际象棋应用的 2D 视图
 * (js/apps/chess3d/index.js + pieces2d.js),布局与交互保持一致:
 * 顶栏「新对局 / 难度 / 人机 / 换边 / 悔棋」+ 中央棋盘 +
 * 底栏左侧行棋状态、右侧等宽字体引擎搜索信息。
 *
 * 引擎即本仓库的主角:src/worker.js(zig → chess.wasm 通道)。
 * 规则/评估/搜索/开局谱库全在 wasm 里:UI 持有的唯一对局状态是
 * **走法序列**(线格式 from<<6|to),走子 / 悔棋 / 新对局都只是改序列
 * 再向 Worker 要一次 state 回包,拿回棋盘与合法着法重画。
 *
 * 协议要点:think 回包的 move 是引擎打包编码(from 在低 6 位),
 * 转回线格式才能进序列;开局库命中时回包带 book/name,引擎直接给谱着。
 * ============================================================ */

/* ==================== 微型工具(替代 webos 的 core)==================== */
const $ = (sel) => document.querySelector(sel);

/** 建 DOM:el('button', {class, onClick, dataset}, ...children) */
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue;
    if (k === 'class') node.className = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'style' && typeof v === 'object') Object.assign(node.style, v);
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

/** 线性图标(路径数据取自 webos 的 core/icons.js) */
const ICON_PATHS = {
  refresh: '<path d="M21 12a9 9 0 1 1-2.64-6.36L21 8"/><path d="M21 3v5h-5"/>',
  reply: '<polyline points="9 17 4 12 9 7"/><path d="M20 18v-2a4 4 0 0 0-4-4H4"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
  moon: '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>',
};
const icon = (name) => {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('fill', 'none');
  s.setAttribute('stroke', 'currentColor');
  s.setAttribute('stroke-width', '2');
  s.setAttribute('stroke-linecap', 'round');
  s.setAttribute('stroke-linejoin', 'round');
  s.setAttribute('aria-hidden', 'true');
  s.innerHTML = ICON_PATHS[name] || '';
  return s;
};

/** webos dialogs.info 的页内替身 */
const dlg = $('#dlg');
function showDialog({ title, message }) {
  $('#dlgTitle').textContent = title;
  $('#dlgMsg').textContent = message;
  if (!dlg.open) dlg.showModal();
}
$('#dlgOk').addEventListener('click', () => dlg.close());
dlg.addEventListener('click', (e) => { if (e.target === dlg) dlg.close(); });

/** webos bus.notify 的页内替身:右下角吐司 */
function toast(text) {
  const t = el('div', { class: 'toast' }, text);
  t.addEventListener('click', () => t.remove());
  $('#toasts').append(t);
  setTimeout(() => { t.classList.add('out'); setTimeout(() => t.remove(), 220); }, 3200);
}

/** 主题:webos 的浅 / 深双主题,记在 localStorage */
const themeBtn = $('#themeBtn');
function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeBtn.replaceChildren(icon(theme === 'dark' ? 'sun' : 'moon'));
  try { localStorage.setItem('aether-pages-theme', theme); } catch {}
}
applyTheme((() => {
  try { return localStorage.getItem('aether-pages-theme') || 'dark'; } catch { return 'dark'; }
})());
themeBtn.addEventListener('click', () =>
  applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'));

const setTitle = (t) => { $('#winTitle').textContent = t; };

/* ==================== 2D 棋子 ====================
 * classic 赛用造型(参照 Wikimedia 的经典 Cburnett 一套,移植自
 * webos 应用同款 pieces2d.js):白子象牙底 + 深色描边,黑子近黑剪影 +
 * 浅色细节线,深浅格上都有清晰轮廓。 */

const W = { fill: '#f9f6ee', line: '#2b241c', detail: '#2b241c' };
const B = { fill: '#26231f', line: '#26231f', detail: '#e9e2d0' };

const PIECES = {
  p: (c) => `<g fill="${c.fill}" stroke="${c.line}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M22.5 9c-2.21 0-4 1.79-4 4 0 .89.29 1.71.78 2.38C17.33 16.5 16 18.59 16 21c0 2.03.94 3.84 2.41 5.03-3 1.06-7.41 5.55-7.41 13.47h23c0-7.92-4.41-12.41-7.41-13.47 1.47-1.19 2.41-3 2.41-5.03 0-2.41-1.33-4.5-3.28-5.62.49-.67.78-1.49.78-2.38 0-2.21-1.79-4-4-4z"/>
    <path d="M12.5 37h20v3h-20z"/><path d="M11 40h23v2.5H11z"/>
  </g>`,
  r: (c) => `<g fill="${c.fill}" stroke="${c.line}" stroke-width="1.5" stroke-linejoin="round">
    <path d="M9 39h27v-3H9zM12 36v-4h21v4zM11 14V9h4v2h5V9h5v2h5V9h4v5" stroke-linecap="butt"/>
    <path d="M34 14l-3 3H14l-3-3"/>
    <path d="M31 17v12.5H14V17" stroke-linecap="butt" stroke-linejoin="miter"/>
    <path d="M31 29.5l1.5 2.5h-20l1.5-2.5"/>
    <path d="M11 14h23" fill="none" stroke="${c.detail}" stroke-linejoin="miter"/>
  </g>`,
  n: (c) => `<g fill="${c.fill}" stroke="${c.line}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M22 10c10.5 1 16.5 8 16 29H15c0-9 10-6.5 8-21z"/>
    <path d="M24 18c.38 2.91-5.55 7.37-8 9-3 2-2.82 4.34-5 4-1.042-.94 1.41-3.04 0-3-1 0 .19 1.23-1 2-1 0-4.003 1-4-4 0-2 6-12 6-12s1.89-1.9 2-3.5c-.73-.994-.5-2-.5-3 1-1 3 2.5 3 2.5h2s.78-1.992 2.5-3c1 0 1 3 1 3z"/>
    <path d="M9.5 25.5a.5.5 0 1 1-1 0 .5.5 0 1 1 1 0z" fill="${c.detail}" stroke="${c.detail}"/>
    <path d="M14.933 15.75a.5 1.5 30 1 1-.866-.5.5 1.5 30 1 1 .866.5z" fill="${c.detail}" stroke="${c.detail}"/>
  </g>`,
  b: (c) => `<g fill="${c.fill}" stroke="${c.line}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M9 36c3.39-.97 10.11.43 13.5-2 3.39 2.43 10.11 1.03 13.5 2 0 0 1.65.54 3 2-.68.97-1.65.99-3 .5-3.39-.97-10.11.46-13.5-1-3.39 1.46-10.11.03-13.5 1-1.35.49-2.32.47-3-.5 1.35-1.94 3-2 3-2z"/>
    <path d="M15 32c2.5 2.5 12.5 2.5 15 0 .5-1.5 0-2 0-2 0-2.5-2.5-4-2.5-4 5.5-1.5 6-11.5-5-15.5-11 4-10.5 14-5 15.5 0 0-2.5 1.5-2.5 4 0 0-.5.5 0 2z"/>
    <path d="M25 8a2.5 2.5 0 1 1-5 0 2.5 2.5 0 1 1 5 0z"/>
    <path d="M17.5 26h10M15 30h15m-7.5-14.5v5M20 18h5" fill="none" stroke="${c.detail}"/>
  </g>`,
  q: (c) => `<g fill="${c.fill}" stroke="${c.line}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M8 12a2 2 0 1 1-4 0 2 2 0 1 1 4 0zm16.5-4.5a2 2 0 1 1-4 0 2 2 0 1 1 4 0zM41 12a2 2 0 1 1-4 0 2 2 0 1 1 4 0zM16 8.5a2 2 0 1 1-4 0 2 2 0 1 1 4 0zM33 9a2 2 0 1 1-4 0 2 2 0 1 1 4 0z"/>
    <path d="M9 26c8.5-1.5 21-1.5 27 0l2.5-12.5L31 25l-.3-14.1-5.2 13.6-3-14.5-3 14.5-5.2-13.6L14 25 6.5 13.5 9 26z" stroke-linecap="butt"/>
    <path d="M9 26c0 2 1.5 2 2.5 4 1 1.5 1 1 .5 3.5-1.5 1-1.5 2.5-1.5 2.5-1.5 1.5.5 2.5.5 2.5 6.5 1 16.5 1 23 0 0 0 1.5-1 0-2.5 0 0 .5-1.5-1-2.5-.5-2.5-.5-2 .5-3.5 1-2 2.5-2 2.5-4-8.5-1.5-18.5-1.5-27 0z"/>
  </g>`,
  k: (c) => `<g fill="none" stroke="${c.line}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M22.5 11.63V6M20 8h5" stroke-linejoin="miter"/>
    <path d="M22.5 25s4.5-7.5 3-10.5c0 0-1-2.5-3-2.5s-3 2.5-3 2.5c-1.5 3 3 10.5 3 10.5z" fill="${c.fill}"/>
    <path d="M12.5 37c5.5 3.5 15.5 3.5 21 0v-7s9-4.5 6-10.5c-4-6.5-13.5-3.5-16 4V27v-3.5c-2.5-7.5-12-10.5-16-4-3 6 6 10.5 6 10.5v7" fill="${c.fill}"/>
    ${c.detail !== c.line ? `<path d="M22.5 11.63V6M20 8h5M22.5 25s4.5-7.5 3-10.5c0 0-1-2.5-3-2.5s-3 2.5-3 2.5c-1.5 3 3 10.5 3 10.5z" fill="none" stroke="${c.detail}"/>` : ''}
  </g>`,
};

/** 某棋子的 2D SVG 标记(t ∈ 'pnbrqk',color 为 'w'/'b') */
function piece2d(t, color) {
  const mk = PIECES[t] || PIECES.p;
  return `<svg viewBox="0 0 45 45" aria-hidden="true">${mk(color === 'b' ? B : W)}</svg>`;
}

/* ==================== 对局(逻辑同 webos 国际象棋应用)==================== */

/* ---- 协议常量与显示辅助(worker 契约的一部分,不是引擎导出)----
 * WHITE/BLACK 是回包 stm / 棋子颜色位的取值;棋子编码 p = 颜色<<3 | 型,
 * TYPE_CHARS 把型翻成字符只服务渲染,规则语义仍全在引擎侧。 */
const WHITE = 0, BLACK = 1;
const TYPE_CHARS = ['', 'p', 'n', 'b', 'r', 'q', 'k'];
const sqName = (s) => 'abcdefgh'[s & 7] + (8 - (s >> 3));
const otherStm = (s) => (s === WHITE ? BLACK : WHITE);
const sideName = (s) => (s === WHITE ? '白方' : '黑方');

/** 引擎评分(白方视角、单位厘兵)→ 给人看的字符串。±20000 以上是将杀分,只标 M。 */
const fmtScore = (s) => {
  if (Math.abs(s) >= 20000) return s > 0 ? '+M' : '-M';
  return (s >= 0 ? '+' : '') + (s / 100).toFixed(2);
};

const appEl = $('#app');

let board = new Array(64).fill(0);    // 引擎棋盘(state 回包驱动;p = 颜色<<3|型)
let stm = WHITE;                      // 行棋方(白先)
let legalAll = [];                    // 行棋方全部合法着法(state 回包,from<<6|to)
let checkNow = false;                 // 行棋方被将军态(state 回包)
let humanColor = WHITE;               // 玩家执子方(换边可改)
let moves = [];                       // 走法序列 —— UI 持有的唯一对局状态
let sel = null;                       // 选中的格 [r,c]
let legal = [];                       // 选中子的落点 [[r,c],...]
let gameOver = false;
let vsAI = true;
let searching = false;
let levels = [];                      // 难度表由**引擎自报**({type:'levels'})
let levelIdx = 0;
let levelsP = null;
let bookName = '';                    // 本局最近一次带名书着的族名;无名谱着沿用它显示(见 think 回包)
let levelsResolve = null;

const aiColor = () => humanColor ^ 1;
const lvName = () => levels[levelIdx]?.name ?? '—';

/* 终局弹窗缓冲(600ms):终局画面先落地,给玩家一点反应时间再弹结算。
 * 缓冲期里的新对局 / 悔棋 / 换边 / 人机切换都调 cancelEndDlg 取消 ——
 * 不然这些操作之后还会蹦出上一局的结算框。 */
const END_DLG_MS = 600;
let endDlgTimer = 0;
const cancelEndDlg = () => { clearTimeout(endDlgTimer); endDlgTimer = 0; };
const popEndDlg = (show) => {
  cancelEndDlg();
  endDlgTimer = setTimeout(() => { endDlgTimer = 0; show(); }, END_DLG_MS);
};

const statusL = el('span', {}, '白方行棋');
const infoL = el('span', {
  class: 'mono', style: { fontSize: '11px' },
  title: '引擎搜索信息(评分是引擎视角,单位兵;+M / -M 表示算到将杀)',
}, '');
const board2d = el('div', { class: 'chess2d-board' });
const fitWrap = el('div', { class: 'fit-wrap' }, board2d);

/** 棋盘按可用空间等比缩放(棋盘内部是固定像素布局) */
function fitBoard() {
  const body = appEl.querySelector('.app-body');
  if (!body) return;
  const w = body.clientWidth - 24, h = body.clientHeight - 24;
  const bw = board2d.offsetWidth, bh = board2d.offsetHeight;
  if (!bw || !bh) return;
  fitWrap.style.transform = `scale(${Math.min(1, w / bw, h / bh)})`;
}

/* ---------- 渲染(全部基于最近一次 state 回包的缓存)---------- */
function render2d() {
  board2d.innerHTML = '';
  const target = new Map(legal.map(([r, c]) => [r * 8 + c, !!board[r * 8 + c]]));
  const flip = humanColor === BLACK;    // 执黑时棋盘转 180°,自己的子永远在近处
  for (let dr = 0; dr < 8; dr++) for (let dc = 0; dc < 8; dc++) {
    const r = flip ? 7 - dr : dr, c = flip ? 7 - dc : dc;
    const s = r * 8 + c, p = board[s];
    const to = target.get(s);           // undefined=非落点,false= quiet,true=吃子
    const cell = el('button', {
      class: 'chess2d-cell ' + ((r + c) % 2 === 0 ? 'light' : 'dark')
        + (sel && sel[0] === r && sel[1] === c ? ' sel' : '')
        + (to === undefined ? '' : to ? ' cap' : ' mv'),
      'aria-label': sqName(s),
      onClick: () => handleSquare(r, c),
    });
    if (p) {
      const pc = el('span', { class: 'chess2d-pc ' + ((p >> 3) === WHITE ? 'w' : 'b') });
      pc.innerHTML = piece2d(TYPE_CHARS[p & 7], (p >> 3) === WHITE ? 'w' : 'b');
      cell.append(pc);
    } else if (to === false) cell.append(el('span', { class: 'chess2d-dot' }));
    board2d.append(cell);
  }
}

function syncPieces() { render2d(); }          // 页面只有 2D 视图
function showHighlights() { render2d(); }      // 高亮随整盘重画一并刷新

function updateStatus() {
  statusL.textContent = sideName(stm) + '行棋' + (checkNow ? ' — 将军!⚠' : '');
  setTitle('国际象棋');
}

/* ---------- 走子:目标格以缓存 state 的合法着法为准 ---------- */
function handleSquare(r, c) {
  if (gameOver || statePending) return;
  if (searching) return;              // AI 想棋时锁盘,免得和在途结果打架
  if (sel) {
    const m = moveTo(r, c);
    if (m) { doMove(m); return; }
  }
  const p = board[r * 8 + c];
  if (p && (p >> 3) === stm) {
    const from = r * 8 + c;
    sel = [r, c];
    legal = [];
    for (const wire of legalAll) {
      if ((wire >> 6) !== from) continue;
      legal.push([(wire & 63) >> 3, (wire & 63) & 7]);
    }
    showHighlights();
  } else if (sel) {
    sel = null; legal = []; showHighlights();
  }
}

/** 在选中格的合法着法里取「落到 (r,c)」的那一手(全是线格式,升变即升后) */
function moveTo(r, c) {
  const from = sel[0] * 8 + sel[1], to = r * 8 + c;
  return legalAll.includes((from << 6) | to) ? (from << 6) | to : 0;
}

/** 落子:改走法序列,然后向 Worker 要一次 state */
function doMove(m) {
  moves.push(m);
  sel = null; legal = []; showHighlights();
  fetchState();
}

/* 终局判定:将死 / 逼和 / 子力不足 / 三次重复 —— 全部来自 state 回包。 */
function checkEnd(d) {
  const wcol = otherStm(stm);        // 刚走子的一方获胜(若有)
  const winner = sideName(wcol) + (vsAI && wcol === aiColor() ? '(AI)' : '');
  let title = null, msg = null, line = null;
  if (d.result === 'mate') { title = '将死'; msg = `${winner}获胜!`; line = `将死 — ${sideName(wcol)}胜`; }
  else if (d.result === 'stale') { title = '逼和'; msg = '和棋(无子可动)'; line = '逼和 — 和棋'; }
  else if (d.result === 'material') { title = '和棋'; msg = '子力不足,无法将死'; line = '子力不足 — 和棋'; }
  else if (d.result === 'threefold') { title = '和棋'; msg = '三次重复局面'; line = '三次重复 — 和棋'; }
  if (!title) { updateStatus(); return false; }
  gameOver = true;
  abortEngine();
  /* 结算弹窗缓一拍:让玩家看清终局盘面再弹;缓冲期里的操作会取消它 */
  popEndDlg(() => showDialog({ title, message: msg }));
  statusL.textContent = line;
  setTitle('国际象棋');
  toast('国际象棋:' + line);
  return true;
}

/* ---------- AI:搜索跑在 Worker 里(zig → wasm 通道)---------- */
let worker = null, reqSeq = 0, pendingId = 0, stateSeq = 0, statePending = null;
let thinkT0 = 0, moveTimer = 0;   // 应手节奏:thinkAI 发出请求的时刻 / 补足定时器句柄
/* AI 应手节奏下限(ms):与 webos 应用同一套「立即开想、落子前补足差额」——
 * 搜索慢(深算)时全额占用、一点不叠垫;秒回(开局书/浅搜)时补足下限再落。
 * 历史上这里是「秒回立即落子」(更早是 350~800ms 死垫,被判定为 bug 移除);
 * 补足式在 UI 层与 webos 侧对齐,秒回不再瞬移。 */
const MIN_AI_MS = 260;

/** AI 回包的 move 是引擎打包编码(from 在低 6 位),转回线格式 (from<<6|to) */
const packedToWire = (m) => ((m & 63) << 6) | ((m >> 6) & 63);

/** 开局问一次引擎的难度表:表到手才解开 levelsP 的闸门(thinkAI 会先等它) */
function applyLevels(d) {
  const table = Array.isArray(d.levels)
    ? d.levels.filter((lv) => lv && typeof lv.name === 'string' && lv.name) : [];
  if (!table.length) {
    levelSel.title = 'AI 难度不可用(引擎未上报)';
    levelsResolve?.();
    return;
  }
  levels = table;
  const def = Number.isInteger(d.default) && d.default >= 0 && d.default < table.length ? d.default : 0;
  levelIdx = def;
  levelSel.append(...table.map((lv, i) => el('option', { value: String(i) }, lv.name)));
  levelSel.value = String(def);
  levelSel.disabled = false;
  levelSel.title = 'AI 难度:' + table.map((lv) => lv.name).join(' / ');
  levelsResolve?.();
}
function fetchLevels(timeoutMs = 5000) {
  if (!ensureWorker()) { levelsResolve?.(); return; }
  worker.postMessage({ type: 'levels' });
  setTimeout(() => levelsResolve?.(), timeoutMs);   // 超时也放行,别让 AI 永远等表
}

/** state 回包落地:棋盘重画、将军态、终局判定、AI 调度全由它驱动 */
function applyState(d) {
  board = d.board;
  stm = d.stm;
  legalAll = d.legal;
  checkNow = d.check;
  if (d.over) {
    gameOver = true;
    syncPieces(); showHighlights();
    checkEnd(d);
    return;
  }
  gameOver = false;
  syncPieces();
  if (vsAI && stm === aiColor()) thinkAI();
  else updateStatus();
}

/** 向 Worker 要当前局面的规则事实(state 契约) */
function fetchState() {
  if (!worker && !ensureWorker()) return;
  const id = ++stateSeq;
  statePending = (d) => {
    if (!d) return;                            // 被作废(terminate / 新对局)
    applyState(d);
  };
  worker.postMessage({ type: 'state', id, moves: moves.slice() });
}

function onEngineMsg(e) {
  const d = e.data;
  if (!d) return;
  if (d.type === 'levels') { applyLevels(d); return; }
  if (d.type === 'state') {
    if (!statePending || d.id !== stateSeq) return;   // 过期局面直接丢
    const p = statePending; statePending = null;
    p(d.error ? null : d);
    return;
  }
  if (d.type === 'pong' || d.id !== pendingId) return;      // 过期 / 无关消息
  if (d.error || !d.move) { pendingId = 0; searching = false; infoL.textContent = 'AI 无可用着法'; fetchState(); return; }
  const wire = packedToWire(d.move);
  pendingId = 0;
  if (d.book) {
    // 引擎查谱命中:信息先亮,落子照走 holdMove 的最短应答节奏;
    // 作废防护同普通着法 —— id 过期即丢。
    // 无名谱着(谱树深处 ECO 未再细分)沿用本局最近族名:无名 ≠ 离开该开局
    if (d.name) bookName = d.name;
    infoL.textContent = bookName ? `开局库 · ${bookName}` : '开局库';
    holdMove(d.id, wire);
    return;
  }
  infoL.textContent = `${lvName()} · 深度 ${d.depth} · ${Math.round(d.nodes / 1000)}k 节点 · ${d.ms}ms · ${fmtScore(d.score)}`;
  holdMove(d.id, wire);
}

/** AI 应手落子前的节奏垫:引擎秒回(开局书命中 / 浅搜)时不足 MIN_AI_MS 的
 *  补足再落。等待期间 searching 保持 true(锁盘、状态行仍是思考中);
 *  作废防护与在途搜索同一套 —— abortEngine 会 reqSeq++,迟到回调对不上号就整着丢弃。 */
function holdMove(id, wire) {
  const rest = MIN_AI_MS - (performance.now() - thinkT0);
  if (rest <= 0) { searching = false; doMove(wire); return; }
  moveTimer = setTimeout(() => {
    moveTimer = 0;
    if (id !== reqSeq) return;
    searching = false;
    doMove(wire);
  }, rest);
}

function killWorker() {
  if (worker) { worker.terminate(); worker = null; }
  pendingId = 0; searching = false;
  if (moveTimer) { clearTimeout(moveTimer); moveTimer = 0; }   // 正在垫的应手一并作废
  if (statePending) { const p = statePending; statePending = null; p(null); }
}

/** 作废在途请求(局面已变 / 页面关闭),免得过期着法落到新对局上 */
function abortEngine() {
  reqSeq++;
  killWorker();
  infoL.textContent = '';
}

function ensureWorker() {
  if (worker) return worker;
  try {
    /* pages/app.js 的上一级就是仓库根:src/worker.js 与 wasm/chess.wasm
     * 恰好都在站点根下(本地仓库起服与 GitHub Pages 的 _site 同一布局) */
    worker = new Worker(new URL('../src/worker.js', import.meta.url), { type: 'module' });
    worker.onmessage = onEngineMsg;
    worker.onerror = (ev) => {
      console.warn('[chess-pages] AI Worker 异常:', ev.message || ev);
      killWorker();
      statusL.textContent = 'AI 出错,已跳过本步';
    };
  } catch (err) {
    console.error('[chess-pages] 无法创建 AI Worker:', err);
    worker = null; searching = false;
    statusL.textContent = 'AI 不可用(Worker 创建失败)';
    return null;
  }
  return worker;
}

async function thinkAI() {
  if (gameOver || searching) return;
  /* 先等难度表:表没到手就发 think,worker 会按它自己的 default 跑 */
  if (levelsP) await levelsP;
  searching = true;
  sel = null; legal = []; showHighlights();
  statusL.textContent = `${sideName(aiColor())}思考中…`;
  setTitle('国际象棋');
  infoL.textContent = '';
  if (typeof Worker === 'undefined') {
    searching = false;
    statusL.textContent = '当前环境不支持 Web Worker,AI 不可用';
    return;
  }
  if (!ensureWorker()) return;
  const id = ++reqSeq;
  pendingId = id;
  thinkT0 = performance.now();     // 应手节奏从这里计时,holdMove 垫的就是这段
  worker.postMessage({ id, moves: moves.slice(), level: levelIdx });
}

function resetGame() {
  abortEngine();
  cancelEndDlg();
  board = new Array(64).fill(0);
  stm = WHITE; legalAll = []; checkNow = false;
  moves = [];
  sel = null; legal = [];
  gameOver = false;
  bookName = '';             // 上局的开局族名不带进新局
  syncPieces(); showHighlights(); updateStatus();
  fetchState();                                   // 初始局面事实照问引擎
  if (vsAI && stm === aiColor()) thinkAI();       // 换边后玩家执黑时,AI 执白先行
}

/** 悔棋:撤到「轮到玩家重新决策」为止。人机撤两手,人人撤一手 */
function doUndo() {
  if (!moves.length) return;
  abortEngine();
  cancelEndDlg();
  let n = 1;
  if (vsAI && stm === humanColor && moves.length >= 2) n = 2;
  while (n-- > 0 && moves.length) moves.pop();
  gameOver = false;
  sel = null; legal = [];
  bookName = '';             // 撤回后名字可能已细化过头,清掉等带名书着重建
  stm = moves.length % 2 === 0 ? WHITE : BLACK;   // 仅作过渡,回包会再校正
  syncPieces(); showHighlights();
  fetchState();
  if (vsAI && stm === aiColor()) thinkAI();
  else updateStatus();
}

/** 换边:与 AI 互换执子方,棋盘随之翻转 */
function switchSide() {
  abortEngine();
  cancelEndDlg();
  humanColor ^= 1;
  sel = null; legal = [];
  render2d();
  if (!gameOver && vsAI && stm === aiColor()) thinkAI();
  else if (!gameOver) updateStatus();
}

/* ---------- 界面 ---------- */
const newBtn = el('button', { class: 'btn primary', onClick: resetGame }, icon('refresh'), '新对局');
const levelSel = el('select', {
  class: 'select chess-level',
  title: 'AI 难度(等引擎上报)',
  'aria-label': 'AI 难度',
  disabled: true,
  onChange: (e) => {
    levelIdx = Number(e.currentTarget.value) || 0;
    if (searching) { abortEngine(); thinkAI(); }
  },
});
const aiBtn = el('button', {
  class: 'btn', title: '切换人机 / 双人对战',
  onClick: (e) => {
    cancelEndDlg();
    vsAI = !vsAI;
    e.currentTarget.replaceChildren(vsAI ? '人机' : '双人');
    sideBtn.disabled = !vsAI;                                  // 换边只对人机模式有意义
    if (!vsAI) { abortEngine(); updateStatus(); }              // 关掉 AI 要把在途搜索停掉
    else if (!gameOver && stm === aiColor()) thinkAI();        // 轮到 AI 一侧就立刻接手
    else updateStatus();
  },
}, '人机');
const sideBtn = el('button', {
  class: 'btn', title: '换边:与 AI 互换执子方,棋盘随之翻转',
  onClick: switchSide,
}, '换边');
const undoBtn = el('button', {
  class: 'btn', title: '悔棋:人机模式连 AI 的应手一起撤,人人模式撤一手',
  onClick: doUndo,
}, icon('reply'), '悔棋');

appEl.append(el('div', { class: 'app' },
  el('div', { class: 'app-toolbar' },
    newBtn,
    el('label', { class: 'chess-level-wrap', title: 'AI 难度' },
      el('span', { class: 'dim', style: { fontSize: '12px' } }, '难度'), levelSel),
    aiBtn, sideBtn, undoBtn),
  el('div', { class: 'app-body' }, fitWrap),
  el('div', { class: 'app-status' }, statusL,
    el('span', { class: 'grow' }),
    infoL)));

/* 问引擎要难度表与初始局面 */
levelsP = new Promise((res) => { levelsResolve = res; });
fetchLevels();
fetchState();
new ResizeObserver(fitBoard).observe(appEl.querySelector('.app-body'));
fitBoard();

/* 页面冒烟探针钩子(验证脚本用) */
window.__pagesStats = () => ({
  plies: moves.length, turn: stm, human: humanColor, gameOver, vsAI,
  level: lvName(),
});
window.__pagesHumanMove = () => {
  if (gameOver || (vsAI && stm !== humanColor)) return false;
  /* 选第一个有合法着法的己方子,落到它的第一个合法格 */
  for (const wire of legalAll) {
    const from = wire >> 6;
    if ((board[from] >> 3) !== stm) continue;
    doMove(wire);
    return true;
  }
  return false;
};

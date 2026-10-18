/* Scan-Relay 任务窗格逻辑
 * 配对 -> WebSocket 连接中转服务 -> 收到扫码/表单数据后按宿主写入（Excel/Word/PowerPoint）。
 * 连接路径: 页面(https://localhost:4443) -> /relay/* 反向代理 -> 本地中转服务(8765)
 */
/* global Office, Excel, Word, PowerPoint */
import QRCode from "qrcode";

const RELAY_PAIR_URL = "/relay/pair";
const PPT_TEXTBOX_NAME = "ScanRelay.Text"; // PPT 追加目标文本框的标记名

// ---------------------------------------------------------------- 状态
const state = {
  ws: null,
  token: null,
  sawPhone: false,
  hostKind: "other", // excel | word | powerpoint | other
  degraded: false,   // Office.js 未就绪（CDN 慢/被拦截）时的降级标记
  mode: "stream", // stream | form
  stream: { sheetName: null, row: null, col: null, count: 0, lastValue: "", lastTime: 0 },
  form: { sheetName: null, row: null, fields: [] }, // fields: [{name, col(数字索引)}]
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- 工具
function log(line) {
  const el = document.createElement("div");
  el.textContent = new Date().toLocaleTimeString() + "  " + line;
  $("log").prepend(el);
}

function setStatus(kind, text) {
  $("statusDot").className = kind;
  $("statusText").textContent = text;
}

function colLetter(index) {
  let s = "";
  let n = index + 1;
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function letterToIndex(letter) {
  const m = String(letter).toUpperCase().match(/^[A-Z]+$/);
  if (!m) return null;
  return letter.toUpperCase().split("").reduce((acc, ch) => acc * 26 + (ch.charCodeAt(0) - 64), 0) - 1;
}

async function storageGet(key) {
  try {
    if (typeof OfficeRuntime !== "undefined" && OfficeRuntime.storage) {
      return await OfficeRuntime.storage.get(key);
    }
  } catch (e) { /* fall through */ }
  return localStorage.getItem(key);
}

async function storageSet(key, value) {
  try {
    if (typeof OfficeRuntime !== "undefined" && OfficeRuntime.storage) {
      await OfficeRuntime.storage.set(key, value);
      return;
    }
  } catch (e) { /* fall through */ }
  localStorage.setItem(key, value);
}

// ---------------------------------------------------------------- Excel 写入
async function getActiveCellPos() {
  return Excel.run(async (context) => {
    const cell = context.workbook.getActiveCell();
    cell.load(["rowIndex", "columnIndex"]);
    const sheet = context.workbook.worksheets.getActiveWorksheet();
    sheet.load("name");
    await context.sync();
    return { sheetName: sheet.name, row: cell.rowIndex, col: cell.columnIndex };
  });
}

async function writeCell(sheetName, rowIndex, colIndex, value) {
  return Excel.run(async (context) => {
    const sheet = context.workbook.worksheets.getItem(sheetName);
    sheet.getRangeByIndexes(rowIndex, colIndex, 1, 1).values = [[String(value)]];
    await context.sync();
  });
}

async function writeRow(sheetName, rowIndex, pairs) {
  // pairs: [{col, value}] —— 同一次 sync 内写多个单元格
  return Excel.run(async (context) => {
    const sheet = context.workbook.worksheets.getItem(sheetName);
    for (const p of pairs) {
      sheet.getRangeByIndexes(rowIndex, p.col, 1, 1).values = [[String(p.value)]];
    }
    await context.sync();
  });
}

// ---------------------------------------------------------------- Word 写入（光标处逐行插入）
async function writeWordLines(lines) {
  // lines: string[] —— 一次调用整体插到当前光标后，每条占一段；光标跟随到末尾
  return Word.run(async (context) => {
    const range = context.document.getSelection();
    const text = lines.map(String).join("\r") + "\r";
    // "End" = 插到选区之后（Word.InsertLocation 是官方枚举，值 "End"）
    const inserted = range.insertText(text, Word.InsertLocation.end);
    // ① 先提交写入：Office.js 的操作是排队到 sync 才执行，任何异常只要发生在
    //    sync 之前，整批都会被丢弃——所以必须把"写入"和"移动光标"拆成两步，
    //    光标操作出问题绝不能连累已经写进去的数据。
    await context.sync();
    try {
      // ② 再把光标挪到新内容末尾，好让下一条继续往后追加。
      //    枚举是 Word.SelectionMode（"Select"/"Start"/"End"），
      //    Word.SelectionRange 根本不存在，用了会直接 TypeError。
      inserted.select(Word.SelectionMode.end);
      await context.sync();
    } catch (e) {
      // 光标没跟上：本次内容仍在，但下一条可能接在原地，提示用户重定位
      log("⚠ 光标跟随失败（已写入内容不受影响）: " + e.message);
    }
  });
}

// ---------------------------------------------------------------- PowerPoint 写入（当前页文本框追加）
async function writePptLines(lines) {
  // lines: string[] —— 追加到当前幻灯片一个专用文本框（不存在则创建）
  return PowerPoint.run(async (context) => {
    const slide = context.presentation.getSelectedSlide();
    const shapes = slide.shapes;
    shapes.load("items");
    await context.sync();

    let box = null;
    if (shapes.items.length > 0) {
      // 显式加载 name：只 load("items") 时直接取 s.name 可能被 Office.js 拒绝
      // （PropertyNotLoaded），那样每扫一次就会新建一个文本框而不是追加
      shapes.items.forEach((s) => s.load("name"));
      await context.sync();
      box = shapes.items.find((s) => s.name === PPT_TEXTBOX_NAME);
    }
    if (!box) {
      box = slide.shapes.addTextBox("", 40, 120, 560, 300);
      box.name = PPT_TEXTBOX_NAME;
    }
    const textRange = box.textFrame.textRange;
    textRange.load("text");
    await context.sync();

    const prefix = textRange.text ? textRange.text.replace(/\n$/, "") + "\n" : "";
    textRange.text = prefix + lines.map((l) => String(l)).join("\n");
    await context.sync();
  });
}

// ---------------------------------------------------------------- 统一写入口（按宿主分流）
async function writeLines(lines) {
  if (state.hostKind === "word") {
    await writeWordLines(lines);
  } else if (state.hostKind === "powerpoint") {
    await writePptLines(lines);
  } else if (state.hostKind === "excel") {
    // Excel 走原有单元格逻辑，这里不处理
    throw new Error("Excel 请使用单元格写入路径");
  } else {
    throw new Error("当前 Office 组件不支持写入");
  }
}

// ---------------------------------------------------------------- 选中单元格自动跟踪（轮询活动单元格）
// 注：本机 Excel 运行时不提供 worksheet.onSelectionChange 事件成员（取到 undefined），
// 改用轮询 getActiveCell —— 效果相同，且兼容所有 Excel 版本。
function applyAnchor(sheetName, row, col, logIt = true) {
  const s = state.stream;
  const f = state.form;
  const changed = s.sheetName !== sheetName || s.row !== row || s.col !== col;
  if (changed) {
    Object.assign(s, { sheetName, row, col, count: 0, lastValue: "", lastTime: 0 });
    $("scanCount").textContent = "已写入 0 行";
  }
  Object.assign(f, { sheetName, row });
  $("streamPos").textContent = `${sheetName}!${colLetter(col)}${row + 1}`;
  $("formPos").textContent = `${sheetName} 第 ${row + 1} 行`;
  if (changed && logIt) {
    log(`起点: ${sheetName}!${colLetter(col)}${row + 1}（自动跟踪）`);
  }
  return changed;
}

async function pollActiveCell() {
  if (typeof Excel === "undefined" || !Excel.run) return;
  try {
    const pos = await getActiveCellPos();
    applyAnchor(pos.sheetName, pos.row, pos.col);
  } catch (e) { /* 瞬时错误（如正在重算）忽略，下一轮重试 */ }
}

let _autoTracking = false; // startAutoTracking 只允许启动一次轮询

async function startAutoTracking() {
  if (_autoTracking) return; // 幂等：宿主适配可能被调用多次（晚到的 Office.onReady）
  _autoTracking = true;
  try {
    const pos = await getActiveCellPos();
    applyAnchor(pos.sheetName, pos.row, pos.col, false);
    log(`自动跟踪已启动，起点 ${pos.sheetName}!${colLetter(pos.col)}${pos.row + 1}（点哪个单元格就从哪开始写）`);
  } catch (e) {
    log("⚠ 获取选中单元格失败: " + e.message);
  }
  setInterval(pollActiveCell, 800);
}

// ---------------------------------------------------------------- 连接管理
async function fetchPairInfo() {
  const res = await fetch(RELAY_PAIR_URL);
  if (!res.ok) throw new Error("配对接口请求失败 " + res.status);
  return res.json();
}

async function connect(token) {
  // 只关闭旧 socket，不重置界面（qrBox 等 UI 状态由调用方控制，
  // 断开按钮走 disconnect()，此处不能复用，否则会把刚显示的二维码藏回去）
  if (state.ws) {
    state.ws.onclose = null;
    state.ws.close();
    state.ws = null;
  }
  state.token = token;
  setStatus("connecting", "连接中…");
  const wsOrigin = location.origin.replace(/^http/, "ws");
  const ws = new WebSocket(`${wsOrigin}/relay/ws?token=${encodeURIComponent(token)}&role=addin`);
  state.ws = ws;

  ws.onopen = async () => {
    setStatus("connected", "已连接");
    await storageSet("scanrelay_token", token);
    log("已连接中转服务，token=" + token);
  };
  ws.onmessage = (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    handleMessage(msg);
  };
  ws.onclose = () => {
    if (state.ws === ws) {
      state.ws = null;
      setStatus("", "已断开");
      log("连接已断开");
    }
  };
  ws.onerror = () => log("WebSocket 错误（请确认中转服务已启动）");
}

function disconnect(clearToken = true) {
  if (state.ws) {
    state.ws.onclose = null;
    state.ws.close();
    state.ws = null;
  }
  if (clearToken) {
    state.token = null;
    storageSet("scanrelay_token", "");
  }
  setStatus("", "未连接");
  $("qrBox").hidden = true;
  $("btnDisconnect").disabled = true;
  $("phoneCount").textContent = "";
}

function handleMessage(msg) {
  switch (msg.type) {
    case "peer_status": {
      const n = msg.phones || 0;
      $("phoneCount").textContent = n > 0 ? `手机 ${n} 台在线` : "";
      if (n > 0) {
        state.sawPhone = true;
        log(`手机已连接（${n} 台）`);
      } else {
        log(state.sawPhone ? "手机已断开" : "等待手机连接…");
        state.sawPhone = false;
      }
      break;
    }
    case "scan":
      log(`扫码: ${msg.value}`);
      onScan(msg.value);
      break;
    case "form_submit":
      log(`表单提交: ${JSON.stringify(msg.fields)}`);
      onFormSubmit(msg.fields);
      break;
    case "form_config":
      log("已收到表单配置（来自其他加载项窗口）");
      break;
    case "error":
      log("服务端错误: " + msg.message);
      break;
  }
}

function sendMessage(obj) {
  if (state.ws && state.ws.readyState === WebSocket.OPEN) {
    state.ws.send(JSON.stringify(obj));
    return true;
  }
  log("未连接，消息被忽略");
  return false;
}

// ---------------------------------------------------------------- 数据处理
async function onScan(value) {
  if (state.mode !== "stream") return;
  const s = state.stream;
  if (state.hostKind === "excel" && s.sheetName === null) {
    log("⚠ 未定位起点，请在表格中点选一个单元格");
    return;
  }
  if (state.hostKind === "other") {
    log("⚠ 当前 Office 组件不支持写入（仅 Excel/Word/PowerPoint）");
    return;
  }
  // 重复保护
  const now = Date.now();
  const dedupe = parseInt($("dedupeMs").value, 10) || 0;
  if (dedupe > 0 && value === s.lastValue && now - s.lastTime < dedupe) {
    log("⏭ 重复数据已跳过");
    return;
  }
  s.lastValue = value;
  s.lastTime = now;
  try {
    if (state.hostKind === "excel") {
      await writeCell(s.sheetName, s.row + s.count, s.col, value);
    } else {
      await writeLines([value]);
    }
    s.count += 1;
    $("scanCount").textContent = `已写入 ${s.count} 行`;
  } catch (e) {
    log("⚠ 写入失败: " + e.message);
  }
}

async function onFormSubmit(fields) {
  const f = state.form;
  if (state.hostKind === "other") {
    log("⚠ 当前 Office 组件不支持写入（仅 Excel/Word/PowerPoint）");
    return;
  }
  if (state.hostKind === "excel" && f.sheetName === null) {
    log("⚠ 未定位起点，请在表格中点选一个单元格");
    return;
  }
  const pairs = f.fields
    .filter((x) => fields[x.name] !== undefined)
    .map((x) => ({ col: x.col, name: x.name, value: fields[x.name] }));
  if (pairs.length === 0) {
    log("⚠ 提交的字段与配置不匹配");
    return;
  }
  try {
    if (state.hostKind === "excel") {
      await writeRow(f.sheetName, f.row, pairs);
      f.row += 1;
      $("formPos").textContent = `${f.sheetName} 第 ${f.row} 行`;
    } else {
      // Word/PPT：字段顺序即插入顺序，格式「字段名: 值」
      await writeLines(pairs.map((p) => `${p.name}: ${p.value}`));
      log(`表单已写入（${pairs.length} 个字段）`);
    }
  } catch (e) {
    log("⚠ 写入失败: " + e.message);
  }
}

// ---------------------------------------------------------------- 配对 UI
async function showPairQR() {
  try {
    const info = await fetchPairInfo();
    // 用 data URL 渲染成 <img>（WebView2 对 canvas 偶有渲染问题，img 更可靠）
    const dataUrl = await QRCode.toDataURL(info.page_url, { width: 180, margin: 2 });
    $("qrImg").src = dataUrl;
    $("qrUrl").textContent = info.page_url;
    $("qrBox").hidden = false;
    $("btnDisconnect").disabled = false;
    // 多网卡（USB共享/热点并存）时列出候选地址，手机可手动输入兜底
    const ips = Array.isArray(info.ips) ? info.ips : [];
    const others = ips.filter((ip) => !info.page_url.includes(ip));
    if (others.length > 0) {
      $("serverHint").textContent =
        `连不上二维码地址时，手机手动输入: ` +
        others.map((ip) => `http://${ip}:8765/scan?token=${info.token}`).join("  或  ");
    }
    log(`配对码已生成（图片 ${dataUrl.length > 100 ? "正常" : "异常，长度 " + dataUrl.length}）`);
    connect(info.token);
  } catch (e) {
    log("⚠ 生成配对码失败: " + e.message + "（请确认中转服务已启动）");
  }
}

// ---------------------------------------------------------------- 表单设计器 UI
function renderFields() {
  const list = $("fieldList");
  list.innerHTML = "";
  state.form.fields.forEach((field, i) => {
    const row = document.createElement("div");
    row.className = "fieldRow";

    const nameInput = document.createElement("input");
    nameInput.type = "text";
    nameInput.placeholder = "字段名（手机上显示）";
    nameInput.value = field.name;
    nameInput.oninput = () => { field.name = nameInput.value.trim(); };

    const colInput = document.createElement("input");
    colInput.type = "text";
    colInput.className = "col";
    colInput.title = "写入的列（A、B、C…）";
    colInput.value = colLetter(field.col);
    // Word/PPT 没有"列"的概念，动态新增的字段同样不能露出列输入
    // （adaptUiForHost 只能管到初始化那一刻已经存在的行）
    if (state.hostKind !== "excel") colInput.style.display = "none";
    colInput.onchange = () => {
      const idx = letterToIndex(colInput.value);
      if (idx === null) { colInput.value = colLetter(field.col); return; }
      field.col = idx;
      colInput.value = colLetter(idx);
    };

    const del = document.createElement("a");
    del.textContent = "✕";
    del.onclick = () => { state.form.fields.splice(i, 1); renderFields(); };

    row.append(nameInput, colInput, del);
    list.appendChild(row);
  });
}

// ---------------------------------------------------------------- 事件绑定与初始化
function bindEvents() {
  $("btnPair").onclick = showPairQR;
  $("btnDisconnect").onclick = () => { disconnect(); log("已手动断开"); };
  $("btnClearLog").onclick = () => { $("log").innerHTML = ""; };

  // 模式切换
  $("tabStream").onclick = () => switchTab("stream");
  $("tabForm").onclick = () => switchTab("form");

  // 连续扫码（手动备用取点）—— 仅 Excel 有意义（Word 跟随光标、PPT 跟随当前页）
  $("btnLocate").onclick = async () => {
    if (state.hostKind !== "excel") {
      log("⚠ 手动取点只在 Excel 中可用（Word 插在光标处 / PPT 插在当前页）");
      return;
    }
    try {
      const pos = await getActiveCellPos();
      applyAnchor(pos.sheetName, pos.row, pos.col, false);
      log(`手动取点: ${pos.sheetName}!${colLetter(pos.col)}${pos.row + 1}`);
    } catch (e) { log("⚠ 定位失败: " + e.message); }
  };

  // 表单模式
  $("btnAddField").onclick = () => {
    state.form.fields.push({ name: "", col: state.form.fields.length });
    renderFields();
  };
  $("btnSendConfig").onclick = () => {
    const fields = state.form.fields.filter((f) => f.name);
    if (fields.length === 0) { log("⚠ 请先添加字段"); return; }
    sendMessage({ type: "form_config", fields: fields.map((f) => ({ name: f.name, column: colLetter(f.col) })) });
    log("表单配置已下发");
  };
  $("btnFormLocate").onclick = async () => {
    if (state.hostKind !== "excel") {
      log("⚠ 手动取点只在 Excel 中可用（Word 插在光标处 / PPT 插在当前页）");
      return;
    }
    try {
      const pos = await getActiveCellPos();
      applyAnchor(pos.sheetName, pos.row, pos.col, false);
      log(`手动取点: ${pos.sheetName} 第 ${pos.row + 1} 行`);
    } catch (e) { log("⚠ 定位失败: " + e.message); }
  };
}

function switchTab(mode) {
  state.mode = mode;
  $("tabStream").className = mode === "stream" ? "active" : "";
  $("tabForm").className = mode === "form" ? "active" : "";
  $("paneStream").hidden = mode !== "stream";
  $("paneForm").hidden = mode !== "form";
}

let _initialized = false;
let _hostApplied = null;      // 上次按宿主适配时的 hostKind（用于 applyHostUi 幂等）
let _serverWatchStarted = false;
let _startButtonBound = false;

function detectHostKind(info) {
  try {
    const h = info && info.host;
    if (typeof Office !== "undefined" && Office.HostType) {
      if (h === Office.HostType.Excel) return "excel";
      if (h === Office.HostType.Word) return "word";
      if (h === Office.HostType.PowerPoint) return "powerpoint";
    }
  } catch (e) { /* ignore */ }
  return "other";
}

const HOST_LABELS = { excel: "Excel", word: "Word", powerpoint: "PowerPoint" };

function initTaskpane() {
  if (_initialized) return;
  _initialized = true;
  bindEvents();
  renderFields();
  $("serverHint").textContent = `中转服务地址: ${location.origin}/relay（需先启动中转服务）`;
  applyHostUi();
  restoreToken();
  startServerWatch();
}

// 按宿主适配 UI —— 幂等：宿主没变就什么都不做。
// 存在意义：Office.onReady 可能晚于 8 秒兜底超时才到达，那时 _initialized 已为
// true、initTaskpane 直接返回，若不单独再调一次本函数，hostKind 虽被更新却
// 既不会隐藏 Excel 专用控件、也不会启动 Excel 自动跟踪。
function applyHostUi() {
  if (_hostApplied === state.hostKind) return;
  _hostApplied = state.hostKind;

  const label = HOST_LABELS[state.hostKind];
  if (label) {
    state.degraded = false;
    log(`加载项就绪（${label} 模式）`);
    adaptUiForHost();
    if (state.hostKind === "excel") startAutoTracking();
    else log(state.hostKind === "word"
      ? "扫码内容将插入到光标处（每条一段）"
      : "扫码内容将追加到当前页文本框（没有会自动创建）");
  } else {
    adaptUiForHost(); // 降级/不支持：Excel 专用取点控件同样要藏起来
    log(state.degraded
      ? "⚠ Office.js 未就绪（CDN appsforoffice.microsoft.com 可能被拦截），已进入降级模式：可配对，无法写入。检查网络后重启 Office 即可恢复"
      : "⚠ 当前 Office 组件不受支持（仅 Excel/Word/PowerPoint），配对可用但无法写入");
  }
}

// 统一入口：初始化一次 + 按宿主适配（可重复）+ 绑定启动按钮（幂等）
function startApp() {
  initTaskpane();
  applyHostUi();
  bindStartButton();
}

function adaptUiForHost() {
  if (state.hostKind === "excel") return; // Excel 保持原样（取点按钮、列输入都要留着）

  // Word/PPT/降级：隐藏 Excel 专用的取点行。
  // 关键：这两个元素带 class="row"（display:flex），作者样式会压过浏览器默认的
  // [hidden]{display:none}，光设 .hidden=true 是**不生效**的（这正是 Word 里
  // "手动取点"点出 Excel is not defined 的原因），必须配合 HTML 里的
  // [hidden]{display:none!important} 才真正隐藏。
  const hide = (id) => { const el = $(id); if (el) el.hidden = true; };
  hide("streamLocateRow");
  hide("formLocateRow");
  // 字段行里动态创建的列输入也一并压掉
  document.querySelectorAll(".fieldRow input.col").forEach((el) => { el.style.display = "none"; });

  if (state.hostKind === "word") {
    $("streamHint").textContent = "扫码内容插入到光标处，每条数据占一段；请先在文档中点好光标位置。";
    $("formHint").textContent = "表单按「字段名: 值」逐条插入到光标处。";
  } else if (state.hostKind === "powerpoint") {
    $("streamHint").textContent = "扫码内容追加到当前页的「ScanRelay.Text」文本框；换页后扫码会自动创建新文本框。";
    $("formHint").textContent = "表单按「字段名: 值」逐条追加到当前页的「ScanRelay.Text」文本框。";
  } else {
    // 降级（Office.js 未就绪）或不支持的宿主
    $("streamHint").textContent = "当前环境无法写入（仅 Excel/Word/PowerPoint），配对仍可使用。";
    $("formHint").textContent = "当前环境无法写入（仅 Excel/Word/PowerPoint），配对仍可使用。";
  }
}

// ---------------------------------------------------------------- 服务器状态卡（探测 + 一键启动）
const START_PROTOCOL = "scanrelay://start";

async function probeServer() {
  // 同源 /healthz，服务在但可能未配对也能探测到
  try {
    const res = await fetch("/healthz", { cache: "no-store" });
    return res.ok;
  } catch (e) {
    return false;
  }
}

let _serverUp = true; // 页面能加载出来通常说明服务在跑

function setServerCard(up) {
  if (up === _serverUp) return;
  _serverUp = up;
  $("serverCard").hidden = up;
  if (!up) {
    setStatus("", "服务未运行");
    log("⚠ 中转服务已停止（可用下方按钮一键启动）");
  } else {
    log("✓ 中转服务已恢复");
  }
}

async function startServerWatch() {
  if (_serverWatchStarted) return;
  _serverWatchStarted = true;
  // 每 3 秒探测一次；服务停止时显示一键启动卡
  setInterval(async () => {
    const up = await probeServer();
    setServerCard(up);
    // 服务恢复且之前连过 -> 自动重连
    if (up && !state.ws && state.token) {
      log("自动重新连接…");
      connect(state.token);
    }
  }, 3000);
}

function bindStartButton() {
  if (_startButtonBound) return;
  _startButtonBound = true;
  $("btnStartServer").onclick = () => {
    const hint = $("startHint");
    hint.hidden = false;
    hint.textContent = "正在请求启动（若弹出确认框请点「打开」）…";
    log("请求启动中转服务（scanrelay://）");
    // 触发自定义协议唤起本地启动器（anchor 点击是 WebView2 支持最稳的方式，
    // 系统会弹一次「是否打开 launcher.vbs」确认）
    const a = document.createElement("a");
    a.href = START_PROTOCOL;
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    setTimeout(() => a.remove(), 30000);
    // 轮询等待服务起来
    let waited = 0;
    const timer = setInterval(async () => {
      waited += 1;
      if (await probeServer()) {
        clearInterval(timer);
        hint.textContent = "";
        hint.hidden = true;
        setServerCard(true);
      } else if (waited >= 20) { // 20 次 x 1.5 秒 = 30 秒超时
        clearInterval(timer);
        hint.textContent = "启动超时：请确认弹窗中点了「打开」，或手动运行 启动Scan-Relay.bat";
      }
    }, 1500);
  };
}

async function restoreToken() {
  const saved = await storageGet("scanrelay_token");
  if (saved) {
    log("尝试恢复上次会话…");
    state.token = saved;
    connect(saved);
  }
}

if (typeof Office !== "undefined" && typeof Office.onReady === "function") {
  Office.onReady(async (info) => {
    state.hostKind = detectHostKind(info);
    startApp();
  });
  // 兜底：8 秒内 Office.js 没就绪（如 CDN 被拦截）也初始化——配对不依赖 Office API
  setTimeout(() => {
    if (!_initialized) {
      state.degraded = true;
      startApp(); // initTaskpane 里的 applyHostUi 负责打印降级提示
    }
  }, 8000);
} else {
  state.degraded = true;
  startApp();
}

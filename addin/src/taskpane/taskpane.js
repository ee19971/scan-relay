/* Scan-Relay 任务窗格逻辑
 * 配对 -> WebSocket 连接中转服务 -> 收到扫码/表单数据后写入 Excel。
 * 连接路径: 页面(https://localhost:3000) -> /relay/* 反向代理 -> 本地中转服务(8765)
 */
/* global Office, Excel */
import QRCode from "qrcode";

const RELAY_PAIR_URL = "/relay/pair";

// ---------------------------------------------------------------- 状态
const state = {
  ws: null,
  token: null,
  sawPhone: false,
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

async function startAutoTracking() {
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
  if (s.sheetName === null) {
    log("⚠ 未定位起点，请在表格中点选一个单元格");
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
    await writeCell(s.sheetName, s.row + s.count, s.col, value);
    s.count += 1;
    $("scanCount").textContent = `已写入 ${s.count} 行`;
  } catch (e) {
    log("⚠ 写入失败: " + e.message);
  }
}

async function onFormSubmit(fields) {
  const f = state.form;
  if (f.sheetName === null) {
    log("⚠ 未定位起点，请在表格中点选一个单元格");
    return;
  }
  const pairs = f.fields
    .filter((x) => fields[x.name] !== undefined)
    .map((x) => ({ col: x.col, value: fields[x.name] }));
  if (pairs.length === 0) {
    log("⚠ 提交的字段与配置不匹配");
    return;
  }
  try {
    await writeRow(f.sheetName, f.row, pairs);
    f.row += 1;
    $("formPos").textContent = `${f.sheetName} 第 ${f.row} 行`;
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

  // 连续扫码（手动备用取点）
  $("btnLocate").onclick = async () => {
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

function initTaskpane() {
  if (_initialized) return;
  _initialized = true;
  bindEvents();
  renderFields();
  $("serverHint").textContent = `中转服务地址: ${location.origin}/relay（需先启动中转服务）`;
  log("加载项就绪");
  restoreToken();
  startAutoTracking();
}

async function restoreToken() {
  const saved = await storageGet("scanrelay_token");
  if (saved) {
    log("尝试恢复上次会话…");
    connect(saved);
  }
}

if (typeof Office !== "undefined" && typeof Office.onReady === "function") {
  Office.onReady(async (info) => {
    if (info && info.host && info.host !== Office.HostType.Excel) {
      log("⚠ 当前不是 Excel 宿主");
    }
    initTaskpane();
  });
  // 兜底：8 秒内 Office.js 没就绪（如 CDN 被拦截）也初始化——配对不依赖 Office API
  setTimeout(() => {
    if (!_initialized) {
      log("⚠ Office.js 加载超时（CDN 可能被拦截），已进入降级模式：配对可用，写入 Excel 可能失败");
      initTaskpane();
    }
  }, 8000);
} else {
  log("⚠ 未检测到 Office 环境（office.js 未加载），已进入降级模式：配对可用，写入 Excel 可能失败");
  initTaskpane();
}

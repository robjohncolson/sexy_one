// SEXY ONE Sample Lab -- a deferred, local-first pad-bank planner.
//
// This module is intentionally absent from index.js's static import graph. The
// trainer loads and becomes interactive first, then index.js imports this file.
// Audio bytes live in IndexedDB and move between devices only inside a user-
// initiated .sxc1lab export. Nothing here has a network write path.

const ROUTE = "#/samples";
const META_KEY = "sxc1.sample-lab.v1";
const DB_NAME = "sxc1-sample-lab";
const DB_VERSION = 1;
const DB_STORE = "audio";
const FORMAT_MAGIC = "SXC1LAB1";
const FORMAT_SCHEMA = 1;
const MAX_MANIFEST_BYTES = 5 * 1024 * 1024;
const MAX_AUDIO_BYTES = 180 * 1024 * 1024;
const SLOT_NAMES = ["A", "B", "C", "D"];
const SUPPORTED_EXTENSIONS = new Set(["wav", "mp3", "flac", "cswp"]);

const COPY = {
  en: {
    homeTitle: "Build a sample bank",
    homeSub: "Arrange audio on an SXC-1 pad mockup",
    library: "Manuals, course, and progress",
    back: "Back to SEXY ONE",
    eyebrow: "LOCAL SAMPLE WORKSPACE",
    title: "Sample Lab",
    intro: "Shape files in Audacity, plan the pads here, then carry one project to your phone.",
    local: "Audio stays on this device",
    temporary: "Temporary mode — export before closing this tab",
    project: "Project",
    projectName: "Project name",
    bankSlots: "Four SXC-1 bank slots",
    bankNumber: "User bank",
    bankName: "Bank name",
    padMap: "Pad map",
    padHint: "Press an assigned pad to preview it. Empty pads select a destination.",
    empty: "EMPTY",
    selectedPad: "Selected destination",
    dropTitle: "Drop a sample here",
    dropHint: "or choose WAV, MP3, FLAC, or .cswp — up to 180 MB",
    choose: "Choose a sample",
    importing: "Reading sample…",
    replace: "Replace file",
    remove: "Remove",
    name: "Pad name",
    source: "Source note",
    sourcePlaceholder: "Game, recording, video, session…",
    tags: "Tags",
    tagsPlaceholder: "kick, texture, voice",
    color: "Pad colour",
    playMode: "Playback intent",
    oneShot: "One-shot",
    loop: "Loop",
    bpm: "BPM (optional)",
    group: "Mute group",
    none: "None",
    fileFacts: "File details",
    recommended: "SXC-1-ready WAV",
    supported: "Supported by CASIO app",
    retained: "Retained as project data",
    recommendWav: "For the closest hardware match, export 48 kHz / 16-bit PCM WAV from Audacity.",
    saveShare: "Save / share project",
    handoff: "Phone handoff",
    tools: "Project tools",
    importProject: "Import .sxc1lab project",
    usage: "Storage",
    copyright: "Only use audio you have permission to sample. Sample Lab does not extract audio from games or video services.",
    saved: "Saved locally",
    exported: "Project ready",
    imported: "Project imported",
    invalidFile: "Choose a WAV, MP3, FLAC, or .cswp file.",
    tooLarge: "That file is larger than the 180 MB per-sample limit.",
    storageFailed: "Persistent audio storage is unavailable. This tab will keep the audio temporarily.",
    readFailed: "That file could not be read.",
    badProject: "That is not a valid Sample Lab project.",
    removeConfirm: "Remove this pad assignment? The original file outside SEXY ONE is not affected.",
    noPads: "Assign at least one sample before starting phone handoff.",
    handoffEyebrow: "PHONE HANDOFF",
    handoffTitle: "Load one pad at a time",
    handoffIntro: "Open this project on your phone. SEXY ONE keeps the destination visible while CASIO Sampler App performs the actual assignment.",
    backPlanner: "Back to pad planner",
    destination: "Destination",
    file: "File",
    step1: "Connect the SXC-1 DATA port to the phone and open CASIO Sampler App.",
    step2: "Open the destination bank and pad, choose Assign Sound, then Select from file.",
    step3: "Share or download this original audio file, select it in CASIO's app, and confirm the assignment there.",
    shareFile: "Share this file",
    downloadFile: "Download this file",
    nextPad: "Next pad",
    finish: "Finish handoff",
    progress: "Pad {current} of {total}",
    noPreview: "This file can travel with the project but cannot be previewed in this browser.",
    previewFailed: "Browser preview is unavailable for this file; its original bytes are still safe.",
    playing: "Playing {name}",
    downloadReady: "Downloaded {name}",
  },
  ja: {
    homeTitle: "サンプルバンクを作る",
    homeSub: "SXC-1のパッド配置で音声を整理",
    library: "マニュアル、コース、進捗",
    back: "SEXY ONEへ戻る",
    eyebrow: "ローカル・サンプル・ワークスペース",
    title: "Sample Lab",
    intro: "Audacityで整えたファイルをパッドに配置し、プロジェクトごとスマートフォンへ移します。",
    local: "音声はこの端末内だけに保存されます",
    temporary: "一時モード — タブを閉じる前に書き出してください",
    project: "プロジェクト",
    projectName: "プロジェクト名",
    bankSlots: "SXC-1 バンクスロット A〜D",
    bankNumber: "ユーザーバンク",
    bankName: "バンク名",
    padMap: "パッド配置",
    padHint: "割り当て済みパッドを押すと試聴できます。空パッドは割り当て先を選びます。",
    empty: "空き",
    selectedPad: "選択中の割り当て先",
    dropTitle: "ここにサンプルをドロップ",
    dropHint: "または WAV / MP3 / FLAC / .cswp を選択（最大180 MB）",
    choose: "サンプルを選ぶ",
    importing: "サンプルを読み込み中…",
    replace: "ファイルを交換",
    remove: "削除",
    name: "パッド名",
    source: "出典メモ",
    sourcePlaceholder: "ゲーム、録音、動画、セッション…",
    tags: "タグ",
    tagsPlaceholder: "kick, texture, voice",
    color: "パッド色",
    playMode: "再生方法の予定",
    oneShot: "ワンショット",
    loop: "ループ",
    bpm: "BPM（任意）",
    group: "ミュートグループ",
    none: "なし",
    fileFacts: "ファイル情報",
    recommended: "SXC-1向け WAV",
    supported: "CASIOアプリ対応形式",
    retained: "プロジェクトデータとして保持",
    recommendWav: "ハードウェアに合わせる場合は、Audacityから48 kHz / 16-bit PCM WAVで書き出してください。",
    saveShare: "プロジェクトを保存／共有",
    handoff: "スマートフォンへ",
    tools: "プロジェクトツール",
    importProject: ".sxc1labプロジェクトを読み込む",
    usage: "ストレージ",
    copyright: "使用許可のある音声だけを取り込んでください。Sample Labはゲームや動画サービスから音声を抽出しません。",
    saved: "端末内に保存しました",
    exported: "プロジェクトを準備しました",
    imported: "プロジェクトを読み込みました",
    invalidFile: "WAV、MP3、FLAC、または.cswpファイルを選んでください。",
    tooLarge: "1サンプル180 MBの上限を超えています。",
    storageFailed: "音声を永続保存できません。このタブ内で一時的に保持します。",
    readFailed: "このファイルを読み取れませんでした。",
    badProject: "有効なSample Labプロジェクトではありません。",
    removeConfirm: "このパッド割り当てを削除しますか？ SEXY ONE外の元ファイルには影響しません。",
    noPads: "スマートフォンへ移す前に、1つ以上のサンプルを割り当ててください。",
    handoffEyebrow: "スマートフォンへの引き渡し",
    handoffTitle: "1パッドずつ読み込む",
    handoffIntro: "スマートフォンでこのプロジェクトを開きます。SEXY ONEが割り当て先を表示し、実際の転送はCASIO Sampler Appで行います。",
    backPlanner: "パッド配置へ戻る",
    destination: "割り当て先",
    file: "ファイル",
    step1: "SXC-1のDATA端子をスマートフォンへ接続し、CASIO Sampler Appを開きます。",
    step2: "割り当て先のバンクとパッドを開き、サウンドアサインからファイル選択を選びます。",
    step3: "元の音声ファイルを共有またはダウンロードし、CASIOアプリで選んで確定します。",
    shareFile: "このファイルを共有",
    downloadFile: "このファイルを保存",
    nextPad: "次のパッド",
    finish: "引き渡し完了",
    progress: "{total}件中 {current}件目",
    noPreview: "プロジェクトには保存できますが、このブラウザでは試聴できません。",
    previewFailed: "ブラウザで試聴できませんが、元のファイルはそのまま保持されています。",
    playing: "再生中：{name}",
    downloadReady: "保存しました：{name}",
  },
};

let started = false;
let lang = "en";
let strings = COPY.en;
let state = null;
let overlay = null;
let db = null;
let persistentAudio = true;
let currentAudio = null;
let currentObjectUrl = null;
let renderQueued = false;
let handoffIndex = 0;
const memoryAudio = new Map();

function uid(prefix = "id") {
  try { return `${prefix}-${crypto.randomUUID()}`; } catch (_) {
    return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }
}

function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
}

function defaultSlot(index) {
  const bank = 15 + index;
  return { bank, name: `Bank ${bank}`, pads: {} };
}

function defaultProject() {
  return {
    schema: FORMAT_SCHEMA,
    id: uid("project"),
    name: "My SXC-1 set",
    activeSlot: "A",
    selectedPad: 1,
    slots: Object.fromEntries(SLOT_NAMES.map((slot, index) => [slot, defaultSlot(index)])),
    updatedAt: new Date().toISOString(),
  };
}

function normalizePad(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.blobId !== "string" || !raw.blobId) return null;
  const playMode = raw.playMode === "loop" ? "loop" : "one-shot";
  return {
    blobId: raw.blobId,
    originalName: String(raw.originalName || "sample"),
    mime: String(raw.mime || "application/octet-stream"),
    bytes: Math.max(0, Number(raw.bytes) || 0),
    name: String(raw.name || raw.originalName || "Sample").slice(0, 80),
    source: String(raw.source || "").slice(0, 240),
    tags: String(raw.tags || "").slice(0, 240),
    color: ["red", "amber", "green", "cyan", "blue", "violet", "white"].includes(raw.color) ? raw.color : "green",
    playMode,
    bpm: raw.bpm === "" || raw.bpm == null ? "" : clampInt(raw.bpm, 20, 300, ""),
    group: clampInt(raw.group, 0, 16, 0),
    duration: Math.max(0, Number(raw.duration) || 0),
    sampleRate: Math.max(0, Number(raw.sampleRate) || 0),
    channels: Math.max(0, Number(raw.channels) || 0),
    bitDepth: Math.max(0, Number(raw.bitDepth) || 0),
    waveform: Array.isArray(raw.waveform)
      ? raw.waveform.slice(0, 64).map((value) => Math.min(1, Math.max(0, Number(value) || 0)))
      : [],
    previewable: raw.previewable !== false,
  };
}

function normalizeProject(raw) {
  if (!raw || typeof raw !== "object") return defaultProject();
  const fallback = defaultProject();
  const result = {
    schema: FORMAT_SCHEMA,
    id: typeof raw.id === "string" && raw.id ? raw.id : fallback.id,
    name: String(raw.name || fallback.name).slice(0, 100),
    activeSlot: SLOT_NAMES.includes(raw.activeSlot) ? raw.activeSlot : "A",
    selectedPad: clampInt(raw.selectedPad, 1, 16, 1),
    slots: {},
    updatedAt: typeof raw.updatedAt === "string" ? raw.updatedAt : fallback.updatedAt,
  };
  SLOT_NAMES.forEach((slot, index) => {
    const source = raw.slots && typeof raw.slots[slot] === "object" ? raw.slots[slot] : {};
    const bank = clampInt(source.bank, 15, 80, 15 + index);
    const pads = {};
    if (source.pads && typeof source.pads === "object") {
      for (let number = 1; number <= 16; number += 1) {
        const pad = normalizePad(source.pads[number] || source.pads[String(number)]);
        if (pad) pads[number] = pad;
      }
    }
    result.slots[slot] = {
      bank,
      name: String(source.name || `Bank ${bank}`).slice(0, 80),
      pads,
    };
  });
  return result;
}

function loadProject() {
  try {
    const raw = localStorage.getItem(META_KEY);
    return raw ? normalizeProject(JSON.parse(raw)) : defaultProject();
  } catch (_) {
    persistentAudio = false;
    return defaultProject();
  }
}

function persistProject() {
  state.updatedAt = new Date().toISOString();
  try {
    localStorage.setItem(META_KEY, JSON.stringify(state));
  } catch (_) {
    persistentAudio = false;
  }
  publishDiagnostics();
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) {
      reject(new Error("IndexedDB unavailable"));
      return;
    }
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const nextDb = request.result;
      if (!nextDb.objectStoreNames.contains(DB_STORE)) nextDb.createObjectStore(DB_STORE, { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("IndexedDB failed"));
    request.onblocked = () => reject(new Error("IndexedDB blocked"));
  });
}

function databaseRequest(mode, operation) {
  if (!db) return Promise.reject(new Error("Database unavailable"));
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(DB_STORE, mode);
    const store = transaction.objectStore(DB_STORE);
    let request;
    try { request = operation(store); } catch (error) { reject(error); return; }
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("Audio storage failed"));
  });
}

async function putAudio(record) {
  memoryAudio.set(record.id, record);
  if (!persistentAudio || !db) return;
  try { await databaseRequest("readwrite", (store) => store.put(record)); }
  catch (_) { persistentAudio = false; announce(strings.storageFailed, "warning"); }
}

async function getAudio(id) {
  if (memoryAudio.has(id)) return memoryAudio.get(id);
  if (!db) return null;
  try {
    const record = await databaseRequest("readonly", (store) => store.get(id));
    if (record) memoryAudio.set(id, record);
    return record || null;
  } catch (_) { return null; }
}

async function deleteAudio(id) {
  memoryAudio.delete(id);
  if (!db || !persistentAudio) return;
  try { await databaseRequest("readwrite", (store) => store.delete(id)); } catch (_) { /* best effort */ }
}

function extOf(name) {
  const match = String(name || "").toLowerCase().match(/\.([a-z0-9]+)$/);
  return match ? match[1] : "";
}

function cleanName(filename) {
  const stem = String(filename || "Sample").replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").trim();
  return (stem || "Sample").slice(0, 80);
}

function parseWav(buffer) {
  try {
    const view = new DataView(buffer);
    const ascii = (offset, length) => String.fromCharCode(...new Uint8Array(buffer, offset, length));
    if (view.byteLength < 12 || ascii(0, 4) !== "RIFF" || ascii(8, 4) !== "WAVE") return null;
    let offset = 12;
    let format = null;
    let dataSize = 0;
    while (offset + 8 <= view.byteLength) {
      const id = ascii(offset, 4);
      const size = view.getUint32(offset + 4, true);
      const start = offset + 8;
      if (id === "fmt " && start + 16 <= view.byteLength) {
        format = {
          audioFormat: view.getUint16(start, true),
          channels: view.getUint16(start + 2, true),
          sampleRate: view.getUint32(start + 4, true),
          byteRate: view.getUint32(start + 8, true),
          bitDepth: view.getUint16(start + 14, true),
        };
      } else if (id === "data") {
        dataSize = size;
        break;
      }
      offset = start + size + (size % 2);
    }
    if (!format) return null;
    return { ...format, duration: format.byteRate > 0 && dataSize > 0 ? dataSize / format.byteRate : 0 };
  } catch (_) { return null; }
}

async function analyzeAudio(file) {
  const extension = extOf(file.name);
  const wav = extension === "wav" ? parseWav(await file.slice(0, Math.min(file.size, 65536)).arrayBuffer()) : null;
  const result = {
    duration: wav?.duration || 0,
    sampleRate: wav?.sampleRate || 0,
    channels: wav?.channels || 0,
    bitDepth: wav?.bitDepth || 0,
    waveform: [],
    previewable: extension !== "cswp",
  };
  if (extension === "cswp") return result;
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextClass || file.size > 48 * 1024 * 1024) return result;
  let context = null;
  try {
    context = new AudioContextClass();
    const decoded = await context.decodeAudioData(await file.arrayBuffer());
    result.duration = decoded.duration || result.duration;
    // decodeAudioData may resample to the AudioContext's playback rate (44.1
    // kHz in headless Chrome). Preserve authoritative WAV-header values and
    // use decoded metadata only for formats without an inspectable header.
    result.sampleRate = result.sampleRate || decoded.sampleRate || 0;
    result.channels = result.channels || decoded.numberOfChannels || 0;
    const data = decoded.getChannelData(0);
    const bars = 48;
    const step = Math.max(1, Math.floor(data.length / bars));
    for (let bar = 0; bar < bars; bar += 1) {
      let peak = 0;
      const end = Math.min(data.length, (bar + 1) * step);
      for (let i = bar * step; i < end; i += Math.max(1, Math.floor(step / 128))) peak = Math.max(peak, Math.abs(data[i]));
      result.waveform.push(Math.min(1, peak));
    }
  } catch (_) {
    result.previewable = false;
  } finally {
    try { await context?.close(); } catch (_) { /* harmless */ }
  }
  return result;
}

function activeBank() { return state.slots[state.activeSlot]; }
function selectedPad() { return activeBank().pads[state.selectedPad] || null; }

function allAssignedPads() {
  const rows = [];
  SLOT_NAMES.forEach((slot) => {
    const bank = state.slots[slot];
    for (let pad = 1; pad <= 16; pad += 1) {
      if (bank.pads[pad]) rows.push({ slot, bank: bank.bank, bankName: bank.name, pad, data: bank.pads[pad] });
    }
  });
  return rows;
}

function assignedBlobIds() {
  return new Set(allAssignedPads().map((row) => row.data.blobId));
}

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  const value = bytes / (1024 ** index);
  return `${value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

function formatDuration(seconds) {
  if (!seconds) return "—";
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 1 : 0)}s`;
  return `${Math.floor(seconds / 60)}:${String(Math.round(seconds % 60)).padStart(2, "0")}`;
}

function fill(template, values) {
  return String(template).replace(/\{(\w+)\}/g, (_, key) => String(values[key] ?? ""));
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function labeledField(labelText, control) {
  const label = el("label", "sample-field");
  label.append(el("span", "sample-field-label", labelText), control);
  return label;
}

function textInput(id, value, maxLength, placeholder = "") {
  const input = document.createElement("input");
  input.id = id;
  input.type = "text";
  input.value = value;
  input.maxLength = maxLength;
  input.placeholder = placeholder;
  return input;
}

function option(value, text, selected = false) {
  const node = document.createElement("option");
  node.value = String(value);
  node.textContent = text;
  node.selected = selected;
  return node;
}

function announce(message, kind = "ok") {
  const status = overlay?.querySelector("#sample-lab-status");
  if (!status) return;
  status.textContent = message;
  status.dataset.kind = kind;
}

function stopPreview() {
  if (currentAudio) {
    try { currentAudio.pause(); } catch (_) { /* harmless */ }
    currentAudio = null;
  }
  if (currentObjectUrl) {
    URL.revokeObjectURL(currentObjectUrl);
    currentObjectUrl = null;
  }
  overlay?.querySelectorAll(".sample-pad.is-playing").forEach((pad) => pad.classList.remove("is-playing"));
}

async function previewPad(button, pad) {
  stopPreview();
  if (!pad.previewable) { announce(strings.noPreview, "warning"); return; }
  const record = await getAudio(pad.blobId);
  if (!record?.blob) { announce(strings.previewFailed, "warning"); return; }
  try {
    currentObjectUrl = URL.createObjectURL(record.blob);
    currentAudio = new Audio(currentObjectUrl);
    currentAudio.loop = pad.playMode === "loop";
    currentAudio.addEventListener("ended", stopPreview, { once: true });
    await currentAudio.play();
    button?.classList.add("is-playing");
    announce(fill(strings.playing, { name: pad.name }));
  } catch (_) {
    stopPreview();
    announce(strings.previewFailed, "warning");
  }
}

function setRouteActive() {
  const active = window.location.hash === ROUTE || window.location.hash.startsWith(`${ROUTE}/`);
  document.body.classList.toggle("sample-lab-active", active);
  const app = document.getElementById("app");
  if (app) active ? app.setAttribute("aria-hidden", "true") : app.removeAttribute("aria-hidden");
  if (!overlay) return;
  overlay.hidden = !active;
  if (active) {
    document.title = `${strings.title} — SEXY ONE`;
    renderPlanner();
    requestAnimationFrame(() => overlay.querySelector("h1")?.focus());
  } else {
    stopPreview();
    document.title = "SEXY ONE — SXC-1 Trainer";
  }
}

function enhanceHome() {
  const wizard = document.getElementById("sxc1-wizard-actions");
  const primary = document.getElementById("btn-primary-training");
  const browse = document.getElementById("sxc1-browse-library");
  if (!wizard || !primary || !browse) return;
  let sample = document.getElementById("btn-sample-lab");
  if (!sample) {
    sample = el("a", "wizard-choice wizard-no sample-lab-home-action");
    sample.id = "btn-sample-lab";
    sample.href = ROUTE;
    sample.append(el("strong", "", strings.homeTitle), el("small", "primary-training-card", strings.homeSub));
  }
  if (wizard.children.length !== 2 || wizard.children[0] !== primary.parentElement || wizard.children[1] !== sample) {
    const primaryShell = primary.parentElement;
    wizard.replaceChildren(primaryShell, sample);
  }
  browse.classList.remove("wizard-choice", "wizard-no");
  browse.classList.add("home-disclosure", "sample-library-disclosure");
  const summary = browse.querySelector(":scope > summary");
  // Do not rewrite an already-correct text node: this function runs from a
  // MutationObserver, and an unconditional textContent assignment would
  // schedule itself forever on an otherwise settled Home screen.
  if (summary && summary.textContent !== strings.library) summary.textContent = strings.library;
  if (browse.previousElementSibling !== wizard) wizard.insertAdjacentElement("afterend", browse);
}

function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    if (!overlay.hidden && document.body.classList.contains("sample-lab-active")) renderPlanner();
  });
}

function projectHeader() {
  const header = el("header", "sample-lab-header");
  const back = el("a", "sample-back", `← ${strings.back}`);
  back.href = "#/";
  const badge = el("span", `sample-local-badge${persistentAudio ? "" : " is-warning"}`, persistentAudio ? strings.local : strings.temporary);
  header.append(back, badge);
  return header;
}

function hero() {
  const section = el("section", "sample-hero");
  section.append(el("p", "sample-eyebrow", strings.eyebrow));
  const title = el("h1", "", strings.title);
  title.tabIndex = -1;
  section.append(title, el("p", "sample-lede", strings.intro));
  const status = el("p", "sample-status", "");
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  section.append(status);
  return section;
}

function bankStrip() {
  const section = el("section", "sample-panel sample-bank-panel");
  section.setAttribute("aria-labelledby", "sample-bank-heading");
  const heading = el("h2", "sample-panel-heading", strings.bankSlots);
  heading.id = "sample-bank-heading";
  const tabs = el("div", "sample-bank-tabs");
  tabs.setAttribute("role", "tablist");
  SLOT_NAMES.forEach((slot) => {
    const bank = state.slots[slot];
    const button = el("button", `sample-bank-tab${slot === state.activeSlot ? " is-active" : ""}`);
    button.type = "button";
    button.dataset.slot = slot;
    button.setAttribute("role", "tab");
    button.setAttribute("aria-selected", String(slot === state.activeSlot));
    button.append(el("strong", "", slot), el("small", "", `BANK ${bank.bank}`));
    button.addEventListener("click", () => {
      state.activeSlot = slot;
      persistProject();
      stopPreview();
      renderPlanner();
      requestAnimationFrame(() => overlay.querySelector(`.sample-bank-tab[data-slot="${slot}"]`)?.focus());
    });
    tabs.append(button);
  });
  const fields = el("div", "sample-bank-fields");
  const bankSelect = document.createElement("select");
  bankSelect.id = "sample-bank-number";
  for (let bank = 15; bank <= 80; bank += 1) bankSelect.append(option(bank, `BANK ${bank}`, bank === activeBank().bank));
  bankSelect.addEventListener("change", () => {
    activeBank().bank = clampInt(bankSelect.value, 15, 80, activeBank().bank);
    persistProject();
    scheduleRender();
  });
  const bankName = textInput("sample-bank-name", activeBank().name, 80);
  bankName.addEventListener("input", () => { activeBank().name = bankName.value; persistProject(); });
  fields.append(labeledField(strings.bankNumber, bankSelect), labeledField(strings.bankName, bankName));
  section.append(heading, tabs, fields);
  return section;
}

function padGrid() {
  const section = el("section", "sample-panel sample-pad-panel");
  section.setAttribute("aria-labelledby", "sample-pad-heading");
  const top = el("div", "sample-section-top");
  const heading = el("h2", "sample-panel-heading", strings.padMap);
  heading.id = "sample-pad-heading";
  top.append(heading, el("p", "sample-help", strings.padHint));
  const grid = el("div", "sample-pad-grid");
  for (let number = 1; number <= 16; number += 1) {
    const pad = activeBank().pads[number] || null;
    const button = el("button", `sample-pad sample-pad-${pad?.color || "empty"}${number === state.selectedPad ? " is-selected" : ""}`);
    button.type = "button";
    button.dataset.pad = String(number);
    button.setAttribute("aria-pressed", String(number === state.selectedPad));
    button.setAttribute("aria-label", pad ? `Pad ${number}: ${pad.name}` : `Pad ${number}: ${strings.empty}`);
    button.append(el("span", "sample-pad-number", String(number)), el("strong", "sample-pad-name", pad?.name || strings.empty));
    if (pad) button.append(el("span", "sample-pad-duration", formatDuration(pad.duration)));
    button.addEventListener("click", () => {
      state.selectedPad = number;
      persistProject();
      renderPlanner();
      const current = overlay.querySelector(`.sample-pad[data-pad="${number}"]`);
      current?.focus();
      if (pad) previewPad(current, pad);
    });
    grid.append(button);
  }
  section.append(top, grid);
  return section;
}

function waveform(pad) {
  const figure = el("figure", "sample-waveform");
  figure.setAttribute("aria-label", strings.fileFacts);
  if (pad.waveform.length) {
    pad.waveform.forEach((value) => {
      const bar = el("span", "");
      bar.style.height = `${Math.max(8, Math.round(value * 100))}%`;
      figure.append(bar);
    });
  } else {
    figure.append(el("span", "sample-waveform-empty", pad.previewable ? "••••••••" : "CSWP"));
  }
  return figure;
}

function fileInput(id) {
  const input = document.createElement("input");
  input.id = id;
  input.type = "file";
  input.accept = ".wav,.mp3,.flac,.cswp,audio/wav,audio/mpeg,audio/flac";
  input.hidden = true;
  input.addEventListener("change", () => {
    const file = input.files && input.files[0];
    if (file) importSample(file);
    input.value = "";
  });
  return input;
}

function emptyPadEditor(section) {
  const drop = el("div", "sample-dropzone");
  drop.tabIndex = 0;
  drop.append(el("strong", "", strings.dropTitle), el("span", "", strings.dropHint));
  const input = fileInput("sample-file-input");
  const choose = el("button", "sample-button sample-button-primary", strings.choose);
  choose.type = "button";
  choose.addEventListener("click", () => input.click());
  drop.append(input, choose);
  const setDrag = (active) => drop.classList.toggle("is-dragging", active);
  drop.addEventListener("dragenter", (event) => { event.preventDefault(); setDrag(true); });
  drop.addEventListener("dragover", (event) => { event.preventDefault(); setDrag(true); });
  drop.addEventListener("dragleave", () => setDrag(false));
  drop.addEventListener("drop", (event) => {
    event.preventDefault();
    setDrag(false);
    const file = event.dataTransfer?.files?.[0];
    if (file) importSample(file);
  });
  section.append(drop);
}

function metadataEditor(section, pad) {
  section.append(waveform(pad));
  const facts = el("div", "sample-file-facts");
  const recommended = extOf(pad.originalName) === "wav" && pad.sampleRate === 48000 && pad.bitDepth === 16;
  const compatibility = extOf(pad.originalName) === "cswp" ? strings.retained : (recommended ? strings.recommended : strings.supported);
  [
    pad.originalName,
    formatBytes(pad.bytes),
    formatDuration(pad.duration),
    pad.sampleRate ? `${(pad.sampleRate / 1000).toFixed(1)} kHz` : null,
    pad.bitDepth ? `${pad.bitDepth}-bit` : null,
    pad.channels ? `${pad.channels} ch` : null,
    compatibility,
  ].filter(Boolean).forEach((text) => facts.append(el("span", recommended && text === compatibility ? "is-ready" : "", text)));
  section.append(facts);
  if (!recommended && extOf(pad.originalName) !== "cswp") section.append(el("p", "sample-format-note", strings.recommendWav));

  const form = el("div", "sample-metadata-grid");
  const name = textInput("sample-pad-name", pad.name, 80);
  const source = textInput("sample-pad-source", pad.source, 240, strings.sourcePlaceholder);
  const tags = textInput("sample-pad-tags", pad.tags, 240, strings.tagsPlaceholder);
  const color = document.createElement("select");
  color.id = "sample-pad-color";
  ["red", "amber", "green", "cyan", "blue", "violet", "white"].forEach((value) => color.append(option(value, value[0].toUpperCase() + value.slice(1), value === pad.color)));
  const playMode = document.createElement("select");
  playMode.id = "sample-pad-play-mode";
  playMode.append(option("one-shot", strings.oneShot, pad.playMode === "one-shot"), option("loop", strings.loop, pad.playMode === "loop"));
  const bpm = document.createElement("input");
  bpm.id = "sample-pad-bpm";
  bpm.type = "number";
  bpm.min = "20";
  bpm.max = "300";
  bpm.inputMode = "numeric";
  bpm.value = pad.bpm;
  const group = document.createElement("select");
  group.id = "sample-pad-group";
  group.append(option(0, strings.none, pad.group === 0));
  for (let value = 1; value <= 16; value += 1) group.append(option(value, String(value), pad.group === value));
  const bind = (control, key, map = (value) => value, reflect = null) => control.addEventListener("input", () => {
    const current = selectedPad();
    if (!current) return;
    current[key] = map(control.value);
    persistProject();
    if (reflect) reflect(current[key]);
  });
  bind(name, "name", (value) => value.slice(0, 80), (value) => {
    const button = overlay.querySelector(`.sample-pad[data-pad="${state.selectedPad}"]`);
    const label = button?.querySelector(".sample-pad-name");
    if (label) label.textContent = value || strings.empty;
    if (button) button.setAttribute("aria-label", `Pad ${state.selectedPad}: ${value || strings.empty}`);
  });
  bind(source, "source", (value) => value.slice(0, 240));
  bind(tags, "tags", (value) => value.slice(0, 240));
  bind(color, "color", (value) => value, (value) => {
    const button = overlay.querySelector(`.sample-pad[data-pad="${state.selectedPad}"]`);
    if (!button) return;
    Array.from(button.classList).filter((item) => item.startsWith("sample-pad-")).forEach((item) => button.classList.remove(item));
    button.classList.add(`sample-pad-${value}`);
  });
  bind(playMode, "playMode");
  bind(bpm, "bpm", (value) => value === "" ? "" : clampInt(value, 20, 300, ""));
  bind(group, "group", (value) => clampInt(value, 0, 16, 0));
  form.append(
    labeledField(strings.name, name),
    labeledField(strings.source, source),
    labeledField(strings.tags, tags),
    labeledField(strings.color, color),
    labeledField(strings.playMode, playMode),
    labeledField(strings.bpm, bpm),
    labeledField(strings.group, group),
  );
  section.append(form);
  const input = fileInput("sample-replace-input");
  const actions = el("div", "sample-action-row");
  const replace = el("button", "sample-button sample-button-secondary", strings.replace);
  replace.type = "button";
  replace.addEventListener("click", () => input.click());
  const remove = el("button", "sample-button sample-button-danger", strings.remove);
  remove.type = "button";
  remove.addEventListener("click", async () => {
    if (!window.confirm(strings.removeConfirm)) return;
    const old = selectedPad();
    if (!old) return;
    delete activeBank().pads[state.selectedPad];
    persistProject();
    stopPreview();
    if (!assignedBlobIds().has(old.blobId)) await deleteAudio(old.blobId);
    renderPlanner();
  });
  actions.append(input, replace, remove);
  section.append(actions);
}

function padEditor() {
  const section = el("section", "sample-panel sample-editor");
  section.setAttribute("aria-labelledby", "sample-editor-heading");
  const heading = el("h2", "sample-panel-heading", `${strings.selectedPad}: ${state.activeSlot} / BANK ${activeBank().bank} / PAD ${state.selectedPad}`);
  heading.id = "sample-editor-heading";
  section.append(heading);
  const pad = selectedPad();
  if (pad) metadataEditor(section, pad); else emptyPadEditor(section);
  return section;
}

function projectTools() {
  const details = el("details", "sample-project-tools");
  const summary = el("summary", "", strings.tools);
  const content = el("div", "sample-project-tools-body");
  const importInput = document.createElement("input");
  importInput.id = "sample-project-input";
  importInput.type = "file";
  importInput.accept = ".sxc1lab,application/octet-stream";
  importInput.hidden = true;
  importInput.addEventListener("change", async () => {
    const file = importInput.files?.[0];
    if (file) await importProjectFile(file);
    importInput.value = "";
  });
  const importLabel = el("button", "sample-button sample-button-secondary", strings.importProject);
  importLabel.type = "button";
  importLabel.addEventListener("click", () => importInput.click());
  const usage = el("p", "sample-storage-usage", `${strings.usage}: ${allAssignedPads().length} pads / ${formatBytes(allAssignedPads().reduce((sum, row) => sum + row.data.bytes, 0))}`);
  content.append(importInput, importLabel, usage, el("p", "sample-copyright", strings.copyright));
  details.append(summary, content);
  return details;
}

function plannerFooter() {
  const footer = el("footer", "sample-planner-footer");
  const actions = el("div", "sample-primary-actions");
  const save = el("button", "sample-button sample-button-secondary", strings.saveShare);
  save.id = "btn-sample-project-export";
  save.type = "button";
  save.addEventListener("click", exportAndShareProject);
  const handoff = el("button", "sample-button sample-button-primary", strings.handoff);
  handoff.id = "btn-sample-handoff";
  handoff.type = "button";
  handoff.addEventListener("click", () => {
    if (!allAssignedPads().length) { announce(strings.noPads, "warning"); return; }
    handoffIndex = 0;
    stopPreview();
    renderHandoff();
  });
  actions.append(save, handoff);
  footer.append(actions, projectTools());
  return footer;
}

function renderPlanner() {
  if (!overlay || overlay.hidden) return;
  overlay.dataset.view = "planner";
  const content = el("div", "sample-lab-shell");
  const project = el("section", "sample-project-heading");
  const projectName = textInput("sample-project-name", state.name, 100);
  projectName.addEventListener("input", () => { state.name = projectName.value; persistProject(); });
  project.append(labeledField(strings.projectName, projectName));
  content.append(projectHeader(), hero(), project, bankStrip(), padGrid(), padEditor(), plannerFooter());
  overlay.replaceChildren(content);
  publishDiagnostics();
}

async function importSample(file) {
  const extension = extOf(file.name);
  if (!SUPPORTED_EXTENSIONS.has(extension)) { announce(strings.invalidFile, "warning"); return; }
  if (file.size > MAX_AUDIO_BYTES) { announce(strings.tooLarge, "warning"); return; }
  announce(strings.importing);
  try {
    const analysis = await analyzeAudio(file);
    const blobId = uid("audio");
    const blob = file.slice(0, file.size, file.type || "application/octet-stream");
    await putAudio({ id: blobId, blob, name: file.name, type: blob.type });
    const old = selectedPad();
    activeBank().pads[state.selectedPad] = normalizePad({
      blobId,
      originalName: file.name,
      mime: blob.type,
      bytes: file.size,
      name: old?.name || cleanName(file.name),
      source: old?.source || "",
      tags: old?.tags || "",
      color: old?.color || "green",
      playMode: old?.playMode || "one-shot",
      bpm: old?.bpm || "",
      group: old?.group || 0,
      ...analysis,
    });
    persistProject();
    if (old && !assignedBlobIds().has(old.blobId)) await deleteAudio(old.blobId);
    renderPlanner();
    announce(strings.saved);
  } catch (_) {
    announce(strings.readFailed, "warning");
  }
}

function projectFilename() {
  const safe = (state.name || "sxc1-project").trim().replace(/[^a-z0-9._-]+/gi, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "sxc1-project";
  return `${safe}.sxc1lab`;
}

async function exportProjectBlob() {
  const blobs = [];
  const files = [];
  let offset = 0;
  for (const blobId of assignedBlobIds()) {
    const record = await getAudio(blobId);
    if (!record?.blob) throw new Error(`Missing audio ${blobId}`);
    files.push({ id: blobId, name: record.name || "sample", type: record.type || record.blob.type || "application/octet-stream", offset, length: record.blob.size });
    blobs.push(record.blob);
    offset += record.blob.size;
  }
  const manifest = { schema: FORMAT_SCHEMA, createdBy: "SEXY ONE Sample Lab", exportedAt: new Date().toISOString(), project: state, files };
  const manifestBytes = new TextEncoder().encode(JSON.stringify(manifest));
  if (manifestBytes.byteLength > MAX_MANIFEST_BYTES) throw new Error("Manifest too large");
  const header = new Uint8Array(12);
  header.set(new TextEncoder().encode(FORMAT_MAGIC), 0);
  new DataView(header.buffer).setUint32(8, manifestBytes.byteLength, true);
  return new Blob([header, manifestBytes, ...blobs], { type: "application/octet-stream" });
}

function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
}

async function shareOrDownload(file, fallbackName) {
  if (navigator.share && navigator.canShare) {
    try {
      if (navigator.canShare({ files: [file] })) {
        await navigator.share({ files: [file], title: file.name });
        return "shared";
      }
    } catch (error) {
      if (error?.name === "AbortError") return "cancelled";
    }
  }
  downloadBlob(file, fallbackName);
  return "downloaded";
}

async function exportAndShareProject() {
  try {
    const blob = await exportProjectBlob();
    const name = projectFilename();
    const file = new File([blob], name, { type: blob.type, lastModified: Date.now() });
    await shareOrDownload(file, name);
    announce(strings.exported);
  } catch (_) { announce(strings.readFailed, "warning"); }
}

async function readProjectManifest(file) {
  if (!(file instanceof Blob) || file.size < 12) throw new Error("Short file");
  const header = await file.slice(0, 12).arrayBuffer();
  const magic = new TextDecoder().decode(new Uint8Array(header, 0, 8));
  if (magic !== FORMAT_MAGIC) throw new Error("Wrong magic");
  const manifestLength = new DataView(header).getUint32(8, true);
  if (!manifestLength || manifestLength > MAX_MANIFEST_BYTES || 12 + manifestLength > file.size) throw new Error("Bad manifest size");
  const manifest = JSON.parse(await file.slice(12, 12 + manifestLength).text());
  if (manifest.schema !== FORMAT_SCHEMA || !manifest.project || !Array.isArray(manifest.files)) throw new Error("Unsupported schema");
  const project = normalizeProject(manifest.project);
  const referenced = new Set();
  SLOT_NAMES.forEach((slot) => Object.values(project.slots[slot].pads).forEach((pad) => referenced.add(pad.blobId)));
  const fileIds = new Set();
  for (const entry of manifest.files) {
    if (!entry || typeof entry.id !== "string" || fileIds.has(entry.id)) throw new Error("Bad file table");
    const offset = Number(entry.offset);
    const length = Number(entry.length);
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || 12 + manifestLength + offset + length > file.size) throw new Error("Bad file range");
    fileIds.add(entry.id);
  }
  for (const id of referenced) if (!fileIds.has(id)) throw new Error("Missing referenced audio");
  return { manifest, project, payloadOffset: 12 + manifestLength };
}

async function importProjectFile(file) {
  try {
    const parsed = await readProjectManifest(file);
    const nextRecords = [];
    for (const entry of parsed.manifest.files) {
      nextRecords.push({
        id: entry.id,
        name: String(entry.name || "sample"),
        type: String(entry.type || "application/octet-stream"),
        blob: file.slice(parsed.payloadOffset + entry.offset, parsed.payloadOffset + entry.offset + entry.length, entry.type || "application/octet-stream"),
      });
    }
    for (const record of nextRecords) await putAudio(record);
    state = parsed.project;
    persistProject();
    stopPreview();
    renderPlanner();
    announce(strings.imported);
    return true;
  } catch (_) {
    announce(strings.badProject, "warning");
    return false;
  }
}

function renderHandoff() {
  const rows = allAssignedPads();
  if (!rows.length) { renderPlanner(); announce(strings.noPads, "warning"); return; }
  handoffIndex = Math.min(Math.max(0, handoffIndex), rows.length - 1);
  const row = rows[handoffIndex];
  overlay.dataset.view = "handoff";
  const shell = el("div", "sample-lab-shell sample-handoff-shell");
  const header = projectHeader();
  const back = el("a", "sample-handoff-back", `← ${strings.backPlanner}`);
  back.href = ROUTE;
  back.addEventListener("click", (event) => { event.preventDefault(); renderPlanner(); });
  const heroSection = el("section", "sample-hero sample-handoff-hero");
  heroSection.append(el("p", "sample-eyebrow", strings.handoffEyebrow));
  const title = el("h1", "", strings.handoffTitle);
  title.tabIndex = -1;
  heroSection.append(title, el("p", "sample-lede", strings.handoffIntro), back);
  const card = el("section", "sample-handoff-card");
  card.setAttribute("aria-labelledby", "sample-handoff-destination");
  const progress = el("p", "sample-handoff-progress", fill(strings.progress, { current: handoffIndex + 1, total: rows.length }));
  const destination = el("h2", "sample-handoff-destination", `${row.slot} / BANK ${row.bank} / PAD ${row.pad}`);
  destination.id = "sample-handoff-destination";
  card.append(progress, destination, el("strong", "sample-handoff-name", row.data.name));
  const info = el("dl", "sample-handoff-info");
  info.append(el("dt", "", strings.file), el("dd", "", `${row.data.originalName} · ${formatBytes(row.data.bytes)}`));
  card.append(info);
  const steps = el("ol", "sample-handoff-steps");
  steps.append(el("li", "", strings.step1), el("li", "", strings.step2), el("li", "", strings.step3));
  card.append(steps);
  const status = el("p", "sample-status", "");
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  card.append(status);
  const actions = el("div", "sample-primary-actions");
  const share = el("button", "sample-button sample-button-secondary", navigator.share ? strings.shareFile : strings.downloadFile);
  share.id = "btn-sample-share-file";
  share.type = "button";
  share.addEventListener("click", async () => {
    const record = await getAudio(row.data.blobId);
    if (!record?.blob) { announce(strings.readFailed, "warning"); return; }
    const file = new File([record.blob], row.data.originalName, { type: row.data.mime || record.blob.type, lastModified: Date.now() });
    const result = await shareOrDownload(file, row.data.originalName);
    if (result === "downloaded") announce(fill(strings.downloadReady, { name: row.data.originalName }));
  });
  const next = el("button", "sample-button sample-button-primary", handoffIndex === rows.length - 1 ? strings.finish : strings.nextPad);
  next.id = "btn-sample-next-pad";
  next.type = "button";
  next.addEventListener("click", () => {
    if (handoffIndex >= rows.length - 1) renderPlanner();
    else { handoffIndex += 1; renderHandoff(); requestAnimationFrame(() => overlay.querySelector("h1")?.focus()); }
  });
  actions.append(share, next);
  card.append(actions);
  shell.append(header, heroSection, card);
  overlay.replaceChildren(shell);
  title.focus();
  publishDiagnostics();
}

function publishDiagnostics() {
  window.__SXC1_SAMPLE_LAB = {
    ready: started,
    route: ROUTE,
    schema: FORMAT_SCHEMA,
    storage: persistentAudio ? "indexeddb" : "temporary",
    projectId: state?.id || null,
    activeSlot: state?.activeSlot || null,
    selectedPad: state?.selectedPad || null,
    assignedPads: state ? allAssignedPads().map((row) => ({ slot: row.slot, bank: row.bank, pad: row.pad, name: row.data.name, filename: row.data.originalName })) : [],
    exportProjectBlob,
    importProjectFile,
  };
}

function createOverlay() {
  const main = document.createElement("main");
  main.id = "sxc1-sample-lab";
  main.hidden = true;
  main.dataset.lang = lang;
  document.body.append(main);
  return main;
}

export async function startSampleLab(options = {}) {
  if (started) return;
  started = true;
  lang = options.lang === "ja" ? "ja" : "en";
  strings = COPY[lang];
  state = loadProject();
  overlay = createOverlay();
  try { db = await openDatabase(); }
  catch (_) { persistentAudio = false; }
  enhanceHome();
  setRouteActive();
  window.addEventListener("hashchange", setRouteActive);
  new MutationObserver(() => {
    enhanceHome();
    if (window.location.hash.startsWith(ROUTE)) setRouteActive();
  }).observe(document.getElementById("app") || document.body, { childList: true, subtree: true });
  publishDiagnostics();
}

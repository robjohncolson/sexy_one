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
const MAX_BATCH_FILES = 64;
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
    inbox: "Sample Inbox",
    inboxHint: "Audition a sound, then press its destination pad. You can also drag it on desktop.",
    inboxEmpty: "Drop an Audacity export batch here. Nothing is assigned until you place it.",
    inboxDrop: "Drop WAV, MP3, FLAC, or .cswp files",
    addSamples: "Add samples",
    fillEmpty: "Fill empty pads",
    assignNext: "Assign next empty",
    removeInbox: "Remove from Inbox",
    removeInboxConfirm: "Delete this unassigned sample from Sample Lab? The original file outside SEXY ONE is not affected.",
    inboxSelected: "{name} selected — choose a destination pad.",
    inboxImported: "Added {added} sample(s) to the Inbox{rejected}.",
    inboxRejected: "; skipped {count}",
    batchLimit: "Only the first 64 files in one batch are imported.",
    noInbox: "The Inbox is empty.",
    noEmptyPads: "This bank has no empty pads.",
    autoFilled: "Placed {count} sample(s) on empty pads.",
    assignedTo: "Assigned {name} to {slot} / BANK {bank} / PAD {pad}.",
    replacedTo: "Assigned {name}; {old} returned to the Inbox.",
    moveSwap: "Move / swap",
    returnInbox: "Return to Inbox",
    moveSelected: "{name} is ready to move — choose any destination pad or bank.",
    movedTo: "Moved {name} to {slot} / BANK {bank} / PAD {pad}.",
    swapped: "Swapped {first} and {second}.",
    placement: "Placement ready",
    cancel: "Cancel",
    placementCancelled: "Placement cancelled.",
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
    noPads: "Assign at least one sample before starting phone handoff.",
    checking: "Checking project…",
    validationEyebrow: "HANDOFF CHECK",
    validationTitle: "Review the project",
    validationReady: "Everything is ready for phone handoff.",
    validationIntro: "Resolve anything important now, or continue with the supported files as they are.",
    validationBlocking: "Handoff is blocked until missing local audio is restored.",
    validationInbox: "{count} sample(s) are still unassigned in the Inbox.",
    validationBanks: "Bank {bank} is used by more than one A-D slot.",
    validationFormat: "{count} assigned file(s) are supported by CASIO but are not 48 kHz / 16-bit WAV.",
    validationNames: "{count} pad name(s) are duplicated within a bank.",
    validationMissing: "{count} assigned audio file(s) are missing from local storage.",
    fixProject: "Back to planner",
    continueHandoff: "Continue to handoff",
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
    inbox: "サンプル受け皿",
    inboxHint: "音を試聴してから割り当て先パッドを押します。パソコンではドラッグもできます。",
    inboxEmpty: "Audacityの書き出しをまとめてドロップしてください。配置するまでパッドには割り当てません。",
    inboxDrop: "WAV / MP3 / FLAC / .cswp をドロップ",
    addSamples: "サンプルを追加",
    fillEmpty: "空きパッドへ配置",
    assignNext: "次の空きへ配置",
    removeInbox: "受け皿から削除",
    removeInboxConfirm: "この未割り当てサンプルをSample Labから削除しますか？ 外部の元ファイルには影響しません。",
    inboxSelected: "{name}を選択中 — 割り当て先パッドを選んでください。",
    inboxImported: "{added}件を受け皿へ追加しました{rejected}。",
    inboxRejected: "（{count}件をスキップ）",
    batchLimit: "一度に読み込むのは先頭64ファイルまでです。",
    noInbox: "受け皿は空です。",
    noEmptyPads: "このバンクに空きパッドはありません。",
    autoFilled: "空きパッドへ{count}件を配置しました。",
    assignedTo: "{name}を {slot} / BANK {bank} / PAD {pad} へ配置しました。",
    replacedTo: "{name}を配置し、{old}を受け皿へ戻しました。",
    moveSwap: "移動／入れ替え",
    returnInbox: "受け皿へ戻す",
    moveSelected: "{name}の移動先パッドまたはバンクを選んでください。",
    movedTo: "{name}を {slot} / BANK {bank} / PAD {pad} へ移動しました。",
    swapped: "{first}と{second}を入れ替えました。",
    placement: "配置先を選択中",
    cancel: "キャンセル",
    placementCancelled: "配置をキャンセルしました。",
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
    noPads: "スマートフォンへ移す前に、1つ以上のサンプルを割り当ててください。",
    checking: "プロジェクトを確認中…",
    validationEyebrow: "引き渡し前の確認",
    validationTitle: "プロジェクトを確認",
    validationReady: "スマートフォンへの引き渡し準備ができました。",
    validationIntro: "必要な項目を修正するか、対応形式のまま続行できます。",
    validationBlocking: "ローカル音声の欠落を復元するまで引き渡しできません。",
    validationInbox: "受け皿に未割り当てサンプルが{count}件あります。",
    validationBanks: "BANK {bank}が複数のA〜Dスロットで使われています。",
    validationFormat: "割り当て済みの{count}件はCASIO対応形式ですが、48 kHz / 16-bit WAVではありません。",
    validationNames: "同じバンク内に重複したパッド名が{count}件あります。",
    validationMissing: "ローカル保存から音声ファイルが{count}件見つかりません。",
    fixProject: "配置画面へ戻る",
    continueHandoff: "引き渡しを続ける",
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
let armedPlacement = null;
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
    inbox: [],
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

function normalizeInboxItem(raw) {
  const pad = normalizePad(raw);
  if (!pad) return null;
  return {
    ...pad,
    id: typeof raw.id === "string" && raw.id ? raw.id : uid("inbox"),
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
    // M12 projects have no inbox property. Absence migrates to an empty tray
    // while duplicate/malformed item ids are rejected locally.
    inbox: [],
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
  const inboxIds = new Set();
  if (Array.isArray(raw.inbox)) {
    raw.inbox.slice(0, 256).forEach((candidate) => {
      const item = normalizeInboxItem(candidate);
      if (item && !inboxIds.has(item.id)) {
        inboxIds.add(item.id);
        result.inbox.push(item);
      }
    });
  }
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

function referencedBlobIds(project = state) {
  const ids = new Set();
  SLOT_NAMES.forEach((slot) => Object.values(project.slots[slot].pads).forEach((pad) => ids.add(pad.blobId)));
  project.inbox.forEach((item) => ids.add(item.blobId));
  return ids;
}

function firstEmptyPad(slot = state.activeSlot) {
  for (let number = 1; number <= 16; number += 1) {
    if (!state.slots[slot].pads[number]) return number;
  }
  return null;
}

function returnableInboxItem(pad) {
  return { ...pad, id: uid("inbox") };
}

function cancelPlacement(shouldRender = true) {
  armedPlacement = null;
  if (shouldRender) {
    renderPlanner();
    announce(strings.placementCancelled);
  }
}

function armInbox(item) {
  armedPlacement = { type: "inbox", id: item.id };
  renderPlanner();
  const card = overlay.querySelector(`.sample-inbox-card[data-inbox-id="${item.id}"]`);
  card?.focus();
  previewPad(card, item);
  announce(fill(strings.inboxSelected, { name: item.name }));
}

function armPad(slot, number) {
  const pad = state.slots[slot]?.pads[number];
  if (!pad) return;
  armedPlacement = { type: "pad", slot, pad: number };
  renderPlanner();
  announce(fill(strings.moveSelected, { name: pad.name }));
}

function placeArmedOnPad(slot, number) {
  if (!armedPlacement || !state.slots[slot]) return false;
  stopPreview();
  const destinationBank = state.slots[slot];
  const destination = destinationBank.pads[number] || null;
  if (armedPlacement.type === "inbox") {
    const index = state.inbox.findIndex((item) => item.id === armedPlacement.id);
    if (index < 0) { cancelPlacement(); return false; }
    const [item] = state.inbox.splice(index, 1);
    const { id: _itemId, ...pad } = item;
    if (destination) state.inbox.push(returnableInboxItem(destination));
    destinationBank.pads[number] = pad;
    state.activeSlot = slot;
    state.selectedPad = number;
    armedPlacement = null;
    persistProject();
    renderPlanner();
    announce(fill(destination ? strings.replacedTo : strings.assignedTo, {
      name: pad.name,
      old: destination?.name || "",
      slot,
      bank: destinationBank.bank,
      pad: number,
    }));
    return true;
  }
  if (armedPlacement.type === "pad") {
    const sourceBank = state.slots[armedPlacement.slot];
    const source = sourceBank?.pads[armedPlacement.pad] || null;
    if (!source) { cancelPlacement(); return false; }
    if (armedPlacement.slot === slot && armedPlacement.pad === number) {
      cancelPlacement();
      return false;
    }
    if (destination) sourceBank.pads[armedPlacement.pad] = destination;
    else delete sourceBank.pads[armedPlacement.pad];
    destinationBank.pads[number] = source;
    state.activeSlot = slot;
    state.selectedPad = number;
    armedPlacement = null;
    persistProject();
    renderPlanner();
    announce(fill(destination ? strings.swapped : strings.movedTo, {
      name: source.name,
      first: source.name,
      second: destination?.name || "",
      slot,
      bank: destinationBank.bank,
      pad: number,
    }));
    return true;
  }
  return false;
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
  overlay?.querySelectorAll(".sample-pad.is-playing, .sample-inbox-card.is-playing")
    .forEach((control) => control.classList.remove("is-playing"));
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
    armedPlacement = null;
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

function inboxFileInput() {
  const input = document.createElement("input");
  input.id = "sample-inbox-input";
  input.type = "file";
  input.multiple = true;
  input.accept = ".wav,.mp3,.flac,.cswp,audio/wav,audio/mpeg,audio/flac";
  input.hidden = true;
  input.addEventListener("change", async () => {
    const files = Array.from(input.files || []);
    input.value = "";
    if (files.length) await importFilesToInbox(files);
  });
  return input;
}

function assignSelectedInboxNext() {
  if (armedPlacement?.type !== "inbox") return;
  const number = firstEmptyPad();
  if (number == null) { announce(strings.noEmptyPads, "warning"); return; }
  placeArmedOnPad(state.activeSlot, number);
  requestAnimationFrame(() => overlay.querySelector(`.sample-pad[data-pad="${number}"]`)?.focus());
}

async function removeSelectedInbox() {
  if (armedPlacement?.type !== "inbox") return;
  const index = state.inbox.findIndex((item) => item.id === armedPlacement.id);
  if (index < 0 || !window.confirm(strings.removeInboxConfirm)) return;
  const [removed] = state.inbox.splice(index, 1);
  armedPlacement = null;
  persistProject();
  if (!referencedBlobIds().has(removed.blobId)) await deleteAudio(removed.blobId);
  stopPreview();
  renderPlanner();
  announce(strings.saved);
}

function autoFillActiveBank() {
  const empty = [];
  for (let number = 1; number <= 16; number += 1) {
    if (!activeBank().pads[number]) empty.push(number);
  }
  const count = Math.min(empty.length, state.inbox.length);
  if (!state.inbox.length) { announce(strings.noInbox, "warning"); return; }
  if (!count) { announce(strings.noEmptyPads, "warning"); return; }
  for (let index = 0; index < count; index += 1) {
    const item = state.inbox.shift();
    const { id: _itemId, ...pad } = item;
    activeBank().pads[empty[index]] = pad;
  }
  state.selectedPad = empty[count - 1];
  armedPlacement = null;
  persistProject();
  renderPlanner();
  announce(fill(strings.autoFilled, { count }));
}

function inboxPanel() {
  const section = el("section", "sample-panel sample-inbox-panel");
  section.setAttribute("aria-labelledby", "sample-inbox-heading");
  const top = el("div", "sample-section-top");
  const heading = el("h2", "sample-panel-heading", `${strings.inbox} · ${state.inbox.length}`);
  heading.id = "sample-inbox-heading";
  top.append(heading, el("p", "sample-help", strings.inboxHint));
  section.append(top);

  const drop = el("div", `sample-inbox-drop${state.inbox.length ? " is-compact" : ""}`);
  drop.append(el("strong", "", strings.inboxDrop), el("span", "", state.inbox.length ? strings.inboxHint : strings.inboxEmpty));
  const setDrag = (active) => drop.classList.toggle("is-dragging", active);
  drop.addEventListener("dragenter", (event) => { event.preventDefault(); setDrag(true); });
  drop.addEventListener("dragover", (event) => {
    if (Array.from(event.dataTransfer?.types || []).includes("Files")) event.preventDefault();
    setDrag(true);
  });
  drop.addEventListener("dragleave", () => setDrag(false));
  drop.addEventListener("drop", async (event) => {
    setDrag(false);
    const files = Array.from(event.dataTransfer?.files || []);
    if (!files.length) return;
    event.preventDefault();
    await importFilesToInbox(files);
  });
  section.append(drop);

  if (state.inbox.length) {
    const tray = el("div", "sample-inbox-tray");
    tray.setAttribute("role", "list");
    state.inbox.forEach((item, index) => {
      const selected = armedPlacement?.type === "inbox" && armedPlacement.id === item.id;
      const card = el("button", `sample-inbox-card sample-pad-${item.color}${selected ? " is-selected" : ""}`);
      card.type = "button";
      card.draggable = true;
      card.dataset.inboxId = item.id;
      card.setAttribute("role", "listitem");
      card.setAttribute("aria-pressed", String(selected));
      card.setAttribute("aria-label", `${index + 1}. ${item.name}, ${formatDuration(item.duration)}`);
      const mini = waveform(item);
      mini.classList.add("sample-waveform-mini");
      card.append(
        el("span", "sample-inbox-order", String(index + 1).padStart(2, "0")),
        el("strong", "sample-inbox-name", item.name),
        el("span", "sample-inbox-meta", `${extOf(item.originalName).toUpperCase()} · ${formatDuration(item.duration)} · ${formatBytes(item.bytes)}`),
        mini,
      );
      card.addEventListener("click", () => armInbox(item));
      card.addEventListener("dragstart", (event) => {
        armedPlacement = { type: "inbox", id: item.id };
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", `inbox:${item.id}`);
        card.classList.add("is-selected");
      });
      card.addEventListener("dragend", () => {
        if (armedPlacement?.type === "inbox" && armedPlacement.id === item.id) cancelPlacement();
      });
      tray.append(card);
    });
    section.append(tray);
  }

  const input = inboxFileInput();
  const actions = el("div", "sample-inbox-actions");
  if (armedPlacement?.type === "inbox") {
    const assign = el("button", "sample-button sample-button-primary", strings.assignNext);
    assign.id = "btn-sample-inbox-assign-next";
    assign.type = "button";
    assign.addEventListener("click", assignSelectedInboxNext);
    const remove = el("button", "sample-button sample-button-danger", strings.removeInbox);
    remove.id = "btn-sample-inbox-remove";
    remove.type = "button";
    remove.addEventListener("click", removeSelectedInbox);
    actions.append(assign, remove);
  } else {
    const add = el("button", "sample-button sample-button-secondary", strings.addSamples);
    add.id = "btn-sample-inbox-add";
    add.type = "button";
    add.addEventListener("click", () => input.click());
    const fill = el("button", "sample-button sample-button-primary", strings.fillEmpty);
    fill.id = "btn-sample-inbox-fill";
    fill.type = "button";
    fill.disabled = !state.inbox.length;
    fill.addEventListener("click", autoFillActiveBank);
    actions.append(add, fill);
  }
  section.append(input, actions);
  return section;
}

function placementNotice() {
  if (armedPlacement?.type !== "pad") return null;
  const source = state.slots[armedPlacement.slot]?.pads[armedPlacement.pad];
  if (!source) return null;
  const aside = el("aside", "sample-placement-notice");
  aside.setAttribute("role", "status");
  const copy = el("div", "");
  copy.append(el("strong", "", strings.placement), el("span", "", fill(strings.moveSelected, { name: source.name })));
  const cancel = el("button", "sample-button sample-button-secondary", strings.cancel);
  cancel.id = "btn-sample-placement-cancel";
  cancel.type = "button";
  cancel.addEventListener("click", () => cancelPlacement());
  aside.append(copy, cancel);
  return aside;
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
    const isSource = armedPlacement?.type === "pad"
      && armedPlacement.slot === state.activeSlot && armedPlacement.pad === number;
    const button = el("button", `sample-pad sample-pad-${pad?.color || "empty"}${number === state.selectedPad ? " is-selected" : ""}${armedPlacement ? " is-placement-target" : ""}${isSource ? " is-placement-source" : ""}`);
    button.type = "button";
    button.dataset.pad = String(number);
    button.draggable = Boolean(pad);
    button.setAttribute("aria-pressed", String(number === state.selectedPad));
    button.setAttribute("aria-label", pad ? `Pad ${number}: ${pad.name}` : `Pad ${number}: ${strings.empty}`);
    button.append(el("span", "sample-pad-number", String(number)), el("strong", "sample-pad-name", pad?.name || strings.empty));
    if (pad) button.append(el("span", "sample-pad-duration", formatDuration(pad.duration)));
    button.addEventListener("click", () => {
      if (armedPlacement) {
        placeArmedOnPad(state.activeSlot, number);
        requestAnimationFrame(() => overlay.querySelector(`.sample-pad[data-pad="${number}"]`)?.focus());
        return;
      }
      state.selectedPad = number;
      persistProject();
      renderPlanner();
      const current = overlay.querySelector(`.sample-pad[data-pad="${number}"]`);
      current?.focus();
      if (pad) previewPad(current, pad);
    });
    button.addEventListener("dragstart", (event) => {
      if (!pad) { event.preventDefault(); return; }
      armedPlacement = { type: "pad", slot: state.activeSlot, pad: number };
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", `pad:${state.activeSlot}:${number}`);
      button.classList.add("is-placement-source");
    });
    button.addEventListener("dragend", () => {
      if (armedPlacement?.type === "pad" && armedPlacement.slot === state.activeSlot && armedPlacement.pad === number) cancelPlacement();
    });
    button.addEventListener("dragover", (event) => {
      if (!armedPlacement) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      button.classList.add("is-dragging-over");
    });
    button.addEventListener("dragleave", () => button.classList.remove("is-dragging-over"));
    button.addEventListener("drop", (event) => {
      event.preventDefault();
      button.classList.remove("is-dragging-over");
      placeArmedOnPad(state.activeSlot, number);
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
  const actions = el("div", "sample-action-row");
  const move = el("button", "sample-button sample-button-secondary", strings.moveSwap);
  move.id = "btn-sample-pad-move";
  move.type = "button";
  move.addEventListener("click", () => armPad(state.activeSlot, state.selectedPad));
  const returnButton = el("button", "sample-button sample-button-secondary", strings.returnInbox);
  returnButton.id = "btn-sample-pad-return";
  returnButton.type = "button";
  returnButton.addEventListener("click", () => {
    const pad = selectedPad();
    if (!pad) return;
    state.inbox.push(returnableInboxItem(pad));
    delete activeBank().pads[state.selectedPad];
    armedPlacement = null;
    persistProject();
    stopPreview();
    renderPlanner();
    announce(strings.saved);
  });
  actions.append(move, returnButton);
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
  const allItems = [...allAssignedPads().map((row) => row.data), ...state.inbox];
  const usage = el("p", "sample-storage-usage", `${strings.usage}: ${allAssignedPads().length} pads + ${state.inbox.length} Inbox / ${formatBytes(allItems.reduce((sum, item) => sum + item.bytes, 0))}`);
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
  handoff.addEventListener("click", async () => {
    if (!allAssignedPads().length) { announce(strings.noPads, "warning"); return; }
    stopPreview();
    announce(strings.checking);
    const report = await validateProject();
    if (report.issues.length) renderValidation(report);
    else {
      handoffIndex = 0;
      renderHandoff();
    }
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
  const notice = placementNotice();
  content.append(projectHeader(), hero(), project, bankStrip(), inboxPanel());
  if (notice) content.append(notice);
  content.append(padGrid());
  if (armedPlacement?.type !== "pad") content.append(padEditor());
  content.append(plannerFooter());
  overlay.replaceChildren(content);
  publishDiagnostics();
}

async function audioItemFromFile(file, prior = null) {
  const analysis = await analyzeAudio(file);
  const blobId = uid("audio");
  const blob = file.slice(0, file.size, file.type || "application/octet-stream");
  await putAudio({ id: blobId, blob, name: file.name, type: blob.type });
  return normalizePad({
    blobId,
    originalName: file.name,
    mime: blob.type,
    bytes: file.size,
    name: prior?.name || cleanName(file.name),
    source: prior?.source || "",
    tags: prior?.tags || "",
    color: prior?.color || "green",
    playMode: prior?.playMode || "one-shot",
    bpm: prior?.bpm || "",
    group: prior?.group || 0,
    ...analysis,
  });
}

async function importFilesToInbox(fileList) {
  const files = Array.from(fileList || []).slice(0, MAX_BATCH_FILES);
  let rejected = Math.max(0, Array.from(fileList || []).length - files.length);
  let added = 0;
  stopPreview();
  armedPlacement = null;
  for (let index = 0; index < files.length; index += 1) {
    const file = files[index];
    const extension = extOf(file.name);
    if (!SUPPORTED_EXTENSIONS.has(extension) || file.size > MAX_AUDIO_BYTES) {
      rejected += 1;
      continue;
    }
    announce(`${strings.importing} ${index + 1}/${files.length}`);
    try {
      const pad = await audioItemFromFile(file);
      if (!pad) { rejected += 1; continue; }
      state.inbox.push({ ...pad, id: uid("inbox") });
      added += 1;
    } catch (_) { rejected += 1; }
  }
  if (added) persistProject();
  renderPlanner();
  if (fileList.length > MAX_BATCH_FILES) announce(strings.batchLimit, "warning");
  else if (!added) announce(strings.invalidFile, "warning");
  else announce(fill(strings.inboxImported, {
    added,
    rejected: rejected ? fill(strings.inboxRejected, { count: rejected }) : "",
  }), rejected ? "warning" : "ok");
}

async function importSample(file) {
  const extension = extOf(file.name);
  if (!SUPPORTED_EXTENSIONS.has(extension)) { announce(strings.invalidFile, "warning"); return; }
  if (file.size > MAX_AUDIO_BYTES) { announce(strings.tooLarge, "warning"); return; }
  announce(strings.importing);
  try {
    const old = selectedPad();
    const pad = await audioItemFromFile(file, old);
    activeBank().pads[state.selectedPad] = pad;
    if (old) state.inbox.push(returnableInboxItem(old));
    persistProject();
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
  for (const blobId of referencedBlobIds()) {
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
  project.inbox.forEach((item) => referenced.add(item.blobId));
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
    armedPlacement = null;
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

async function validateProject() {
  const rows = allAssignedPads();
  const issues = [];
  const bankCounts = new Map();
  SLOT_NAMES.forEach((slot) => {
    const bank = state.slots[slot].bank;
    bankCounts.set(bank, (bankCounts.get(bank) || 0) + 1);
  });
  for (const [bank, count] of bankCounts) {
    if (count > 1) issues.push({ kind: "banks", blocking: false, text: fill(strings.validationBanks, { bank }) });
  }
  if (state.inbox.length) {
    issues.push({ kind: "inbox", blocking: false, text: fill(strings.validationInbox, { count: state.inbox.length }) });
  }
  const formatCount = rows.filter((row) => {
    const extension = extOf(row.data.originalName);
    return extension !== "cswp" && !(extension === "wav" && row.data.sampleRate === 48000 && row.data.bitDepth === 16);
  }).length;
  if (formatCount) issues.push({ kind: "format", blocking: false, text: fill(strings.validationFormat, { count: formatCount }) });

  let duplicateNames = 0;
  SLOT_NAMES.forEach((slot) => {
    const names = new Map();
    Object.values(state.slots[slot].pads).forEach((pad) => {
      const key = pad.name.trim().toLocaleLowerCase();
      if (key) names.set(key, (names.get(key) || 0) + 1);
    });
    for (const count of names.values()) if (count > 1) duplicateNames += count - 1;
  });
  if (duplicateNames) issues.push({ kind: "names", blocking: false, text: fill(strings.validationNames, { count: duplicateNames }) });

  let missing = 0;
  for (const blobId of new Set(rows.map((row) => row.data.blobId))) {
    if (!await getAudio(blobId)) missing += 1;
  }
  if (missing) issues.unshift({ kind: "missing", blocking: true, text: fill(strings.validationMissing, { count: missing }) });
  return { issues, blocking: issues.some((issue) => issue.blocking), assigned: rows.length, inbox: state.inbox.length };
}

function renderValidation(report) {
  overlay.dataset.view = "validation";
  const shell = el("div", "sample-lab-shell sample-validation-shell");
  const section = el("section", "sample-hero sample-validation-hero");
  section.append(el("p", "sample-eyebrow", strings.validationEyebrow));
  const title = el("h1", "", strings.validationTitle);
  title.tabIndex = -1;
  section.append(title, el("p", "sample-lede", report.blocking ? strings.validationBlocking : strings.validationIntro));
  const card = el("section", `sample-validation-card${report.blocking ? " has-blocker" : ""}`);
  card.setAttribute("aria-labelledby", "sample-validation-summary");
  const summary = el("h2", "sample-validation-summary", report.issues.length ? strings.validationTitle : strings.validationReady);
  summary.id = "sample-validation-summary";
  card.append(summary);
  const list = el("ul", "sample-validation-list");
  report.issues.forEach((issue) => {
    const item = el("li", issue.blocking ? "is-blocking" : "");
    item.dataset.kind = issue.kind;
    item.append(el("strong", "", issue.blocking ? "!" : "i"), el("span", "", issue.text));
    list.append(item);
  });
  card.append(list);
  const status = el("p", "sample-status", "");
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  card.append(status);
  const actions = el("div", "sample-primary-actions");
  const back = el("button", "sample-button sample-button-secondary", strings.fixProject);
  back.id = "btn-sample-validation-back";
  back.type = "button";
  back.addEventListener("click", renderPlanner);
  actions.append(back);
  if (!report.blocking) {
    const proceed = el("button", "sample-button sample-button-primary", strings.continueHandoff);
    proceed.id = "btn-sample-validation-continue";
    proceed.type = "button";
    proceed.addEventListener("click", () => {
      handoffIndex = 0;
      renderHandoff();
    });
    actions.append(proceed);
  }
  card.append(actions);
  shell.append(projectHeader(), section, card);
  overlay.replaceChildren(shell);
  title.focus();
  publishDiagnostics();
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
    inboxItems: state ? state.inbox.map((item) => ({ id: item.id, name: item.name, filename: item.originalName, bytes: item.bytes })) : [],
    placement: armedPlacement ? { ...armedPlacement } : null,
    assignedPads: state ? allAssignedPads().map((row) => ({ slot: row.slot, bank: row.bank, pad: row.pad, name: row.data.name, filename: row.data.originalName })) : [],
    exportProjectBlob,
    importProjectFile,
    validateProject,
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
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && armedPlacement && !overlay.hidden) {
      event.preventDefault();
      cancelPlacement();
    }
  });
  new MutationObserver(() => {
    enhanceHome();
    if (window.location.hash.startsWith(ROUTE)) setRouteActive();
  }).observe(document.getElementById("app") || document.body, { childList: true, subtree: true });
  publishDiagnostics();
}

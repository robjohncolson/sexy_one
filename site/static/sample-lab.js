// SEXY ONE Sample Lab -- a deferred, local-first sound library and pad planner.
//
// This module is intentionally absent from index.js's static import graph. The
// trainer loads and becomes interactive first, then index.js imports this file.
// Audio bytes live in IndexedDB and move between devices only inside a user-
// initiated .sxc1lab export. Nothing here has a network write path.

const ROUTE = "#/samples";
const META_KEY = "sxc1.sample-lab.v1";
const WORKSPACE_KEY = "sxc1.sample-workspace.v1";
const LIBRARY_KEY = "sxc1.sample-library.v1";
const HANDOFF_KEY = "sxc1.sample-handoffs.v1";
const DB_NAME = "sxc1-sample-lab";
const DB_VERSION = 1;
const DB_STORE = "audio";
const FORMAT_MAGIC = "SXC1LAB1";
const FORMAT_SCHEMA = 1;
const MAX_MANIFEST_BYTES = 5 * 1024 * 1024;
const MAX_AUDIO_BYTES = 180 * 1024 * 1024;
const MAX_BATCH_FILES = 64;
const MAX_PROJECTS = 32;
const MAX_LIBRARY_ITEMS = 2048;
const MAX_INBOX_ITEMS = 256;
const MAX_HANDOFF_SESSIONS = 32;
const MAX_HANDOFF_ENTRIES = 64;
const SLOT_NAMES = ["A", "B", "C", "D"];
const SUPPORTED_EXTENSIONS = new Set(["wav", "mp3", "flac", "cswp"]);

const COPY = {
  en: {
    homeTitle: "Build a sample library",
    homeSub: "Catalog sounds and plan SXC-1 pad banks",
    library: "Manuals, course, and progress",
    back: "Back to SEXY ONE",
    eyebrow: "LOCAL SAMPLE WORKSPACE",
    title: "Sample Lab",
    intro: "Shape files in Audacity, plan the pads here, then carry one project to your phone.",
    local: "Audio stays on this device",
    temporary: "Temporary mode — export before closing this tab",
    project: "Project",
    projectName: "Project name",
    currentProject: "Current project",
    newProject: "New project",
    createProject: "Create project",
    cancelProject: "Cancel",
    newProjectName: "New project name",
    projectCreated: "Project created.",
    deleteProject: "Delete current project",
    deleteProjectConfirm: "Delete this project? Sounds remain safe in Sample Library.",
    projectDeleted: "Project deleted. Library sounds were kept.",
    projectLimit: "This device already has 32 projects.",
    inboxLimit: "This project's Inbox already has 256 items.",
    sampleLibrary: "Sample Library",
    libraryHint: "One local catalog for every project. Search, audition, and reuse sounds without copying their audio.",
    libraryEmpty: "Add Audacity exports once, then send them into any project's Inbox.",
    librarySearch: "Search sounds",
    librarySearchPlaceholder: "Name, source, tag, BPM, duration, format…",
    libraryStage: "Stage",
    stageAll: "All stages",
    stageRaw: "Raw",
    stageEdited: "Edited",
    stageReady: "Ready",
    addLibrary: "Add to library",
    addToInbox: "Add to Inbox",
    editDetails: "Edit details",
    doneEditing: "Done",
    removeLibrary: "Remove from Library",
    removeLibraryConfirm: "Remove this sound from Sample Library? Any project assignments remain safe.",
    libraryNotes: "Notes",
    libraryNotesPlaceholder: "Scene, take, edit decisions…",
    libraryRights: "Permission / credit",
    libraryRightsPlaceholder: "Owned recording, licensed source, attribution…",
    libraryAdded: "Added {added} new sound(s) to the Library{duplicates}{rejected}.",
    libraryDuplicates: "; reused {count} duplicate(s)",
    librarySelected: "{name} selected.",
    libraryInboxAdded: "Added {name} to {project}'s Inbox.",
    libraryUpdated: "Library details saved.",
    libraryRemoved: "Removed from Sample Library. Project copies remain safe.",
    noLibraryMatch: "No sounds match these filters.",
    inbox: "Sample Inbox",
    inboxHint: "Audition a sound, then press its destination pad. You can also drag it on desktop.",
    inboxEmpty: "Drop an Audacity export batch here. Nothing is assigned until you place it.",
    inboxDrop: "Drop WAV, MP3, FLAC, or .cswp files",
    addSamples: "Add samples",
    fillEmpty: "Fill empty pads",
    assignNext: "Assign next empty",
    removeInbox: "Remove from Inbox",
    removeInboxConfirm: "Remove this item from the current project's Inbox? Its Library sound remains available.",
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
    saveShare: "Send project to phone",
    handoff: "Start phone handoff",
    resumeHandoff: "Resume phone handoff",
    reviewReceipt: "Review handoff receipt",
    tools: "Project tools",
    importProject: "Import .sxc1lab project",
    usage: "Storage",
    usageProjects: "{count} projects",
    usageSounds: "{count} sounds",
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
    downloadFile: "Save this file",
    skipPad: "Skip for now",
    loadedPad: "Loaded",
    problemPad: "Problem",
    awaitingConfirm: "File sent — confirm what happened in CASIO Sampler App.",
    skippedPad: "Skipped {destination}.",
    loadedPadStatus: "Loaded {destination}; continuing.",
    problemPadStatus: "Marked {destination} as a problem; continuing.",
    receiptEyebrow: "HANDOFF RECEIPT",
    receiptTitle: "Handoff reviewed",
    receiptComplete: "All {total} pads are marked loaded.",
    receiptPartial: "{loaded} loaded · {problem} problem · {skipped} skipped",
    receiptLoaded: "Loaded",
    receiptProblem: "Problem",
    receiptSkipped: "Skipped",
    retryUnresolved: "Retry unresolved",
    finish: "Back to planner",
    handoffSaved: "Handoff progress is saved on this device.",
    progress: "Pad {current} of {total}",
    noPreview: "This file can travel with the project but cannot be previewed in this browser.",
    previewFailed: "Browser preview is unavailable for this file; its original bytes are still safe.",
    playing: "Playing {name}",
    downloadReady: "Downloaded {name}",
    sharedReady: "Shared {name}",
    projectDownloaded: "Project saved — move the .sxc1lab file to your phone and open it in SEXY ONE.",
    projectShared: "Project shared. Open the .sxc1lab file on your phone to continue.",
    shareCancelled: "Sharing was cancelled; nothing changed.",
  },
  ja: {
    homeTitle: "サンプルライブラリを作る",
    homeSub: "音声を整理してSXC-1のパッドを計画",
    library: "マニュアル、コース、進捗",
    back: "SEXY ONEへ戻る",
    eyebrow: "ローカル・サンプル・ワークスペース",
    title: "Sample Lab",
    intro: "Audacityで整えたファイルをパッドに配置し、プロジェクトごとスマートフォンへ移します。",
    local: "音声はこの端末内だけに保存されます",
    temporary: "一時モード — タブを閉じる前に書き出してください",
    project: "プロジェクト",
    projectName: "プロジェクト名",
    currentProject: "現在のプロジェクト",
    newProject: "新規プロジェクト",
    createProject: "プロジェクトを作成",
    cancelProject: "キャンセル",
    newProjectName: "新しいプロジェクト名",
    projectCreated: "プロジェクトを作成しました。",
    deleteProject: "現在のプロジェクトを削除",
    deleteProjectConfirm: "このプロジェクトを削除しますか？ 音声はサンプルライブラリに残ります。",
    projectDeleted: "プロジェクトを削除しました。ライブラリの音声は保持されています。",
    projectLimit: "この端末にはすでに32件のプロジェクトがあります。",
    inboxLimit: "このプロジェクトの受け皿にはすでに256件あります。",
    sampleLibrary: "サンプルライブラリ",
    libraryHint: "全プロジェクト共通のローカル音声カタログです。音声を複製せず検索・試聴・再利用できます。",
    libraryEmpty: "Audacityの書き出しを一度追加し、各プロジェクトの受け皿へ送ります。",
    librarySearch: "音声を検索",
    librarySearchPlaceholder: "名前、出典、タグ、BPM、長さ、形式…",
    libraryStage: "進行段階",
    stageAll: "すべての段階",
    stageRaw: "未編集",
    stageEdited: "編集済み",
    stageReady: "使用準備完了",
    addLibrary: "ライブラリへ追加",
    addToInbox: "受け皿へ追加",
    editDetails: "詳細を編集",
    doneEditing: "完了",
    removeLibrary: "ライブラリから削除",
    removeLibraryConfirm: "この音声をサンプルライブラリから削除しますか？ プロジェクト内の割り当ては残ります。",
    libraryNotes: "メモ",
    libraryNotesPlaceholder: "場面、テイク、編集内容…",
    libraryRights: "使用許可／クレジット",
    libraryRightsPlaceholder: "自分の録音、許諾済み素材、出典表記…",
    libraryAdded: "新しい音声を{added}件ライブラリへ追加しました{duplicates}{rejected}。",
    libraryDuplicates: "（重複{count}件は既存音声を再利用）",
    librarySelected: "{name}を選択しました。",
    libraryInboxAdded: "{name}を「{project}」の受け皿へ追加しました。",
    libraryUpdated: "ライブラリ情報を保存しました。",
    libraryRemoved: "ライブラリから削除しました。プロジェクト内の音声は保持されています。",
    noLibraryMatch: "条件に一致する音声はありません。",
    inbox: "サンプル受け皿",
    inboxHint: "音を試聴してから割り当て先パッドを押します。パソコンではドラッグもできます。",
    inboxEmpty: "Audacityの書き出しをまとめてドロップしてください。配置するまでパッドには割り当てません。",
    inboxDrop: "WAV / MP3 / FLAC / .cswp をドロップ",
    addSamples: "サンプルを追加",
    fillEmpty: "空きパッドへ配置",
    assignNext: "次の空きへ配置",
    removeInbox: "受け皿から削除",
    removeInboxConfirm: "現在のプロジェクトの受け皿からこの項目を外しますか？ ライブラリの音声は残ります。",
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
    saveShare: "プロジェクトをスマートフォンへ送る",
    handoff: "スマートフォンで引き渡し開始",
    resumeHandoff: "スマートフォンで引き渡し再開",
    reviewReceipt: "引き渡し記録を確認",
    tools: "プロジェクトツール",
    importProject: ".sxc1labプロジェクトを読み込む",
    usage: "ストレージ",
    usageProjects: "プロジェクト{count}件",
    usageSounds: "音声{count}件",
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
    skipPad: "今はスキップ",
    loadedPad: "読み込み済み",
    problemPad: "問題あり",
    awaitingConfirm: "ファイルを送りました。CASIO Sampler Appでの結果を確認してください。",
    skippedPad: "{destination}をスキップしました。",
    loadedPadStatus: "{destination}を読み込み済みにして次へ進みます。",
    problemPadStatus: "{destination}を問題ありとして次へ進みます。",
    receiptEyebrow: "引き渡し記録",
    receiptTitle: "引き渡し確認済み",
    receiptComplete: "{total}パッドすべてを読み込み済みにしました。",
    receiptPartial: "読み込み済み {loaded} · 問題あり {problem} · スキップ {skipped}",
    receiptLoaded: "読み込み済み",
    receiptProblem: "問題あり",
    receiptSkipped: "スキップ",
    retryUnresolved: "未解決項目を再試行",
    finish: "パッド配置へ戻る",
    handoffSaved: "引き渡しの進捗はこの端末に保存されます。",
    progress: "{total}件中 {current}件目",
    noPreview: "プロジェクトには保存できますが、このブラウザでは試聴できません。",
    previewFailed: "ブラウザで試聴できませんが、元のファイルはそのまま保持されています。",
    playing: "再生中：{name}",
    downloadReady: "保存しました：{name}",
    sharedReady: "共有しました：{name}",
    projectDownloaded: ".sxc1labファイルを保存しました。スマートフォンへ移し、SEXY ONEで開いてください。",
    projectShared: "プロジェクトを共有しました。スマートフォンで.sxc1labファイルを開いて続けてください。",
    shareCancelled: "共有をキャンセルしました。変更はありません。",
  },
};

let started = false;
let lang = "en";
let strings = COPY.en;
let state = null;
let workspace = null;
let libraryState = null;
let handoffState = null;
let handoffSession = null;
let overlay = null;
let db = null;
let persistentAudio = true;
let currentAudio = null;
let currentObjectUrl = null;
let renderQueued = false;
let handoffIndex = 0;
let armedPlacement = null;
let librarySelection = null;
let libraryEditing = false;
let libraryQuery = "";
let libraryStageFilter = "all";
let creatingProject = false;
let metadataPersistTimer = null;
let libraryImportQueue = Promise.resolve();
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

function defaultWorkspace(project = defaultProject()) {
  return { schema: 1, activeProjectId: project.id, projects: [project] };
}

function defaultLibrary() {
  return { schema: 1, items: [], updatedAt: new Date().toISOString() };
}

function defaultHandoffState() {
  return { schema: 1, sessions: [], updatedAt: new Date().toISOString() };
}

function normalizeHandoffEntry(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.key !== "string" || !raw.key) return null;
  const status = ["pending", "shared", "loaded", "problem", "skipped"].includes(raw.status)
    ? raw.status
    : "pending";
  return {
    key: raw.key.slice(0, 320),
    slot: SLOT_NAMES.includes(raw.slot) ? raw.slot : "A",
    bank: clampInt(raw.bank, 15, 80, 15),
    pad: clampInt(raw.pad, 1, 16, 1),
    blobId: String(raw.blobId || "").slice(0, 180),
    name: String(raw.name || "Sample").slice(0, 80),
    originalName: String(raw.originalName || "sample").slice(0, 240),
    status,
    sharedAt: typeof raw.sharedAt === "string" ? raw.sharedAt : "",
    resolvedAt: typeof raw.resolvedAt === "string" ? raw.resolvedAt : "",
  };
}

function normalizeHandoffSession(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.projectId !== "string" || !raw.projectId) return null;
  const entries = [];
  const keys = new Set();
  if (Array.isArray(raw.entries)) {
    raw.entries.slice(0, MAX_HANDOFF_ENTRIES).forEach((candidate) => {
      const entry = normalizeHandoffEntry(candidate);
      if (entry && !keys.has(entry.key)) {
        keys.add(entry.key);
        entries.push(entry);
      }
    });
  }
  return {
    projectId: raw.projectId.slice(0, 180),
    entries,
    currentKey: keys.has(raw.currentKey) ? raw.currentKey : "",
    startedAt: typeof raw.startedAt === "string" ? raw.startedAt : new Date().toISOString(),
    updatedAt: typeof raw.updatedAt === "string" ? raw.updatedAt : new Date().toISOString(),
    finishedAt: typeof raw.finishedAt === "string" ? raw.finishedAt : "",
  };
}

function normalizeHandoffState(raw) {
  const result = defaultHandoffState();
  const projectIds = new Set();
  if (raw && typeof raw === "object" && Array.isArray(raw.sessions)) {
    raw.sessions.slice(0, MAX_HANDOFF_SESSIONS).forEach((candidate) => {
      const session = normalizeHandoffSession(candidate);
      if (session && !projectIds.has(session.projectId)) {
        projectIds.add(session.projectId);
        result.sessions.push(session);
      }
    });
  }
  if (raw && typeof raw.updatedAt === "string") result.updatedAt = raw.updatedAt;
  return result;
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
    fingerprint: typeof raw.fingerprint === "string" ? raw.fingerprint.slice(0, 128) : "",
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
    raw.inbox.slice(0, MAX_INBOX_ITEMS).forEach((candidate) => {
      const item = normalizeInboxItem(candidate);
      if (item && !inboxIds.has(item.id)) {
        inboxIds.add(item.id);
        result.inbox.push(item);
      }
    });
  }
  return result;
}

function normalizeWorkspace(raw, legacyProject = null) {
  const projects = [];
  const ids = new Set();
  if (raw && typeof raw === "object" && Array.isArray(raw.projects)) {
    raw.projects.slice(0, MAX_PROJECTS).forEach((candidate) => {
      const project = normalizeProject(candidate);
      if (!ids.has(project.id)) {
        ids.add(project.id);
        projects.push(project);
      }
    });
  }
  if (!projects.length) {
    const project = legacyProject ? normalizeProject(legacyProject) : defaultProject();
    projects.push(project);
    ids.add(project.id);
  }
  const activeProjectId = ids.has(raw?.activeProjectId) ? raw.activeProjectId : projects[0].id;
  return { schema: 1, activeProjectId, projects };
}

function normalizeLibraryItem(raw) {
  const pad = normalizePad(raw);
  if (!pad) return null;
  return {
    ...pad,
    id: typeof raw.id === "string" && raw.id ? raw.id : uid("asset"),
    stage: ["raw", "edited", "ready"].includes(raw.stage) ? raw.stage : "raw",
    notes: String(raw.notes || "").slice(0, 500),
    rights: String(raw.rights || "").slice(0, 300),
    addedAt: typeof raw.addedAt === "string" ? raw.addedAt : new Date().toISOString(),
  };
}

function normalizeLibrary(raw) {
  const result = defaultLibrary();
  const ids = new Set();
  const blobs = new Set();
  if (raw && typeof raw === "object" && Array.isArray(raw.items)) {
    raw.items.slice(0, MAX_LIBRARY_ITEMS).forEach((candidate) => {
      const item = normalizeLibraryItem(candidate);
      if (item && !ids.has(item.id) && !blobs.has(item.blobId)) {
        ids.add(item.id);
        blobs.add(item.blobId);
        result.items.push(item);
      }
    });
  }
  if (raw && typeof raw.updatedAt === "string") result.updatedAt = raw.updatedAt;
  return result;
}

function librarySeedFromPad(pad) {
  return normalizeLibraryItem({
    ...pad,
    id: uid("asset"),
    stage: extOf(pad.originalName) === "wav" && pad.sampleRate === 48000 && pad.bitDepth === 16 ? "ready" : "edited",
  });
}

function seedLibraryFromProjects() {
  const knownBlobs = new Set(libraryState.items.map((item) => item.blobId));
  workspace.projects.forEach((project) => {
    const items = [...Object.values(project.slots).flatMap((slot) => Object.values(slot.pads)), ...project.inbox];
    items.forEach((pad) => {
      if (knownBlobs.has(pad.blobId)) return;
      const item = librarySeedFromPad(pad);
      if (item && libraryState.items.length < MAX_LIBRARY_ITEMS) {
        knownBlobs.add(item.blobId);
        libraryState.items.push(item);
      }
    });
  });
}

function loadWorkspace() {
  const readJson = (key) => {
    try {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (_) { return null; }
  };
  try {
    workspace = normalizeWorkspace(readJson(WORKSPACE_KEY), readJson(META_KEY));
    libraryState = normalizeLibrary(readJson(LIBRARY_KEY));
    handoffState = normalizeHandoffState(readJson(HANDOFF_KEY));
    seedLibraryFromProjects();
    state = workspace.projects.find((project) => project.id === workspace.activeProjectId) || workspace.projects[0];
    workspace.activeProjectId = state.id;
  } catch (_) {
    persistentAudio = false;
    state = defaultProject();
    workspace = defaultWorkspace(state);
    libraryState = defaultLibrary();
    handoffState = defaultHandoffState();
  }
  return state;
}

function persistHandoffs() {
  handoffState.updatedAt = new Date().toISOString();
  try { localStorage.setItem(HANDOFF_KEY, JSON.stringify(handoffState)); }
  catch (_) { persistentAudio = false; }
  publishDiagnostics();
}

function persistProject() {
  if (metadataPersistTimer !== null) {
    clearTimeout(metadataPersistTimer);
    metadataPersistTimer = null;
  }
  state.updatedAt = new Date().toISOString();
  workspace.activeProjectId = state.id;
  const index = workspace.projects.findIndex((project) => project.id === state.id);
  if (index >= 0) workspace.projects[index] = state;
  else workspace.projects.push(state);
  libraryState.updatedAt = new Date().toISOString();
  try {
    localStorage.setItem(WORKSPACE_KEY, JSON.stringify(workspace));
    localStorage.setItem(LIBRARY_KEY, JSON.stringify(libraryState));
    // Keep the M12/M13 key as a mirror of the active project. This makes the
    // migration reversible and preserves older builds' last-project behavior.
    localStorage.setItem(META_KEY, JSON.stringify(state));
  } catch (_) {
    persistentAudio = false;
  }
  publishDiagnostics();
}

function scheduleMetadataPersist() {
  if (metadataPersistTimer !== null) clearTimeout(metadataPersistTimer);
  metadataPersistTimer = setTimeout(() => {
    metadataPersistTimer = null;
    persistProject();
  }, 180);
}

function switchProject(projectId) {
  const next = workspace.projects.find((project) => project.id === projectId);
  if (!next || next === state) return;
  stopPreview();
  armedPlacement = null;
  librarySelection = null;
  libraryEditing = false;
  handoffSession = null;
  state = next;
  workspace.activeProjectId = next.id;
  persistProject();
  renderPlanner();
}

function createProject(name) {
  if (workspace.projects.length >= MAX_PROJECTS) {
    announce(strings.projectLimit, "warning");
    return false;
  }
  stopPreview();
  const project = defaultProject();
  project.name = String(name || strings.newProject).trim().slice(0, 100) || strings.newProject;
  workspace.projects.push(project);
  state = project;
  workspace.activeProjectId = project.id;
  creatingProject = false;
  armedPlacement = null;
  librarySelection = null;
  libraryEditing = false;
  handoffSession = null;
  persistProject();
  renderPlanner();
  announce(strings.projectCreated);
  return true;
}

async function deleteCurrentProject() {
  if (workspace.projects.length <= 1 || !window.confirm(strings.deleteProjectConfirm)) return;
  const index = workspace.projects.findIndex((project) => project.id === state.id);
  if (index < 0) return;
  stopPreview();
  const deletedProjectId = state.id;
  workspace.projects.splice(index, 1);
  state = workspace.projects[Math.min(index, workspace.projects.length - 1)];
  workspace.activeProjectId = state.id;
  armedPlacement = null;
  librarySelection = null;
  libraryEditing = false;
  handoffSession = null;
  handoffState.sessions = handoffState.sessions.filter((session) => session.projectId !== deletedProjectId);
  persistHandoffs();
  persistProject();
  renderPlanner();
  announce(strings.projectDeleted);
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

async function fingerprintFile(file) {
  const bytes = await file.arrayBuffer();
  if (globalThis.crypto?.subtle?.digest) {
    const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
    return `sha256:${Array.from(digest, (value) => value.toString(16).padStart(2, "0")).join("")}`;
  }
  // A deterministic fallback for older local WebViews. It is not a security
  // primitive; equality is additionally guarded by size before reuse.
  let hash = 2166136261;
  const view = new Uint8Array(bytes);
  for (let index = 0; index < view.length; index += 1) {
    hash ^= view[index];
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return `fnv1a:${view.length}:${hash.toString(16).padStart(8, "0")}`;
}

function rememberFingerprint(blobId, fingerprint) {
  const asset = libraryState.items.find((item) => item.blobId === blobId);
  if (asset) asset.fingerprint = fingerprint;
  workspace.projects.forEach((project) => {
    Object.values(project.slots).forEach((slot) => {
      Object.values(slot.pads).forEach((pad) => {
        if (pad.blobId === blobId) pad.fingerprint = fingerprint;
      });
    });
    project.inbox.forEach((item) => {
      if (item.blobId === blobId) item.fingerprint = fingerprint;
    });
  });
}

function padFromLibraryAsset(asset, prior = null) {
  const pick = (key) => prior?.[key] ?? asset[key];
  return normalizePad({
    ...asset,
    name: pick("name"),
    source: pick("source"),
    tags: pick("tags"),
    color: pick("color"),
    playMode: pick("playMode"),
    bpm: pick("bpm"),
    group: pick("group"),
  });
}

function libraryAssetFromFile(file) {
  const run = libraryImportQueue.then(
    () => libraryAssetFromFileUnsafe(file),
    () => libraryAssetFromFileUnsafe(file),
  );
  libraryImportQueue = run.then(() => undefined, () => undefined);
  return run;
}

async function libraryAssetFromFileUnsafe(file) {
  const fingerprint = await fingerprintFile(file);
  let existing = libraryState.items.find((item) => item.fingerprint === fingerprint && item.bytes === file.size);
  // M12/M13 projects did not persist fingerprints. Hash only same-size legacy
  // candidates when a new file arrives, so migration remains instant while an
  // identical re-import still reuses the original IndexedDB blob.
  if (!existing) {
    const candidates = libraryState.items.filter((item) => !item.fingerprint && item.bytes === file.size);
    for (const candidate of candidates) {
      const record = await getAudio(candidate.blobId);
      if (!record?.blob) continue;
      const candidateFingerprint = await fingerprintFile(record.blob);
      rememberFingerprint(candidate.blobId, candidateFingerprint);
      if (candidateFingerprint === fingerprint) {
        existing = candidate;
        break;
      }
    }
  }
  if (existing) return { asset: existing, reused: true };
  if (libraryState.items.length >= MAX_LIBRARY_ITEMS) throw new Error("Library full");
  const analysis = await analyzeAudio(file);
  const blobId = uid("audio");
  const blob = file.slice(0, file.size, file.type || "application/octet-stream");
  await putAudio({ id: blobId, blob, name: file.name, type: blob.type });
  const asset = normalizeLibraryItem({
    blobId,
    originalName: file.name,
    mime: blob.type,
    bytes: file.size,
    name: cleanName(file.name),
    source: "",
    tags: "",
    color: "green",
    playMode: "one-shot",
    bpm: "",
    group: 0,
    fingerprint,
    stage: extOf(file.name) === "wav" && analysis.sampleRate === 48000 && analysis.bitDepth === 16 ? "ready" : "raw",
    ...analysis,
  });
  libraryState.items.push(asset);
  return { asset, reused: false };
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

function handoffRowKey(row) {
  return JSON.stringify([row.slot, row.bank, row.pad, row.data.blobId]);
}

function handoffCounts(session = handoffSession) {
  const counts = { total: 0, pending: 0, shared: 0, loaded: 0, problem: 0, skipped: 0 };
  (session?.entries || []).forEach((entry) => {
    counts.total += 1;
    counts[entry.status] += 1;
  });
  counts.unresolved = counts.pending + counts.shared + counts.problem + counts.skipped;
  return counts;
}

function savedHandoffForProject(projectId = state?.id) {
  return handoffState?.sessions.find((session) => session.projectId === projectId) || null;
}

function handoffMatchesRows(session, rows = allAssignedPads()) {
  if (!session || session.entries.length !== rows.length) return false;
  return session.entries.every((entry, index) => entry.key === handoffRowKey(rows[index]));
}

function handoffButtonLabel() {
  const session = savedHandoffForProject();
  if (!handoffMatchesRows(session)) return strings.handoff;
  const counts = handoffCounts(session);
  if (counts.pending + counts.shared === 0 && counts.total > 0) return strings.reviewReceipt;
  if (session.entries.some((entry) => entry.status !== "pending")) return strings.resumeHandoff;
  return strings.handoff;
}

function syncHandoffSession(rows = allAssignedPads()) {
  const previous = savedHandoffForProject();
  const previousEntries = new Map((previous?.entries || []).map((entry) => [entry.key, entry]));
  const now = new Date().toISOString();
  const entries = rows.slice(0, MAX_HANDOFF_ENTRIES).map((row) => {
    const key = handoffRowKey(row);
    const saved = previousEntries.get(key);
    return normalizeHandoffEntry({
      key,
      slot: row.slot,
      bank: row.bank,
      pad: row.pad,
      blobId: row.data.blobId,
      name: row.data.name,
      originalName: row.data.originalName,
      status: saved?.status || "pending",
      sharedAt: saved?.sharedAt || "",
      resolvedAt: saved?.resolvedAt || "",
    });
  });
  const changed = !previous || previous.entries.length !== entries.length
    || entries.some((entry, index) => previous.entries[index]?.key !== entry.key);
  let currentKey = entries.some((entry) => entry.key === previous?.currentKey
      && ["pending", "shared"].includes(entry.status))
    ? previous.currentKey
    : entries.find((entry) => ["pending", "shared"].includes(entry.status))?.key || "";
  const finished = entries.length > 0 && entries.every((entry) => ["loaded", "problem", "skipped"].includes(entry.status));
  if (finished) currentKey = "";
  const session = {
    projectId: state.id,
    entries,
    currentKey,
    startedAt: previous?.startedAt || now,
    updatedAt: now,
    finishedAt: finished ? (changed ? now : previous?.finishedAt || now) : "",
  };
  const index = handoffState.sessions.findIndex((candidate) => candidate.projectId === state.id);
  if (index >= 0) handoffState.sessions[index] = session;
  else {
    handoffState.sessions.push(session);
    if (handoffState.sessions.length > MAX_HANDOFF_SESSIONS) {
      handoffState.sessions.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
      handoffState.sessions.length = MAX_HANDOFF_SESSIONS;
    }
  }
  handoffSession = session;
  persistHandoffs();
  return session;
}

function currentHandoffEntry() {
  return handoffSession?.entries.find((entry) => entry.key === handoffSession.currentKey) || null;
}

function nextHandoffEntry(afterKey = "") {
  const entries = handoffSession?.entries || [];
  const start = Math.max(-1, entries.findIndex((entry) => entry.key === afterKey));
  for (let offset = 1; offset <= entries.length; offset += 1) {
    const entry = entries[(start + offset) % entries.length];
    if (["pending", "shared"].includes(entry.status)) return entry;
  }
  return null;
}

function finishOrAdvanceHandoff(message = "") {
  const next = nextHandoffEntry(handoffSession.currentKey);
  handoffSession.currentKey = next?.key || "";
  handoffSession.updatedAt = new Date().toISOString();
  handoffSession.finishedAt = next ? "" : handoffSession.updatedAt;
  persistHandoffs();
  if (next) renderHandoff(); else renderHandoffReceipt();
  if (message) announce(message);
}

function markCurrentHandoff(status) {
  if (!handoffSession || !["loaded", "problem", "skipped"].includes(status)) return;
  const entry = currentHandoffEntry();
  if (!entry) return;
  const destination = `${entry.slot} / BANK ${entry.bank} / PAD ${entry.pad}`;
  entry.status = status;
  entry.resolvedAt = new Date().toISOString();
  const message = status === "loaded"
    ? fill(strings.loadedPadStatus, { destination })
    : status === "problem"
      ? fill(strings.problemPadStatus, { destination })
      : fill(strings.skippedPad, { destination });
  finishOrAdvanceHandoff(message);
}

function retryUnresolvedHandoff() {
  if (!handoffSession) return;
  handoffSession.entries.forEach((entry) => {
    if (entry.status !== "loaded") {
      entry.status = "pending";
      entry.sharedAt = "";
      entry.resolvedAt = "";
    }
  });
  handoffSession.currentKey = handoffSession.entries.find((entry) => entry.status === "pending")?.key || "";
  handoffSession.finishedAt = "";
  handoffSession.updatedAt = new Date().toISOString();
  persistHandoffs();
  renderHandoff();
}

function beginHandoff() {
  const rows = allAssignedPads();
  if (!rows.length) { renderPlanner(); announce(strings.noPads, "warning"); return; }
  syncHandoffSession(rows);
  if (currentHandoffEntry()) renderHandoff(); else renderHandoffReceipt();
}

function referencedBlobIds(project = state) {
  const ids = new Set();
  SLOT_NAMES.forEach((slot) => Object.values(project.slots[slot].pads).forEach((pad) => ids.add(pad.blobId)));
  project.inbox.forEach((item) => ids.add(item.blobId));
  return ids;
}

function assignedPadCount(project = state) {
  return SLOT_NAMES.reduce((count, slot) => count + Object.keys(project.slots[slot].pads).length, 0);
}

function projectReferencedBlobIds() {
  const ids = new Set();
  workspace.projects.forEach((project) => referencedBlobIds(project).forEach((id) => ids.add(id)));
  return ids;
}

function allStoredBlobIds() {
  const ids = projectReferencedBlobIds();
  libraryState.items.forEach((item) => ids.add(item.blobId));
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
  overlay?.querySelectorAll(".sample-pad.is-playing, .sample-inbox-card.is-playing, .sample-library-card.is-playing")
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

function projectPanel() {
  const section = el("section", "sample-panel sample-project-panel");
  section.setAttribute("aria-labelledby", "sample-project-heading");
  const heading = el("h2", "sample-panel-heading", strings.project);
  heading.id = "sample-project-heading";
  section.append(heading);
  if (creatingProject) {
    const name = textInput("sample-new-project-name", "", 100, strings.newProjectName);
    const actions = el("div", "sample-action-row");
    const create = el("button", "sample-button sample-button-primary", strings.createProject);
    create.id = "btn-sample-project-create";
    create.type = "button";
    create.addEventListener("click", () => createProject(name.value));
    const cancel = el("button", "sample-button sample-button-secondary", strings.cancelProject);
    cancel.id = "btn-sample-project-create-cancel";
    cancel.type = "button";
    cancel.addEventListener("click", () => { creatingProject = false; renderPlanner(); });
    name.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); createProject(name.value); }
    });
    actions.append(create, cancel);
    section.append(labeledField(strings.newProjectName, name), actions);
    requestAnimationFrame(() => name.focus());
    return section;
  }

  const controls = el("div", "sample-project-controls");
  const chooser = document.createElement("select");
  chooser.id = "sample-project-select";
  workspace.projects.forEach((project) => chooser.append(option(project.id, project.name, project.id === state.id)));
  chooser.addEventListener("change", () => switchProject(chooser.value));
  const projectName = textInput("sample-project-name", state.name, 100);
  projectName.addEventListener("input", () => {
    state.name = projectName.value;
    const selected = Array.from(chooser.options).find((item) => item.value === state.id);
    if (selected) selected.textContent = state.name || strings.newProject;
    persistProject();
  });
  const add = el("button", "sample-button sample-button-secondary", strings.newProject);
  add.id = "btn-sample-project-new";
  add.type = "button";
  add.disabled = workspace.projects.length >= MAX_PROJECTS;
  add.addEventListener("click", () => { creatingProject = true; renderPlanner(); });
  controls.append(
    labeledField(strings.currentProject, chooser),
    labeledField(strings.projectName, projectName),
    add,
  );
  section.append(controls);
  return section;
}

function libraryStageLabel(stage) {
  if (stage === "ready") return strings.stageReady;
  if (stage === "edited") return strings.stageEdited;
  return strings.stageRaw;
}

function librarySearchText(item) {
  return [
    item.name, item.originalName, item.source, item.tags, item.notes, item.rights,
    item.stage, libraryStageLabel(item.stage), extOf(item.originalName), item.bpm,
    formatDuration(item.duration), Math.round(item.duration || 0), item.sampleRate, item.bitDepth,
  ].join(" ").toLocaleLowerCase();
}

function libraryFileInput() {
  const input = document.createElement("input");
  input.id = "sample-library-input";
  input.type = "file";
  input.multiple = true;
  input.accept = ".wav,.mp3,.flac,.cswp,audio/wav,audio/mpeg,audio/flac";
  input.hidden = true;
  input.addEventListener("change", async () => {
    const files = Array.from(input.files || []);
    input.value = "";
    if (files.length) await importFilesToLibrary(files);
  });
  return input;
}

function selectedLibraryAsset() {
  return libraryState.items.find((item) => item.id === librarySelection) || null;
}

function addSelectedLibraryToInbox() {
  const asset = selectedLibraryAsset();
  if (!asset) return;
  if (state.inbox.length >= MAX_INBOX_ITEMS) {
    announce(strings.inboxLimit, "warning");
    return;
  }
  state.inbox.push({ ...padFromLibraryAsset(asset), id: uid("inbox") });
  persistProject();
  librarySelection = null;
  libraryEditing = false;
  renderPlanner();
  announce(fill(strings.libraryInboxAdded, { name: asset.name, project: state.name }));
}

async function removeSelectedLibrary() {
  const asset = selectedLibraryAsset();
  if (!asset || !window.confirm(strings.removeLibraryConfirm)) return;
  libraryState.items = libraryState.items.filter((item) => item.id !== asset.id);
  librarySelection = null;
  libraryEditing = false;
  persistProject();
  if (!projectReferencedBlobIds().has(asset.blobId)) await deleteAudio(asset.blobId);
  stopPreview();
  renderPlanner();
  announce(strings.libraryRemoved);
}

function libraryEditor(section, asset) {
  const editor = el("div", "sample-library-editor");
  editor.append(waveform(asset));
  const facts = el("div", "sample-file-facts");
  [asset.originalName, formatBytes(asset.bytes), formatDuration(asset.duration), extOf(asset.originalName).toUpperCase()]
    .filter(Boolean).forEach((value) => facts.append(el("span", "", value)));
  editor.append(facts);

  const form = el("div", "sample-library-fields");
  const name = textInput("sample-library-name", asset.name, 80);
  const source = textInput("sample-library-source", asset.source, 240, strings.sourcePlaceholder);
  const tags = textInput("sample-library-tags", asset.tags, 240, strings.tagsPlaceholder);
  const notes = document.createElement("textarea");
  notes.id = "sample-library-notes";
  notes.value = asset.notes;
  notes.maxLength = 500;
  notes.rows = 3;
  notes.placeholder = strings.libraryNotesPlaceholder;
  const rights = textInput("sample-library-rights", asset.rights, 300, strings.libraryRightsPlaceholder);
  const stage = document.createElement("select");
  stage.id = "sample-library-stage";
  ["raw", "edited", "ready"].forEach((value) => stage.append(option(value, libraryStageLabel(value), value === asset.stage)));
  const bpm = document.createElement("input");
  bpm.id = "sample-library-bpm";
  bpm.type = "number";
  bpm.min = "20";
  bpm.max = "300";
  bpm.inputMode = "numeric";
  bpm.value = asset.bpm;
  const bind = (control, key, map = (value) => value) => control.addEventListener("input", () => {
    asset[key] = map(control.value);
    scheduleMetadataPersist();
  });
  bind(name, "name", (value) => value.slice(0, 80));
  bind(source, "source", (value) => value.slice(0, 240));
  bind(tags, "tags", (value) => value.slice(0, 240));
  bind(notes, "notes", (value) => value.slice(0, 500));
  bind(rights, "rights", (value) => value.slice(0, 300));
  bind(stage, "stage");
  bind(bpm, "bpm", (value) => value === "" ? "" : clampInt(value, 20, 300, ""));
  form.append(
    labeledField(strings.name, name),
    labeledField(strings.source, source),
    labeledField(strings.tags, tags),
    labeledField(strings.libraryStage, stage),
    labeledField(strings.bpm, bpm),
    labeledField(strings.libraryRights, rights),
    labeledField(strings.libraryNotes, notes),
  );
  editor.append(form);
  const actions = el("div", "sample-action-row sample-library-actions");
  const done = el("button", "sample-button sample-button-primary", strings.doneEditing);
  done.id = "btn-sample-library-done";
  done.type = "button";
  done.addEventListener("click", () => {
    persistProject();
    libraryEditing = false;
    renderPlanner();
    announce(strings.libraryUpdated);
  });
  const remove = el("button", "sample-button sample-button-danger", strings.removeLibrary);
  remove.id = "btn-sample-library-remove";
  remove.type = "button";
  remove.addEventListener("click", removeSelectedLibrary);
  actions.append(done, remove);
  editor.append(actions);
  section.append(editor);
}

function libraryPanel() {
  const section = el("section", "sample-panel sample-library-panel");
  section.setAttribute("aria-labelledby", "sample-library-heading");
  const top = el("div", "sample-section-top");
  const heading = el("h2", "sample-panel-heading", `${strings.sampleLibrary} · ${libraryState.items.length}`);
  heading.id = "sample-library-heading";
  top.append(heading, el("p", "sample-help", strings.libraryHint));
  section.append(top);

  const asset = selectedLibraryAsset();
  if (asset && libraryEditing) {
    libraryEditor(section, asset);
    return section;
  }

  const filters = el("div", "sample-library-filters");
  const search = textInput("sample-library-search", libraryQuery, 120, strings.librarySearchPlaceholder);
  search.setAttribute("aria-label", strings.librarySearch);
  const stage = document.createElement("select");
  stage.id = "sample-library-filter-stage";
  stage.setAttribute("aria-label", strings.libraryStage);
  stage.append(option("all", strings.stageAll, libraryStageFilter === "all"));
  ["raw", "edited", "ready"].forEach((value) => stage.append(option(value, libraryStageLabel(value), value === libraryStageFilter)));
  filters.append(search, stage);
  section.append(filters);

  const empty = el("p", "sample-library-empty", libraryState.items.length ? strings.noLibraryMatch : strings.libraryEmpty);
  const tray = el("div", "sample-library-tray");
  tray.setAttribute("role", "list");
  const applyFilters = () => {
    libraryQuery = search.value;
    libraryStageFilter = stage.value;
    const query = libraryQuery.trim().toLocaleLowerCase();
    let visible = 0;
    tray.querySelectorAll(".sample-library-item").forEach((row) => {
      const card = row.querySelector(".sample-library-card");
      const matches = (!query || card.dataset.search.includes(query))
        && (libraryStageFilter === "all" || card.dataset.stage === libraryStageFilter);
      row.hidden = !matches;
      if (matches) visible += 1;
    });
    empty.hidden = visible > 0;
  };
  search.addEventListener("input", applyFilters);
  stage.addEventListener("change", applyFilters);

  libraryState.items.forEach((item) => {
    const selected = item.id === librarySelection;
    const card = el("button", `sample-library-card sample-pad-${item.color}${selected ? " is-selected" : ""}`);
    card.type = "button";
    card.dataset.libraryId = item.id;
    card.dataset.stage = item.stage;
    card.dataset.search = librarySearchText(item);
    card.setAttribute("aria-pressed", String(selected));
    card.setAttribute("aria-label", `${item.name}, ${libraryStageLabel(item.stage)}, ${formatDuration(item.duration)}`);
    const mini = waveform(item);
    mini.classList.add("sample-waveform-mini");
    card.append(
      el("span", "sample-library-stage", libraryStageLabel(item.stage)),
      el("strong", "sample-library-name", item.name),
      el("span", "sample-library-meta", `${extOf(item.originalName).toUpperCase()} · ${formatDuration(item.duration)}${item.bpm ? ` · ${item.bpm} BPM` : ""}`),
      mini,
    );
    card.addEventListener("click", () => {
      librarySelection = item.id;
      libraryEditing = false;
      renderPlanner();
      const current = overlay.querySelector(`.sample-library-card[data-library-id="${item.id}"]`);
      current?.focus();
      previewPad(current, item);
      announce(fill(strings.librarySelected, { name: item.name }));
    });
    const row = el("div", "sample-library-item");
    row.setAttribute("role", "listitem");
    row.append(card);
    tray.append(row);
  });
  section.append(tray, empty);
  applyFilters();

  const input = libraryFileInput();
  const actions = el("div", "sample-action-row sample-library-actions");
  if (asset) {
    const add = el("button", "sample-button sample-button-primary", strings.addToInbox);
    add.id = "btn-sample-library-inbox";
    add.type = "button";
    add.addEventListener("click", addSelectedLibraryToInbox);
    const edit = el("button", "sample-button sample-button-secondary", strings.editDetails);
    edit.id = "btn-sample-library-edit";
    edit.type = "button";
    edit.addEventListener("click", () => { libraryEditing = true; renderPlanner(); });
    actions.append(add, edit);
  } else {
    const add = el("button", "sample-button sample-button-secondary", strings.addLibrary);
    add.id = "btn-sample-library-add";
    add.type = "button";
    add.addEventListener("click", () => input.click());
    actions.append(add);
  }
  section.append(input, actions);
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
  if (!allStoredBlobIds().has(removed.blobId)) await deleteAudio(removed.blobId);
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
      const row = el("div", "sample-inbox-item");
      row.setAttribute("role", "listitem");
      row.append(card);
      tray.append(row);
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
  returnButton.disabled = state.inbox.length >= MAX_INBOX_ITEMS;
  returnButton.addEventListener("click", () => {
    const pad = selectedPad();
    if (!pad) return;
    if (state.inbox.length >= MAX_INBOX_ITEMS) { announce(strings.inboxLimit, "warning"); return; }
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
    if (file) await importProjectFile(file, { openHandoff: true });
    importInput.value = "";
  });
  const importLabel = el("button", "sample-button sample-button-secondary", strings.importProject);
  importLabel.id = "btn-sample-project-import";
  importLabel.type = "button";
  importLabel.addEventListener("click", () => importInput.click());
  const remove = el("button", "sample-button sample-button-danger", strings.deleteProject);
  remove.id = "btn-sample-project-delete";
  remove.type = "button";
  remove.disabled = workspace.projects.length <= 1;
  remove.addEventListener("click", deleteCurrentProject);
  const uniqueBytes = libraryState.items.reduce((sum, item) => sum + item.bytes, 0);
  const usage = el("p", "sample-storage-usage", `${strings.usage}: ${fill(strings.usageProjects, { count: workspace.projects.length })} · ${fill(strings.usageSounds, { count: libraryState.items.length })} / ${formatBytes(uniqueBytes)}`);
  const toolsActions = el("div", "sample-action-row sample-project-tool-actions");
  toolsActions.append(importLabel, remove);
  content.append(importInput, toolsActions, usage, el("p", "sample-copyright", strings.copyright));
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
  const handoff = el("button", "sample-button sample-button-primary", handoffButtonLabel());
  handoff.id = "btn-sample-handoff";
  handoff.type = "button";
  handoff.addEventListener("click", async () => {
    if (!allAssignedPads().length) { announce(strings.noPads, "warning"); return; }
    stopPreview();
    announce(strings.checking);
    const saved = savedHandoffForProject();
    const resuming = handoffMatchesRows(saved)
      && saved.entries.some((entry) => entry.status !== "pending");
    const report = await validateProject();
    if (report.blocking) renderValidation(report);
    else if (resuming) beginHandoff();
    else if (report.issues.length) renderValidation(report);
    else beginHandoff();
  });
  actions.append(save, handoff);
  footer.append(actions, projectTools());
  return footer;
}

function renderPlanner() {
  if (!overlay || overlay.hidden) return;
  overlay.dataset.view = "planner";
  const content = el("div", "sample-lab-shell");
  const notice = placementNotice();
  content.append(projectHeader(), hero(), projectPanel(), bankStrip(), libraryPanel(), inboxPanel());
  if (notice) content.append(notice);
  content.append(padGrid());
  if (armedPlacement?.type !== "pad") content.append(padEditor());
  content.append(plannerFooter());
  overlay.replaceChildren(content);
  publishDiagnostics();
}

async function audioItemFromFile(file, prior = null) {
  const { asset } = await libraryAssetFromFile(file);
  return padFromLibraryAsset(asset, prior);
}

async function importFilesToLibrary(fileList) {
  const files = Array.from(fileList || []).slice(0, MAX_BATCH_FILES);
  let rejected = Math.max(0, Array.from(fileList || []).length - files.length);
  let added = 0;
  let duplicates = 0;
  stopPreview();
  librarySelection = null;
  libraryEditing = false;
  for (let index = 0; index < files.length; index += 1) {
    const file = files[index];
    const extension = extOf(file.name);
    if (!SUPPORTED_EXTENSIONS.has(extension) || file.size > MAX_AUDIO_BYTES) {
      rejected += 1;
      continue;
    }
    announce(`${strings.importing} ${index + 1}/${files.length}`);
    try {
      const result = await libraryAssetFromFile(file);
      if (result.reused) duplicates += 1;
      else added += 1;
    } catch (_) { rejected += 1; }
  }
  if (added || duplicates) persistProject();
  renderPlanner();
  if (fileList.length > MAX_BATCH_FILES) announce(strings.batchLimit, "warning");
  else if (!added && !duplicates) announce(strings.invalidFile, "warning");
  else announce(fill(strings.libraryAdded, {
    added,
    duplicates: duplicates ? fill(strings.libraryDuplicates, { count: duplicates }) : "",
    rejected: rejected ? fill(strings.inboxRejected, { count: rejected }) : "",
  }), rejected ? "warning" : "ok");
}

async function importFilesToInbox(fileList) {
  const files = Array.from(fileList || []).slice(0, MAX_BATCH_FILES);
  let rejected = Math.max(0, Array.from(fileList || []).length - files.length);
  let added = 0;
  let inboxFull = false;
  stopPreview();
  armedPlacement = null;
  for (let index = 0; index < files.length; index += 1) {
    if (state.inbox.length >= MAX_INBOX_ITEMS) {
      rejected += files.length - index;
      inboxFull = true;
      break;
    }
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
  if (inboxFull) announce(strings.inboxLimit, "warning");
  else if (fileList.length > MAX_BATCH_FILES) announce(strings.batchLimit, "warning");
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
  if (selectedPad() && state.inbox.length >= MAX_INBOX_ITEMS) { announce(strings.inboxLimit, "warning"); return; }
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
    const result = await shareOrDownload(file, name);
    if (result === "shared") announce(strings.projectShared);
    else if (result === "downloaded") announce(strings.projectDownloaded);
    else announce(strings.shareCancelled, "warning");
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

async function importProjectFile(file, options = {}) {
  try {
    const parsed = await readProjectManifest(file);
    const existing = workspace.projects.findIndex((project) => project.id === parsed.project.id);
    if (existing < 0 && workspace.projects.length >= MAX_PROJECTS) {
      announce(strings.projectLimit, "warning");
      return false;
    }
    const importedAssets = new Map();
    for (const entry of parsed.manifest.files) {
      const name = String(entry.name || "sample");
      const type = String(entry.type || "application/octet-stream");
      const blob = file.slice(parsed.payloadOffset + entry.offset, parsed.payloadOffset + entry.offset + entry.length, type);
      const portableFile = new File([blob], name, { type, lastModified: file.lastModified || Date.now() });
      const { asset } = await libraryAssetFromFile(portableFile);
      importedAssets.set(entry.id, asset);
    }
    const reconnect = (pad) => {
      const asset = importedAssets.get(pad.blobId);
      if (!asset) return;
      pad.blobId = asset.blobId;
      pad.fingerprint = asset.fingerprint;
    };
    SLOT_NAMES.forEach((slot) => Object.values(parsed.project.slots[slot].pads).forEach(reconnect));
    parsed.project.inbox.forEach(reconnect);
    if (existing >= 0) workspace.projects[existing] = parsed.project;
    else workspace.projects.push(parsed.project);
    state = parsed.project;
    workspace.activeProjectId = state.id;
    seedLibraryFromProjects();
    armedPlacement = null;
    librarySelection = null;
    libraryEditing = false;
    handoffSession = null;
    persistProject();
    stopPreview();
    if (options?.openHandoff === true && allAssignedPads().length) {
      const report = await validateProject();
      if (report.issues.length) renderValidation(report);
      else beginHandoff();
    } else renderPlanner();
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
      beginHandoff();
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
  if (!handoffSession || handoffSession.projectId !== state.id || !handoffMatchesRows(handoffSession, rows)) {
    syncHandoffSession(rows);
  }
  const entry = currentHandoffEntry();
  if (!entry) { renderHandoffReceipt(); return; }
  handoffIndex = rows.findIndex((row) => handoffRowKey(row) === entry.key);
  if (handoffIndex < 0) { syncHandoffSession(rows); renderHandoff(); return; }
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
  destination.tabIndex = -1;
  card.append(progress, destination, el("strong", "sample-handoff-name", row.data.name));
  const info = el("dl", "sample-handoff-info");
  info.append(el("dt", "", strings.file), el("dd", "", `${row.data.originalName} · ${formatBytes(row.data.bytes)}`));
  card.append(info);
  const steps = el("ol", "sample-handoff-steps");
  steps.append(el("li", "", strings.step1), el("li", "", strings.step2), el("li", "", strings.step3));
  card.append(steps);
  const status = el("p", "sample-status", entry.status === "shared" ? strings.awaitingConfirm : strings.handoffSaved);
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  card.append(status);
  const actions = el("div", "sample-primary-actions");
  if (entry.status === "shared") {
    const loaded = el("button", "sample-button sample-button-primary", strings.loadedPad);
    loaded.id = "btn-sample-handoff-loaded";
    loaded.type = "button";
    loaded.addEventListener("click", () => markCurrentHandoff("loaded"));
    const problem = el("button", "sample-button sample-button-danger", strings.problemPad);
    problem.id = "btn-sample-handoff-problem";
    problem.type = "button";
    problem.addEventListener("click", () => markCurrentHandoff("problem"));
    actions.append(loaded, problem);
  } else {
    const share = el("button", "sample-button sample-button-primary", navigator.share && navigator.canShare ? strings.shareFile : strings.downloadFile);
    share.id = "btn-sample-share-file";
    share.type = "button";
    share.addEventListener("click", async () => {
      Array.from(actions.querySelectorAll("button")).forEach((button) => { button.disabled = true; });
      const record = await getAudio(row.data.blobId);
      if (!record?.blob) {
        Array.from(actions.querySelectorAll("button")).forEach((button) => { button.disabled = false; });
        announce(strings.readFailed, "warning");
        return;
      }
      const file = new File([record.blob], row.data.originalName, { type: row.data.mime || record.blob.type, lastModified: Date.now() });
      const result = await shareOrDownload(file, row.data.originalName);
      if (result === "cancelled") {
        Array.from(actions.querySelectorAll("button")).forEach((button) => { button.disabled = false; });
        announce(strings.shareCancelled, "warning");
        return;
      }
      entry.status = "shared";
      entry.sharedAt = new Date().toISOString();
      entry.resolvedAt = "";
      handoffSession.updatedAt = entry.sharedAt;
      persistHandoffs();
      renderHandoff();
      announce(result === "shared"
        ? fill(strings.sharedReady, { name: row.data.originalName })
        : fill(strings.downloadReady, { name: row.data.originalName }));
    });
    const skip = el("button", "sample-button sample-button-secondary", strings.skipPad);
    skip.id = "btn-sample-skip-pad";
    skip.type = "button";
    skip.addEventListener("click", () => markCurrentHandoff("skipped"));
    actions.append(share, skip);
  }
  card.append(actions);
  shell.append(header, heroSection, card);
  overlay.replaceChildren(shell);
  destination.focus();
  publishDiagnostics();
}

function renderHandoffReceipt() {
  if (!handoffSession || handoffSession.projectId !== state.id) { beginHandoff(); return; }
  overlay.dataset.view = "receipt";
  const counts = handoffCounts();
  const shell = el("div", "sample-lab-shell sample-handoff-shell sample-receipt-shell");
  const heroSection = el("section", "sample-hero sample-handoff-hero");
  heroSection.append(el("p", "sample-eyebrow", strings.receiptEyebrow));
  const title = el("h1", "", strings.receiptTitle);
  title.tabIndex = -1;
  const summaryText = counts.loaded === counts.total
    ? fill(strings.receiptComplete, { total: counts.total })
    : fill(strings.receiptPartial, counts);
  heroSection.append(title, el("p", "sample-lede", summaryText));
  const card = el("section", "sample-handoff-card sample-receipt-card");
  card.setAttribute("aria-labelledby", "sample-receipt-heading");
  const heading = el("h2", "sample-validation-summary", state.name);
  heading.id = "sample-receipt-heading";
  card.append(heading);
  const list = el("ul", "sample-receipt-list");
  handoffSession.entries.forEach((entry) => {
    const item = el("li", `is-${entry.status}`);
    item.dataset.status = entry.status;
    const destination = el("strong", "", `${entry.slot} / BANK ${entry.bank} / PAD ${entry.pad}`);
    const name = el("span", "", entry.name);
    const status = el("span", "sample-receipt-status",
      entry.status === "loaded" ? strings.receiptLoaded
        : entry.status === "problem" ? strings.receiptProblem : strings.receiptSkipped);
    item.append(destination, name, status);
    list.append(item);
  });
  card.append(list);
  const status = el("p", "sample-status", strings.handoffSaved);
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  card.append(status);
  const actions = el("div", "sample-primary-actions");
  if (counts.problem + counts.skipped > 0) {
    const retry = el("button", "sample-button sample-button-secondary", strings.retryUnresolved);
    retry.id = "btn-sample-handoff-retry";
    retry.type = "button";
    retry.addEventListener("click", retryUnresolvedHandoff);
    actions.append(retry);
  }
  const finish = el("button", "sample-button sample-button-primary", strings.finish);
  finish.id = "btn-sample-handoff-finish";
  finish.type = "button";
  finish.addEventListener("click", renderPlanner);
  actions.append(finish);
  card.append(actions);
  shell.append(projectHeader(), heroSection, card);
  overlay.replaceChildren(shell);
  title.focus();
  publishDiagnostics();
}

function publishDiagnostics() {
  const savedHandoff = handoffSession || savedHandoffForProject();
  window.__SXC1_SAMPLE_LAB = {
    ready: started,
    route: ROUTE,
    schema: FORMAT_SCHEMA,
    storage: persistentAudio ? "indexeddb" : "temporary",
    projectId: state?.id || null,
    projectName: state?.name || null,
    projects: workspace ? workspace.projects.map((project) => ({ id: project.id, name: project.name, inbox: project.inbox.length, assigned: assignedPadCount(project) })) : [],
    libraryItems: libraryState ? libraryState.items.map((item) => ({ id: item.id, blobId: item.blobId, name: item.name, filename: item.originalName, stage: item.stage, fingerprint: item.fingerprint })) : [],
    librarySelection,
    activeSlot: state?.activeSlot || null,
    selectedPad: state?.selectedPad || null,
    inboxItems: state ? state.inbox.map((item) => ({ id: item.id, name: item.name, filename: item.originalName, bytes: item.bytes })) : [],
    placement: armedPlacement ? { ...armedPlacement } : null,
    assignedPads: state ? allAssignedPads().map((row) => ({ slot: row.slot, bank: row.bank, pad: row.pad, name: row.data.name, filename: row.data.originalName })) : [],
    handoff: savedHandoff ? {
      projectId: savedHandoff.projectId,
      currentKey: savedHandoff.currentKey,
      finishedAt: savedHandoff.finishedAt,
      counts: handoffCounts(savedHandoff),
      entries: savedHandoff.entries.map((entry) => ({
        key: entry.key,
        slot: entry.slot,
        bank: entry.bank,
        pad: entry.pad,
        name: entry.name,
        filename: entry.originalName,
        status: entry.status,
      })),
    } : null,
    exportProjectBlob,
    importProjectFile,
    validateProject,
    beginHandoff,
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
  state = loadWorkspace();
  overlay = createOverlay();
  try { db = await openDatabase(); }
  catch (_) { persistentAudio = false; }
  persistProject();
  persistHandoffs();
  enhanceHome();
  setRouteActive();
  window.addEventListener("hashchange", setRouteActive);
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || overlay.hidden) return;
    if (armedPlacement) { event.preventDefault(); cancelPlacement(); return; }
    if (["validation", "handoff", "receipt"].includes(overlay.dataset.view)) {
      event.preventDefault();
      renderPlanner();
      requestAnimationFrame(() => overlay.querySelector("#btn-sample-handoff")?.focus());
      return;
    }
    if (libraryEditing || librarySelection || creatingProject) {
      event.preventDefault();
      libraryEditing = false;
      librarySelection = null;
      creatingProject = false;
      renderPlanner();
      requestAnimationFrame(() => overlay.querySelector("#sample-library-search, #btn-sample-project-new")?.focus());
    }
  });
  new MutationObserver(() => {
    enhanceHome();
    if (window.location.hash.startsWith(ROUTE)) setRouteActive();
  }).observe(document.getElementById("app") || document.body, { childList: true, subtree: true });
  publishDiagnostics();
}

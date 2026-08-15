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
const MAX_HANDOFF_KEY_CHARS = 320;
const MAX_HANDOFF_TIMESTAMP_CHARS = 40;
const SXC1_MAX_SAMPLE_BYTES = 173 * 1024 * 1024;
const SXC1_MAX_SAMPLE_SECONDS = 15 * 60;
const SLOT_NAMES = ["A", "B", "C", "D"];
const SUPPORTED_EXTENSIONS = new Set(["wav", "mp3", "flac", "cswp"]);

const COPY = {
  en: {
    homeTitle: "Prepare a sound",
    homeSub: "Check, place, and load your next sample",
    library: "Course, Sample Lab, manuals, and progress",
    todayStep: "Today's practice step",
    skipToday: "Skip for today",
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
    libraryOptions: "Library options",
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
    soundCheckEyebrow: "SOUND CHECK",
    soundCheckTitle: "Is this sound ready?",
    soundCheckIntro: "Read the original file locally, then leave Audacity only the work that matters.",
    checkReadiness: "Check readiness",
    checkWorking: "Reading the original WAV bytes…",
    checkFailed: "This sound could not be checked. Its original bytes are unchanged.",
    checkAgain: "Try again",
    checkDone: "Done",
    readyTitle: "Ready for the SXC-1",
    readyBody: "The required file checks pass. Advisory findings are yours to judge by ear.",
    needsWorkTitle: "Prepare this in Audacity",
    needsWorkBody: "Only the findings below need attention before the next handoff.",
    criterionFormat: "Format",
    criterionRate: "Sample rate",
    criterionDepth: "Bit depth",
    criterionChannels: "Channels",
    criterionDuration: "Duration",
    criterionSize: "File size",
    criterionClipping: "Clipping",
    criterionSilence: "Edge silence",
    criterionPass: "Pass",
    criterionFix: "Fix",
    criterionReview: "Review",
    criterionUnknown: "Not inspected",
    pcmWav: "PCM WAV",
    convertWav: "Convert to PCM WAV",
    invalidWav: "The WAV container could not be read",
    stereo: "Stereo",
    noClipping: "No full-scale samples found",
    clippingFound: "{count} clipped frame(s) found",
    noEdgeSilence: "No meaningful silence at the edges",
    edgeSilence: "{leading}s leading · {trailing}s trailing",
    allSilence: "The scanned audio is silent",
    scanTooLarge: "Header checked; PCM scan skipped above 48 MB",
    scanUnsupported: "Header checked; this WAV encoding cannot be scanned exactly",
    convertFirst: "Convert to WAV before checking PCM details",
    deviceLimit: "15:00 maximum",
    sizeLimit: "About 173 MB maximum",
    recipeTitle: "Audacity recipe",
    recipeIntro: "This recipe contains only this file’s findings.",
    copyRecipe: "Copy Audacity recipe",
    recipeCopied: "Recipe copied. Make the edits in Audacity, then bring back the export.",
    recipeCopyFailed: "The recipe could not be copied. Nothing changed; try again or keep this check open beside Audacity.",
    importEdited: "Import edited version",
    checkingEdited: "Checking the edited export…",
    editedVersion: "Edited version",
    editedVersionIntro: "Compare the new check, then make one decision for every pad using the original.",
    useVersion: "Use this version",
    keepCurrent: "Keep current",
    sameVersion: "That export is byte-for-byte identical to the current sound.",
    linkedVersion: "That file is already linked as a newer version of another sound.",
    versionImported: "Edited version imported; the current pad assignments have not changed yet.",
    versionUsed: "Updated {placements} placement(s) across {projects} project(s).",
    versionKept: "Kept the current version. The edited export remains in the Library.",
    previousVersion: "Previous version: {name}",
    protectsVersion: "A newer version points back to this original. Remove the newer version first.",
    learnWhy: "Learn why these limits matter",
    recipeOpen: "Open the source in Audacity.",
    recipeExport: "File → Export Audio: choose WAV, Stereo, 48000 Hz, and Signed 16-bit PCM.",
    recipeTrim: "Select the audio to keep, then Edit → Remove Special → Trim Audio. Keep it under 15:00 and about 173 MB.",
    recipeClipping: "Use View → Show Clipping. Re-record or lower gain when possible; use Clip Fix only for a short damaged region.",
    recipeSilence: "Select the intended sound and use Edit → Remove Special → Trim Audio to remove the flagged edge silence.",
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
    practiceBank: "Practice this bank",
    padPracticeEyebrow: "PAD PRACTICE",
    padPracticeTitle: "Practice Bank {bank}",
    padPracticeIntro: "Switch to slot {slot}. These are the pads you last loaded for this bank.",
    padPracticeLastLoaded: "Last loaded is a saved handoff receipt, not a live check of the SXC-1.",
    padPracticeWalk: "Walk pad by pad",
    padPracticeStep: "Pad {current} of {total}",
    padPracticePlay: "Play pad {pad} — {name}",
    padPracticeNext: "Next pad",
    padPracticeFinish: "Finish practice",
    padPracticeDecision: "How did this bank practice go?",
    padPracticeDecisionBody: "Make one honest decision for the whole run. Individual pad steps are only navigation.",
    padPracticeMark: "Mark practiced",
    padPracticeRecorded: "Bank {bank} marked practiced",
    padPracticeRecordedBody: "One private practice receipt was saved for {slot}:{bank}.",
    padPracticeUnloaded: "Load this bank first",
    padPracticeUnloadedBody: "One or more assigned pads do not have a matching Loaded receipt. Open the existing phone handoff before practicing this bank.",
    padPracticeOpenHandoff: "Open phone handoff",
    padPracticeUnavailable: "This practice bank is no longer available",
    padPracticeUnavailableBody: "The project, slot, or bank may have changed since this link was created. Nothing was recorded.",
  },
  ja: {
    homeTitle: "音源を準備する",
    homeSub: "確認・配置・読み込みをひとつの流れで",
    library: "コース、Sample Lab、マニュアル、進捗",
    todayStep: "今日の練習ステップ",
    skipToday: "今日はスキップ",
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
    libraryOptions: "ライブラリのオプション",
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
    soundCheckEyebrow: "サウンドチェック",
    soundCheckTitle: "この音源は準備できていますか？",
    soundCheckIntro: "元ファイルを端末内で読み取り、必要な作業だけをAudacityへ渡します。",
    checkReadiness: "準備状態を確認",
    checkWorking: "元のWAVデータを確認中…",
    checkFailed: "この音源を確認できませんでした。元データは変更されていません。",
    checkAgain: "もう一度確認",
    checkDone: "完了",
    readyTitle: "SXC-1で使用できます",
    readyBody: "必須のファイル確認に合格しました。注意項目は実際に聴いて判断してください。",
    needsWorkTitle: "Audacityで準備してください",
    needsWorkBody: "次の引き渡し前に、下記の項目だけを修正してください。",
    criterionFormat: "形式",
    criterionRate: "サンプルレート",
    criterionDepth: "ビット深度",
    criterionChannels: "チャンネル",
    criterionDuration: "長さ",
    criterionSize: "ファイルサイズ",
    criterionClipping: "クリッピング",
    criterionSilence: "前後の無音",
    criterionPass: "合格",
    criterionFix: "修正",
    criterionReview: "確認",
    criterionUnknown: "未確認",
    pcmWav: "PCM WAV",
    convertWav: "PCM WAVへ変換",
    invalidWav: "WAVコンテナを読み取れませんでした",
    stereo: "ステレオ",
    noClipping: "最大振幅に達したサンプルはありません",
    clippingFound: "クリッピングしたフレーム：{count}",
    noEdgeSilence: "前後に目立つ無音はありません",
    edgeSilence: "冒頭 {leading}秒・末尾 {trailing}秒",
    allSilence: "確認した音声は無音です",
    scanTooLarge: "ヘッダーのみ確認（48 MBを超えるためPCM走査を省略）",
    scanUnsupported: "ヘッダーのみ確認（このWAV形式は正確に走査できません）",
    convertFirst: "PCM情報を確認する前にWAVへ変換してください",
    deviceLimit: "最大15分",
    sizeLimit: "最大約173 MB",
    recipeTitle: "Audacityレシピ",
    recipeIntro: "このファイルで必要な項目だけを表示しています。",
    copyRecipe: "Audacityレシピをコピー",
    recipeCopied: "レシピをコピーしました。Audacityで編集し、書き出したファイルを戻してください。",
    recipeCopyFailed: "レシピをコピーできませんでした。内容は変更されていません。もう一度試すか、この画面をAudacityと並べて使用してください。",
    importEdited: "編集済みファイルを読み込む",
    checkingEdited: "編集済みファイルを確認中…",
    editedVersion: "編集済みバージョン",
    editedVersionIntro: "新しい確認結果を見て、元ファイルを使う全パッドについて1つ選んでください。",
    useVersion: "このバージョンを使う",
    keepCurrent: "現在のまま",
    sameVersion: "現在の音源とまったく同じファイルです。",
    linkedVersion: "このファイルは、すでに別の音源の新しいバージョンとして関連付けられています。",
    versionImported: "編集済みバージョンを読み込みました。パッドの割り当てはまだ変更していません。",
    versionUsed: "{projects}件のプロジェクトで{placements}か所を更新しました。",
    versionKept: "現在のバージョンを維持しました。編集済みファイルはライブラリに残ります。",
    previousVersion: "前のバージョン：{name}",
    protectsVersion: "新しいバージョンからこの元ファイルが参照されています。先に新しいバージョンを削除してください。",
    learnWhy: "この制限の理由を学ぶ",
    recipeOpen: "Audacityで元ファイルを開きます。",
    recipeExport: "「ファイル」→「オーディオをエクスポート」で、WAV・ステレオ・48000 Hz・Signed 16-bit PCMを選びます。",
    recipeTrim: "残す音声を選択し、「編集」→「特殊な削除」→「オーディオをトリミング」を実行します。15分・約173 MB以内に収めます。",
    recipeClipping: "「表示」→「クリッピングを表示」で確認します。可能なら録り直すか入力ゲインを下げ、短い損傷部分だけClip Fixを使います。",
    recipeSilence: "残す音声を選び、「編集」→「特殊な削除」→「オーディオをトリミング」で前後の無音を除きます。",
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
    practiceBank: "このバンクを練習",
    padPracticeEyebrow: "パッド練習",
    padPracticeTitle: "BANK {bank}を練習",
    padPracticeIntro: "スロット{slot}へ切り替えます。このバンクで最後に読込済みにしたパッドです。",
    padPracticeLastLoaded: "「最後に読込済み」は保存された引き渡し記録で、SXC-1の現在状態を確認するものではありません。",
    padPracticeWalk: "パッドごとに確認",
    padPracticeStep: "{total}件中 {current}番目",
    padPracticePlay: "PAD {pad} — {name} を演奏",
    padPracticeNext: "次のパッド",
    padPracticeFinish: "練習を終える",
    padPracticeDecision: "このバンクの練習はどうでしたか？",
    padPracticeDecisionBody: "バンク全体について1回だけ正直に記録します。各パッド画面は移動の案内だけです。",
    padPracticeMark: "練習済みにする",
    padPracticeRecorded: "BANK {bank}を練習済みにしました",
    padPracticeRecordedBody: "{slot}:{bank} の非公開練習記録を1件保存しました。",
    padPracticeUnloaded: "先にこのバンクを読み込む",
    padPracticeUnloadedBody: "割り当て済みパッドの一部に一致する読込済み記録がありません。練習前に既存のスマートフォン引き渡しを開いてください。",
    padPracticeOpenHandoff: "スマートフォン引き渡しを開く",
    padPracticeUnavailable: "この練習バンクは利用できません",
    padPracticeUnavailableBody: "リンク作成後にプロジェクト、スロット、またはバンクが変わった可能性があります。記録は保存されていません。",
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
let handoffPersisted = true;
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
let soundCheckState = null;
let padPracticeState = null;
let activePracticeIntent = null;
let lastPracticeIntent = "";
let metadataPersistTimer = null;
let libraryImportQueue = Promise.resolve();
const memoryAudio = new Map();

function uid(prefix = "id") {
  try { return `${prefix}-${crypto.randomUUID()}`; } catch (_) {
    return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }
}

function recordPractice(kind, detail = {}) {
  return window.__SXC1_PRACTICE_LOOP?.record?.(kind, {
    projectId: state?.id || "",
    ...detail,
  }) || null;
}

function practiceRouteIntent() {
  if (!window.location.hash.startsWith(`${ROUTE}?`)) return null;
  try {
    const url = new URL(window.location.hash.slice(1), window.location.origin);
    const practice = url.searchParams.get("practice");
    if (!["organize", "check", "handoff", "pads"].includes(practice)) return null;
    return {
      key: url.pathname + url.search,
      practice,
      projectId: String(url.searchParams.get("project") || "").slice(0, 180),
      assetId: String(url.searchParams.get("asset") || "").slice(0, 180),
      slot: String(url.searchParams.get("slot") || "").slice(0, 1).toUpperCase(),
      bank: clampInt(url.searchParams.get("bank"), 15, 80, 0),
      today: url.searchParams.get("today") === "1",
    };
  } catch (_) { return null; }
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

function normalizedHandoffTimestamp(value) {
  return typeof value === "string" ? value.slice(0, MAX_HANDOFF_TIMESTAMP_CHARS) : "";
}

function normalizeHandoffEntry(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.key !== "string" || !raw.key) return null;
  const status = ["pending", "shared", "loaded", "problem", "skipped"].includes(raw.status)
    ? raw.status
    : "pending";
  return {
    key: raw.key.slice(0, MAX_HANDOFF_KEY_CHARS),
    slot: SLOT_NAMES.includes(raw.slot) ? raw.slot : "A",
    bank: clampInt(raw.bank, 15, 80, 15),
    pad: clampInt(raw.pad, 1, 16, 1),
    blobId: String(raw.blobId || "").slice(0, 180),
    name: String(raw.name || "Sample").slice(0, 80),
    originalName: String(raw.originalName || "sample").slice(0, 240),
    status,
    sharedAt: normalizedHandoffTimestamp(raw.sharedAt),
    resolvedAt: normalizedHandoffTimestamp(raw.resolvedAt),
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
  const currentKey = typeof raw.currentKey === "string"
    ? raw.currentKey.slice(0, MAX_HANDOFF_KEY_CHARS)
    : "";
  return {
    projectId: raw.projectId.slice(0, 180),
    entries,
    currentKey: keys.has(currentKey) ? currentKey : "",
    startedAt: normalizedHandoffTimestamp(raw.startedAt) || new Date().toISOString(),
    updatedAt: normalizedHandoffTimestamp(raw.updatedAt) || new Date().toISOString(),
    finishedAt: normalizedHandoffTimestamp(raw.finishedAt),
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
  if (raw) result.updatedAt = normalizedHandoffTimestamp(raw.updatedAt) || result.updatedAt;
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

function normalizeReadiness(raw) {
  if (!raw || typeof raw !== "object") return null;
  const findings = Array.isArray(raw.findings)
    ? raw.findings.filter((value) => typeof value === "string").slice(0, 12).map((value) => value.slice(0, 40))
    : [];
  return {
    checkedAt: typeof raw.checkedAt === "string" ? raw.checkedAt.slice(0, 40) : "",
    ready: raw.ready === true,
    advisory: clampInt(raw.advisory, 0, 12, 0),
    findings,
  };
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
    replacesId: typeof raw.replacesId === "string" ? raw.replacesId.slice(0, 180) : "",
    readiness: normalizeReadiness(raw.readiness),
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
  const validIds = new Set(result.items.map((item) => item.id));
  result.items.forEach((item) => {
    if (item.replacesId === item.id || !validIds.has(item.replacesId)) item.replacesId = "";
  });
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
  try {
    localStorage.setItem(HANDOFF_KEY, JSON.stringify(handoffState));
    handoffPersisted = true;
  } catch (_) {
    handoffPersisted = false;
  }
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
  soundCheckState = null;
  padPracticeState = null;
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
  soundCheckState = null;
  padPracticeState = null;
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
  soundCheckState = null;
  padPracticeState = null;
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

function assignedPadsForProject(project = state) {
  const rows = [];
  SLOT_NAMES.forEach((slot) => {
    const bank = project.slots[slot];
    for (let pad = 1; pad <= 16; pad += 1) {
      if (bank.pads[pad]) rows.push({ slot, bank: bank.bank, bankName: bank.name, pad, data: bank.pads[pad] });
    }
  });
  return rows;
}

function allAssignedPads() { return assignedPadsForProject(state); }

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

function syncHandoffSessionForProject(project, rows = assignedPadsForProject(project), shouldPersist = true) {
  const previous = savedHandoffForProject(project.id);
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
    projectId: project.id,
    entries,
    currentKey,
    startedAt: previous?.startedAt || now,
    updatedAt: now,
    finishedAt: finished ? (changed ? now : previous?.finishedAt || now) : "",
  };
  const index = handoffState.sessions.findIndex((candidate) => candidate.projectId === project.id);
  if (index >= 0) handoffState.sessions[index] = session;
  else {
    handoffState.sessions.push(session);
    if (handoffState.sessions.length > MAX_HANDOFF_SESSIONS) {
      handoffState.sessions.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
      handoffState.sessions.length = MAX_HANDOFF_SESSIONS;
    }
  }
  if (project.id === state.id) handoffSession = session;
  if (shouldPersist) persistHandoffs();
  return session;
}

function syncHandoffSession(rows = allAssignedPads()) {
  return syncHandoffSessionForProject(state, rows);
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
  if (status === "loaded") recordPractice("pad-loaded", { ref: entry.key });
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
    recordPractice("sample-placed", { ref: item.id });
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

function bankPracticeRows(slot = state?.activeSlot, bank = state?.slots?.[slot]?.bank) {
  return assignedPadsForProject().filter((row) => row.slot === slot && row.bank === bank);
}

function bankLastLoaded(rows) {
  const receipt = savedHandoffForProject();
  const loaded = new Set((receipt?.entries || [])
    .filter((entry) => entry.status === "loaded")
    .map((entry) => entry.key));
  return rows.length > 0 && rows.every((row) => loaded.has(handoffRowKey(row)));
}

function beginPadPractice(slot, bank, unavailable = false) {
  const targetSlot = SLOT_NAMES.includes(slot) ? slot : "";
  const targetBank = clampInt(bank, 15, 80, 0);
  const current = targetSlot ? state?.slots?.[targetSlot] : null;
  const rows = !unavailable && current?.bank === targetBank
    ? bankPracticeRows(targetSlot, targetBank)
    : [];
  if (!rows.length) {
    padPracticeState = { phase: "unavailable", slot: targetSlot, bank: targetBank, rows: [], index: 0, recorded: false };
  } else {
    if (state.activeSlot !== targetSlot) {
      state.activeSlot = targetSlot;
      persistProject();
    }
    padPracticeState = {
      phase: bankLastLoaded(rows) ? "intro" : "reminder",
      slot: targetSlot,
      bank: targetBank,
      rows,
      index: 0,
      recorded: false,
    };
  }
  renderPadPractice();
}

function leavePadPractice() {
  padPracticeState = null;
  if (activePracticeIntent?.today && window.__SXC1_PRACTICE_LOOP?.skip?.()) return;
  history.replaceState(null, "", ROUTE);
  activePracticeIntent = null;
  lastPracticeIntent = "";
  renderPlanner();
}

function markPadPracticed() {
  if (!padPracticeState || padPracticeState.recorded || padPracticeState.phase !== "decision") return;
  padPracticeState.recorded = true;
  padPracticeState.phase = "recorded";
  const { slot, bank } = padPracticeState;
  recordPractice("pad-played", { ref: `${slot}:${bank}` });
  renderPadPractice();
}

function padPracticeActions(items) {
  const actions = el("div", "sample-primary-actions sample-pad-practice-actions");
  items.slice(0, 2).forEach(({ id, label, primary = false, run }) => {
    const button = el("button", `sample-button ${primary ? "sample-button-primary" : "sample-button-secondary"}`, label);
    button.id = id;
    button.type = "button";
    button.addEventListener("click", run);
    actions.append(button);
  });
  return actions;
}

function renderPadPractice() {
  const session = padPracticeState;
  if (!session) { renderPlanner(); return; }
  overlay.dataset.view = "pad-practice";
  overlay.dataset.practicePhase = session.phase;
  const shell = el("div", "sample-lab-shell sample-pad-practice-shell");
  const heroSection = el("section", "sample-hero sample-pad-practice-hero");
  heroSection.append(el("p", "sample-eyebrow", strings.padPracticeEyebrow));
  const titleText = session.phase === "unavailable"
    ? strings.padPracticeUnavailable
    : fill(strings.padPracticeTitle, session);
  const title = el("h1", "", titleText);
  title.tabIndex = -1;
  heroSection.append(title);
  const card = el("section", "sample-panel sample-pad-practice-card");

  if (session.phase === "unavailable") {
    card.append(el("p", "sample-lede", strings.padPracticeUnavailableBody));
    card.append(padPracticeActions([{ id: "btn-pad-practice-back", label: strings.backPlanner, primary: true, run: leavePadPractice }]));
  } else if (session.phase === "reminder") {
    heroSection.append(el("p", "sample-lede", fill(strings.padPracticeIntro, session)));
    card.append(el("h2", "sample-panel-heading", strings.padPracticeUnloaded));
    card.append(el("p", "sample-help", strings.padPracticeUnloadedBody));
    card.append(padPracticeActions([
      { id: "btn-pad-practice-handoff", label: strings.padPracticeOpenHandoff, primary: true, run: () => { padPracticeState = null; beginHandoff(); } },
      { id: "btn-pad-practice-back", label: strings.backPlanner, run: leavePadPractice },
    ]));
  } else if (session.phase === "intro") {
    heroSection.append(el("p", "sample-lede", fill(strings.padPracticeIntro, session)));
    card.append(el("p", "sample-pad-practice-honesty", strings.padPracticeLastLoaded));
    const grid = el("ol", "sample-pad-practice-grid");
    session.rows.forEach((row) => {
      const item = el("li", `sample-pad-practice-pad sample-pad-${row.data.color || "white"}`);
      item.dataset.pad = String(row.pad);
      item.dataset.color = row.data.color || "white";
      item.append(el("span", "sample-pad-number", String(row.pad)), el("strong", "sample-pad-name", row.data.name));
      grid.append(item);
    });
    card.append(grid, padPracticeActions([
      { id: "btn-pad-practice-walk", label: strings.padPracticeWalk, primary: true, run: () => { session.phase = "pad"; renderPadPractice(); } },
    ]));
  } else if (session.phase === "pad") {
    const row = session.rows[session.index];
    heroSection.append(el("p", "sample-lede", fill(strings.padPracticeIntro, session)));
    card.append(
      el("p", "sample-handoff-progress", fill(strings.padPracticeStep, { current: session.index + 1, total: session.rows.length })),
      el("h2", "sample-pad-practice-cue", fill(strings.padPracticePlay, { pad: row.pad, name: row.data.name })),
      el("p", "sample-help", `${row.slot} / BANK ${row.bank} / PAD ${row.pad}`),
    );
    const last = session.index >= session.rows.length - 1;
    card.append(padPracticeActions([
      ...(!last ? [{ id: "btn-pad-practice-next", label: strings.padPracticeNext, primary: true, run: () => { session.index += 1; renderPadPractice(); } }] : []),
      { id: "btn-pad-practice-finish", label: strings.padPracticeFinish, primary: last, run: () => { session.phase = "decision"; renderPadPractice(); } },
    ]));
  } else if (session.phase === "decision") {
    card.append(el("h2", "sample-panel-heading", strings.padPracticeDecision));
    card.append(el("p", "sample-help", strings.padPracticeDecisionBody));
    card.append(padPracticeActions([
      { id: "btn-pad-practice-mark", label: strings.padPracticeMark, primary: true, run: markPadPracticed },
      { id: "btn-pad-practice-skip", label: strings.skipToday, run: leavePadPractice },
    ]));
  } else {
    card.append(el("h2", "sample-panel-heading", fill(strings.padPracticeRecorded, session)));
    card.append(el("p", "sample-help", fill(strings.padPracticeRecordedBody, session)));
    card.append(padPracticeActions([{ id: "btn-pad-practice-back", label: strings.backPlanner, primary: true, run: leavePadPractice }]));
  }
  shell.append(projectHeader(), heroSection, card);
  overlay.replaceChildren(shell);
  title.focus();
  publishDiagnostics();
}

function setRouteActive() {
  const active = window.location.hash === ROUTE
    || window.location.hash.startsWith(`${ROUTE}/`)
    || window.location.hash.startsWith(`${ROUTE}?`);
  document.body.classList.toggle("sample-lab-active", active);
  const app = document.getElementById("app");
  if (app) active ? app.setAttribute("aria-hidden", "true") : app.removeAttribute("aria-hidden");
  if (!overlay) return;
  overlay.hidden = !active;
  if (active) {
    document.title = `${strings.title} — SEXY ONE`;
    const intent = practiceRouteIntent();
    activePracticeIntent = intent;
    const freshIntent = intent && intent.key !== lastPracticeIntent;
    if (!intent || freshIntent) renderPlanner();
    if (freshIntent) {
      lastPracticeIntent = intent.key;
      window.setTimeout(() => applyPracticeIntent(intent), 0);
    }
    requestAnimationFrame(() => overlay.querySelector("h1")?.focus());
  } else {
    stopPreview();
    armedPlacement = null;
    activePracticeIntent = null;
    lastPracticeIntent = "";
    document.title = "SEXY ONE — SXC-1 Trainer";
  }
}

function enhanceHome() {
  const wizard = document.getElementById("sxc1-wizard-actions");
  const primary = document.getElementById("btn-primary-training");
  const browse = document.getElementById("sxc1-browse-library");
  if (!wizard || !primary || !browse) return;
  const sample = document.getElementById("btn-sample-lab");
  if (wizard.children.length !== 1 || wizard.children[0] !== primary.parentElement) {
    wizard.replaceChildren(primary.parentElement);
  }
  if (sample) sample.classList.remove("wizard-choice", "wizard-no", "wizard-next");
  browse.classList.remove("wizard-choice", "wizard-no", "wizard-next");
  browse.classList.add("home-disclosure", "sample-library-disclosure");
  const summary = browse.querySelector(":scope > summary");
  // Do not rewrite an already-correct text node: this function runs from a
  // MutationObserver, and an unconditional textContent assignment would
  // schedule itself forever on an otherwise settled Home screen.
  if (summary && summary.textContent !== strings.library) summary.textContent = strings.library;
  if (browse.previousElementSibling !== wizard) wizard.insertAdjacentElement("afterend", browse);
}

async function applyPracticeIntent(intent) {
  if (!intent || !overlay || overlay.hidden || intent.key !== lastPracticeIntent) return;
  if (intent.projectId && intent.projectId !== state.id) {
    if (!workspace.projects.some((project) => project.id === intent.projectId)) {
      if (intent.practice === "pads") beginPadPractice(intent.slot, intent.bank, true);
      return;
    }
    switchProject(intent.projectId);
  }
  if (intent.practice === "check") {
    const asset = libraryAssetById(intent.assetId);
    if (!asset) return;
    librarySelection = asset.id;
    await beginSoundCheck(asset.id);
  } else if (intent.practice === "organize") {
    const item = state.inbox[0];
    if (item) armInbox(item);
  } else if (intent.practice === "handoff") {
    const saved = savedHandoffForProject();
    if (saved?.entries?.some((entry) => ["pending", "shared"].includes(entry.status))) {
      handoffSession = saved;
      beginHandoff();
      return;
    }
    const report = await validateProject();
    if (report.blocking || report.issues.length) renderValidation(report);
    else beginHandoff();
  } else if (intent.practice === "pads") {
    beginPadPractice(intent.slot, intent.bank);
  }
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
  header.append(back);
  const padHeaderSkip = padPracticeState?.phase === "intro" && activePracticeIntent?.today;
  if (activePracticeIntent && (!padPracticeState || padHeaderSkip)) {
    const skip = el("button", "sample-button sample-button-secondary sample-practice-skip", strings.skipToday);
    skip.id = "btn-sample-practice-skip";
    skip.type = "button";
    skip.setAttribute("aria-label", `${strings.todayStep}: ${strings.skipToday}`);
    skip.addEventListener("click", () => padPracticeState ? leavePadPractice() : window.__SXC1_PRACTICE_LOOP?.skip?.());
    header.append(skip);
  } else header.append(badge);
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

function libraryAssetById(assetId) {
  return libraryState.items.find((item) => item.id === assetId) || null;
}

function readinessFile(asset, record) {
  return new File([record.blob], asset.originalName, {
    type: asset.mime || record.type || record.blob.type || "application/octet-stream",
    lastModified: Date.now(),
  });
}

function inspectReadiness(file) {
  return new Promise((resolve, reject) => {
    let worker;
    try {
      worker = new Worker(new URL("./sample-check-worker.js", import.meta.url), { type: "module" });
    } catch (error) {
      reject(error);
      return;
    }
    const id = uid("check");
    const timeout = setTimeout(() => {
      worker.terminate();
      reject(new Error("Sound Check timed out"));
    }, 90000);
    const finish = (callback) => {
      clearTimeout(timeout);
      worker.terminate();
      callback();
    };
    worker.addEventListener("message", (event) => {
      if (event.data?.id !== id) return;
      if (event.data.ok) finish(() => resolve(event.data.result));
      else finish(() => reject(new Error(event.data.error || "Sound Check failed")));
    });
    worker.addEventListener("error", (event) => finish(() => reject(new Error(event.message || "Sound Check worker failed"))), { once: true });
    worker.postMessage({ id, file });
  });
}

function makeCriterion(code, label, status, value) {
  return { code, label, status, value };
}

function readinessFromInspection(asset, inspection) {
  const header = inspection?.header || null;
  const scan = inspection?.scan || { status: "not-inspected" };
  const wav = inspection?.kind === "wav";
  const validPcm = wav && header?.audioFormat === 1;
  const known = (value) => Number.isFinite(value) && value > 0;
  const criteria = [];
  criteria.push(makeCriterion("format", strings.criterionFormat,
    validPcm ? "pass" : "fail",
    validPcm ? strings.pcmWav : (inspection?.kind === "invalid-wav" ? strings.invalidWav : strings.convertWav)));
  criteria.push(makeCriterion("rate", strings.criterionRate,
    known(header?.sampleRate) ? (header.sampleRate === 48000 ? "pass" : "fail") : "unknown",
    known(header?.sampleRate) ? `${(header.sampleRate / 1000).toFixed(1)} kHz` : strings.convertFirst));
  criteria.push(makeCriterion("depth", strings.criterionDepth,
    known(header?.bitDepth) ? (header.bitDepth === 16 ? "pass" : "fail") : "unknown",
    known(header?.bitDepth) ? `${header.bitDepth}-bit` : strings.convertFirst));
  criteria.push(makeCriterion("channels", strings.criterionChannels,
    known(header?.channels) ? (header.channels === 2 ? "pass" : "fail") : "unknown",
    known(header?.channels) ? (header.channels === 2 ? strings.stereo : `${header.channels} ch`) : strings.convertFirst));
  criteria.push(makeCriterion("duration", strings.criterionDuration,
    known(header?.duration) ? (header.duration <= SXC1_MAX_SAMPLE_SECONDS ? "pass" : "fail") : "unknown",
    known(header?.duration) ? `${formatDuration(header.duration)} · ${strings.deviceLimit}` : strings.convertFirst));
  criteria.push(makeCriterion("size", strings.criterionSize,
    asset.bytes <= SXC1_MAX_SAMPLE_BYTES ? "pass" : "fail",
    `${formatBytes(asset.bytes)} · ${strings.sizeLimit}`));

  if (scan.status === "scanned") {
    criteria.push(makeCriterion("clipping", strings.criterionClipping,
      scan.clippedFrames > 0 ? "advisory" : "pass",
      scan.clippedFrames > 0 ? fill(strings.clippingFound, { count: scan.clippedFrames }) : strings.noClipping));
    const edgeFinding = scan.silent || scan.leadingSilence >= 0.05 || scan.trailingSilence >= 0.1;
    criteria.push(makeCriterion("silence", strings.criterionSilence,
      edgeFinding ? "advisory" : "pass",
      scan.silent ? strings.allSilence : edgeFinding
        ? fill(strings.edgeSilence, { leading: scan.leadingSilence.toFixed(2), trailing: scan.trailingSilence.toFixed(2) })
        : strings.noEdgeSilence));
  } else {
    const reason = scan.status === "too-large" ? strings.scanTooLarge
      : scan.status === "unsupported-pcm" ? strings.scanUnsupported : strings.convertFirst;
    criteria.push(makeCriterion("clipping", strings.criterionClipping, "unknown", reason));
    criteria.push(makeCriterion("silence", strings.criterionSilence, "unknown", reason));
  }

  const required = criteria.filter((item) => !["clipping", "silence"].includes(item.code));
  const ready = required.every((item) => item.status === "pass");
  const findings = criteria.filter((item) => item.status === "fail" || item.status === "advisory").map((item) => item.code);
  return {
    ready,
    criteria,
    findings,
    advisory: criteria.filter((item) => item.status === "advisory").length,
    inspection,
  };
}

function audacityRecipe(result) {
  if (!result) return [];
  const statuses = new Map(result.criteria.map((item) => [item.code, item.status]));
  const steps = [];
  const needsFormatExport = ["format", "rate", "depth", "channels"].some((code) => statuses.get(code) !== "pass");
  const needsTrim = ["duration", "size"].some((code) => statuses.get(code) === "fail");
  const needsAudioEdit = needsTrim || statuses.get("clipping") === "advisory" || statuses.get("silence") === "advisory";
  if (needsFormatExport || needsAudioEdit) {
    steps.push(strings.recipeOpen);
  }
  if (statuses.get("clipping") === "advisory") steps.push(strings.recipeClipping);
  if (needsTrim) steps.push(strings.recipeTrim);
  else if (statuses.get("silence") === "advisory") steps.push(strings.recipeSilence);
  // Every Audacity edit still needs a new file; omitting the final export would
  // leave the learner with a corrected project but no corrected handoff asset.
  if (needsFormatExport || needsAudioEdit) steps.push(strings.recipeExport);
  return steps;
}

function persistedReadiness(result) {
  return normalizeReadiness({
    checkedAt: new Date().toISOString(),
    ready: result.ready,
    advisory: result.advisory,
    findings: result.findings,
  });
}

async function checkLibraryAsset(asset) {
  const record = await getAudio(asset.blobId);
  if (!record?.blob) throw new Error("Missing audio");
  const inspection = await inspectReadiness(readinessFile(asset, record));
  const result = readinessFromInspection(asset, inspection);
  asset.readiness = persistedReadiness(result);
  if (result.ready) asset.stage = "ready";
  else if (asset.stage === "ready") asset.stage = "edited";
  persistProject();
  return result;
}

async function beginSoundCheck(assetId) {
  const asset = libraryAssetById(assetId);
  if (!asset) return;
  stopPreview();
  const session = { phase: "checking", assetId: asset.id, candidateId: "", result: null, candidateResult: null, message: "" };
  soundCheckState = session;
  renderSoundCheck();
  try {
    const result = await checkLibraryAsset(asset);
    if (soundCheckState !== session) return;
    session.result = result;
    session.phase = "result";
  } catch (_) {
    if (soundCheckState !== session) return;
    session.phase = "error";
    session.message = strings.checkFailed;
  }
  if (soundCheckState === session) renderSoundCheck();
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (_) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    area.remove();
    return copied;
  }
}

function recipeText(asset, result) {
  const steps = audacityRecipe(result);
  return [`${strings.recipeTitle}: ${asset.name}`, ...steps.map((step, index) => `${index + 1}. ${step}`)].join("\n");
}

async function importEditedVersion(file) {
  const session = soundCheckState;
  const original = libraryAssetById(session?.assetId);
  if (!session || !original) return;
  const extension = extOf(file.name);
  if (!SUPPORTED_EXTENSIONS.has(extension) || file.size > MAX_AUDIO_BYTES) {
    session.message = file.size > MAX_AUDIO_BYTES ? strings.tooLarge : strings.invalidFile;
    renderSoundCheck();
    return;
  }
  session.phase = "checking-edited";
  session.message = "";
  renderSoundCheck();
  let imported = null;
  let previousCandidateState = null;
  const rollbackImport = async () => {
    if (!imported?.asset) return;
    if (imported.reused && previousCandidateState) {
      imported.asset.replacesId = previousCandidateState.replacesId;
      imported.asset.readiness = previousCandidateState.readiness;
      imported.asset.stage = previousCandidateState.stage;
    }
    if (!imported.reused) {
      libraryState.items = libraryState.items.filter((item) => item.id !== imported.asset.id);
      await deleteAudio(imported.asset.blobId);
    }
    persistProject();
  };
  try {
    imported = await libraryAssetFromFile(file);
    if (soundCheckState !== session) {
      await rollbackImport();
      return;
    }
    const candidate = imported.asset;
    if (candidate.id === original.id) {
      session.phase = "copied";
      session.message = strings.sameVersion;
      renderSoundCheck();
      return;
    }
    if (imported.reused && candidate.replacesId && candidate.replacesId !== original.id) {
      session.phase = "copied";
      session.message = strings.linkedVersion;
      renderSoundCheck();
      return;
    }
    previousCandidateState = {
      replacesId: candidate.replacesId,
      readiness: candidate.readiness,
      stage: candidate.stage,
    };
    // A genuinely new export inherits the preparation context. If dedup finds
    // an existing Library sound, preserve that sound's established metadata.
    if (!imported.reused) {
      ["name", "source", "tags", "color", "playMode", "bpm", "group", "notes", "rights"].forEach((key) => {
        candidate[key] = original[key];
      });
    }
    candidate.replacesId = original.id;
    const candidateResult = await checkLibraryAsset(candidate);
    if (soundCheckState !== session) {
      await rollbackImport();
      return;
    }
    session.candidateId = candidate.id;
    session.candidateResult = candidateResult;
    session.phase = "candidate";
    session.message = strings.versionImported;
    persistProject();
  } catch (_) {
    await rollbackImport();
    if (soundCheckState !== session) return;
    session.phase = "copied";
    session.message = strings.checkFailed;
  }
  if (soundCheckState === session) renderSoundCheck();
}

function replaceAssetEverywhere(original, candidate) {
  let placements = 0;
  const changedProjects = [];
  workspace.projects.forEach((project) => {
    let changed = false;
    SLOT_NAMES.forEach((slot) => {
      Object.entries(project.slots[slot].pads).forEach(([number, pad]) => {
        if (pad.blobId !== original.blobId) return;
        project.slots[slot].pads[number] = padFromLibraryAsset(candidate, pad);
        placements += 1;
        changed = true;
      });
    });
    project.inbox = project.inbox.map((item) => {
      if (item.blobId !== original.blobId) return item;
      placements += 1;
      changed = true;
      return { ...padFromLibraryAsset(candidate, item), id: item.id };
    });
    if (changed) {
      project.updatedAt = new Date().toISOString();
      changedProjects.push(project);
      if (savedHandoffForProject(project.id)) syncHandoffSessionForProject(project, assignedPadsForProject(project), false);
    }
  });
  if (changedProjects.some((project) => savedHandoffForProject(project.id))) persistHandoffs();
  persistProject();
  return { placements, projects: changedProjects.length };
}

function useEditedVersion() {
  const original = libraryAssetById(soundCheckState?.assetId);
  const candidate = libraryAssetById(soundCheckState?.candidateId);
  if (!original || !candidate) return;
  const changed = replaceAssetEverywhere(original, candidate);
  if (candidate.readiness?.ready) recordPractice("sound-ready", { ref: original.id });
  librarySelection = candidate.id;
  libraryEditing = false;
  soundCheckState = null;
  renderPlanner();
  announce(fill(strings.versionUsed, changed));
}

function finishSoundCheck() {
  const assetId = soundCheckState?.assetId || "";
  if (soundCheckState?.result?.ready) recordPractice("sound-ready", { ref: assetId });
  closeSoundCheck();
}

function keepCurrentVersion() {
  const originalId = soundCheckState?.assetId;
  soundCheckState = null;
  librarySelection = originalId || null;
  libraryEditing = false;
  renderPlanner();
  announce(strings.versionKept);
}

function closeSoundCheck() {
  soundCheckState = null;
  libraryEditing = false;
  renderPlanner();
  requestAnimationFrame(() => overlay.querySelector("#btn-sample-library-edit")?.focus());
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
  if (asset && libraryState.items.some((item) => item.replacesId === asset.id)) {
    announce(strings.protectsVersion, "warning");
    return;
  }
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
  if (asset.replacesId) {
    const previous = libraryAssetById(asset.replacesId);
    if (previous) editor.append(el("p", "sample-version-note", fill(strings.previousVersion, { name: previous.name })));
  }

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
  const check = el("button", "sample-button sample-button-secondary", strings.checkReadiness);
  check.id = "btn-sample-sound-check";
  check.type = "button";
  check.addEventListener("click", () => {
    persistProject();
    beginSoundCheck(asset.id);
  });
  actions.append(done, check);
  const options = el("details", "sample-library-options");
  options.append(el("summary", "", strings.libraryOptions));
  const remove = el("button", "sample-button sample-button-danger", strings.removeLibrary);
  remove.id = "btn-sample-library-remove";
  remove.type = "button";
  remove.addEventListener("click", removeSelectedLibrary);
  options.append(remove);
  editor.append(actions, options);
  section.append(editor);
}

function criterionStatusLabel(status) {
  if (status === "pass") return strings.criterionPass;
  if (status === "fail") return strings.criterionFix;
  if (status === "advisory") return strings.criterionReview;
  return strings.criterionUnknown;
}

function readinessResultView(result, titleText) {
  const fragment = document.createDocumentFragment();
  const heading = el("h2", "sample-sound-check-summary", titleText || (result.ready ? strings.readyTitle : strings.needsWorkTitle));
  fragment.append(heading, el("p", "sample-sound-check-body", result.ready ? strings.readyBody : strings.needsWorkBody));
  const list = el("ul", "sample-sound-check-list");
  result.criteria.forEach((criterion) => {
    const item = el("li", `is-${criterion.status}`);
    item.dataset.criterion = criterion.code;
    item.dataset.status = criterion.status;
    item.append(
      el("strong", "sample-sound-check-criterion", criterion.label),
      el("span", "sample-sound-check-value", criterion.value),
      el("span", "sample-sound-check-status", criterionStatusLabel(criterion.status)),
    );
    list.append(item);
  });
  fragment.append(list);
  const recipe = audacityRecipe(result);
  if (recipe.length) {
    const recipeSection = el("section", "sample-recipe");
    recipeSection.append(el("h3", "", strings.recipeTitle), el("p", "", strings.recipeIntro));
    const steps = el("ol", "");
    recipe.forEach((step) => steps.append(el("li", "", step)));
    const learn = el("a", "sample-learn-link", strings.learnWhy);
    learn.href = "#/x/lvl-16";
    recipeSection.append(steps, learn);
    fragment.append(recipeSection);
  }
  return fragment;
}

function editedVersionInput() {
  const input = document.createElement("input");
  input.id = "sample-edited-version-input";
  input.type = "file";
  input.accept = ".wav,.mp3,.flac,audio/wav,audio/mpeg,audio/flac";
  input.hidden = true;
  input.addEventListener("change", async () => {
    const file = input.files?.[0];
    input.value = "";
    if (file) await importEditedVersion(file);
  });
  return input;
}

function renderSoundCheck() {
  if (!soundCheckState) { renderPlanner(); return; }
  const original = libraryAssetById(soundCheckState.assetId);
  if (!original) { soundCheckState = null; renderPlanner(); return; }
  overlay.dataset.view = "sound-check";
  const shell = el("div", "sample-lab-shell sample-sound-check-shell");
  const heroSection = el("section", "sample-hero sample-sound-check-hero");
  heroSection.append(el("p", "sample-eyebrow", strings.soundCheckEyebrow));
  const title = el("h1", "", strings.soundCheckTitle);
  title.tabIndex = -1;
  const back = el("a", "sample-handoff-back", `← ${strings.sampleLibrary}`);
  back.href = ROUTE;
  back.addEventListener("click", (event) => {
    event.preventDefault();
    if (soundCheckState?.phase === "candidate") keepCurrentVersion();
    else closeSoundCheck();
  });
  heroSection.append(title, el("p", "sample-lede", strings.soundCheckIntro), back);

  const card = el("section", "sample-sound-check-card");
  const identity = el("div", "sample-sound-check-identity");
  identity.append(el("strong", "", original.name), el("span", "", `${original.originalName} · ${formatBytes(original.bytes)}`));
  card.append(identity);

  const phase = soundCheckState.phase;
  if (phase === "checking" || phase === "checking-edited") {
    card.setAttribute("aria-busy", "true");
    card.append(el("p", "sample-sound-check-working", phase === "checking-edited" ? strings.checkingEdited : strings.checkWorking));
  } else if (phase === "candidate" && soundCheckState.candidateResult) {
    const candidate = libraryAssetById(soundCheckState.candidateId);
    card.append(readinessResultView(soundCheckState.candidateResult, strings.editedVersion));
    if (candidate) card.append(el("p", "sample-version-note", `${candidate.originalName} · ${formatBytes(candidate.bytes)}`));
    card.append(el("p", "sample-sound-check-body", strings.editedVersionIntro));
  } else if (soundCheckState.result) {
    card.append(readinessResultView(soundCheckState.result));
  } else {
    card.append(el("h2", "sample-sound-check-summary", strings.checkFailed));
  }

  const status = el("p", "sample-status", soundCheckState.message || "");
  status.id = "sample-lab-status";
  status.setAttribute("aria-live", "polite");
  card.append(status);

  const actions = el("div", "sample-primary-actions");
  if (phase === "error") {
    const retry = el("button", "sample-button sample-button-primary", strings.checkAgain);
    retry.id = "btn-sample-check-retry";
    retry.type = "button";
    retry.addEventListener("click", () => beginSoundCheck(original.id));
    const done = el("button", "sample-button sample-button-secondary", strings.checkDone);
    done.id = "btn-sample-check-done";
    done.type = "button";
    done.addEventListener("click", finishSoundCheck);
    actions.append(retry, done);
  } else if (phase === "candidate") {
    const use = el("button", "sample-button sample-button-primary", strings.useVersion);
    use.id = "btn-sample-version-use";
    use.type = "button";
    use.addEventListener("click", useEditedVersion);
    const keep = el("button", "sample-button sample-button-secondary", strings.keepCurrent);
    keep.id = "btn-sample-version-keep";
    keep.type = "button";
    keep.addEventListener("click", keepCurrentVersion);
    actions.append(use, keep);
  } else if (phase === "result" || phase === "copied") {
    const input = editedVersionInput();
    card.append(input);
    const recipe = audacityRecipe(soundCheckState.result);
    if (phase === "result" && recipe.length) {
      const copy = el("button", "sample-button sample-button-primary", strings.copyRecipe);
      copy.id = "btn-sample-recipe-copy";
      copy.type = "button";
      copy.addEventListener("click", async () => {
        const session = soundCheckState;
        if (!session?.result) return;
        const copied = await copyText(recipeText(original, session.result));
        if (soundCheckState !== session) return;
        if (copied) {
          session.phase = "copied";
          session.message = strings.recipeCopied;
        } else {
          session.message = strings.recipeCopyFailed;
        }
        renderSoundCheck();
      });
      actions.append(copy);
    } else if (phase === "copied") {
      const importButton = el("button", "sample-button sample-button-primary", strings.importEdited);
      importButton.id = "btn-sample-version-import";
      importButton.type = "button";
      importButton.addEventListener("click", () => input.click());
      actions.append(importButton);
    }
    const done = el("button", "sample-button sample-button-secondary", strings.checkDone);
    done.id = "btn-sample-check-done";
    done.type = "button";
    done.addEventListener("click", finishSoundCheck);
    actions.append(done);
  }
  if (actions.childElementCount) card.append(actions);
  shell.append(projectHeader(), heroSection, card);
  overlay.replaceChildren(shell);
  title.focus();
  publishDiagnostics();
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
  if (bankPracticeRows().length) {
    const actions = el("div", "sample-action-row sample-bank-practice-actions");
    const practice = el("button", "sample-button sample-button-secondary", strings.practiceBank);
    practice.id = "btn-sample-practice-bank";
    practice.type = "button";
    practice.addEventListener("click", () => {
      const slot = state.activeSlot;
      const bank = activeBank().bank;
      history.replaceState(null, "", `${ROUTE}?practice=pads&project=${encodeURIComponent(state.id)}&slot=${slot}&bank=${bank}`);
      activePracticeIntent = practiceRouteIntent();
      lastPracticeIntent = activePracticeIntent?.key || "";
      beginPadPractice(slot, bank);
    });
    actions.append(practice);
    section.append(actions);
  }
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
  recordPractice("sample-placed", { ref: `autofill:${count}` });
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
    recordPractice("sample-placed", { ref: pad.blobId });
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
    handoffStorage: handoffPersisted ? "localStorage" : "temporary",
    projectId: state?.id || null,
    projectName: state?.name || null,
    projects: workspace ? workspace.projects.map((project) => ({ id: project.id, name: project.name, inbox: project.inbox.length, assigned: assignedPadCount(project) })) : [],
    libraryItems: libraryState ? libraryState.items.map((item) => ({
      id: item.id,
      blobId: item.blobId,
      name: item.name,
      filename: item.originalName,
      stage: item.stage,
      fingerprint: item.fingerprint,
      replacesId: item.replacesId,
      readiness: item.readiness,
    })) : [],
    librarySelection,
    activeSlot: state?.activeSlot || null,
    selectedPad: state?.selectedPad || null,
    inboxItems: state ? state.inbox.map((item) => ({ id: item.id, name: item.name, filename: item.originalName, bytes: item.bytes })) : [],
    placement: armedPlacement ? { ...armedPlacement } : null,
    assignedPads: state ? allAssignedPads().map((row) => ({ slot: row.slot, bank: row.bank, pad: row.pad, blobId: row.data.blobId, name: row.data.name, filename: row.data.originalName })) : [],
    soundCheck: soundCheckState ? {
      phase: soundCheckState.phase,
      assetId: soundCheckState.assetId,
      candidateId: soundCheckState.candidateId,
      ready: soundCheckState.result?.ready ?? null,
      candidateReady: soundCheckState.candidateResult?.ready ?? null,
      criteria: (soundCheckState.candidateResult || soundCheckState.result)?.criteria?.map((item) => ({ code: item.code, status: item.status, value: item.value })) || [],
    } : null,
    padPractice: padPracticeState ? {
      phase: padPracticeState.phase,
      slot: padPracticeState.slot,
      bank: padPracticeState.bank,
      padCount: padPracticeState.rows.length,
      index: padPracticeState.index,
      recorded: padPracticeState.recorded,
      loaded: padPracticeState.rows.length ? bankLastLoaded(padPracticeState.rows) : false,
    } : null,
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
        blobId: entry.blobId,
        name: entry.name,
        filename: entry.originalName,
        status: entry.status,
      })),
    } : null,
    exportProjectBlob,
    importProjectFile,
    validateProject,
    beginHandoff,
    beginSoundCheck,
    beginPadPractice,
    inspectReadiness,
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
    if (["validation", "handoff", "receipt", "sound-check"].includes(overlay.dataset.view)) {
      event.preventDefault();
      if (overlay.dataset.view === "sound-check") closeSoundCheck();
      else {
        renderPlanner();
        requestAnimationFrame(() => overlay.querySelector("#btn-sample-handoff")?.focus());
      }
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

# M4 plan — WebMIDI live-device verification

**From:** Opus 5 design agent · **Date:** 2026-08-07
**Brief:** `briefs/M4-webmidi.md` · **Companion:** `briefs/M4-manifest.json` (7 tasks / 5 waves)
**Designed against:** the committed tree at tag `m2`.
**Implements against:** the *merged M3 tree*. M4 implementation is sequenced after
the M3 gate — both milestones touch `site/app/Main.hs`, and M3's size reduction
sets M4's budget. Wave 0 exists to re-baseline before a single line is written.

Everything below marked **MEASURED** was executed today against the real
toolchain (`~/.ghc-wasm`, GHC 9.14.1.20260731, miso 1.12.0.0) and real headless
Chrome. Probe sources live in the scratchpad
(`m4/{base,ffi,real,rawffi}/Main.hs`, `m4/fake-midi.js`, `m4/drive*.mjs`).

---

## 0. Summary of the decision

**Route: Miso JS DSL only. No `index.js` bridge. No raw `foreign import javascript`.**

The whole Web MIDI surface M4 needs — promise resolution, `MIDIInputMap`
enumeration, `onmidimessage` subscription, `MIDIMessageEvent.data` byte reads,
unsubscription, `onstatechange` hot-plug, and dispatching a Miso action from
inside a JS callback — was compiled, linked and **executed in a browser** through
`jsg` / `(!)` / `(#)` / `setProp` / `asyncCallback1` / `(!!)` / `freeFunction`,
with nothing added to `site/static/index.js` and nothing added to
`site/cabal.project`. `site/static/index.js` stays exactly as it is.

---

## 1. FFI probe — measured results

Four wasm binaries were built and three of them run in headless Chrome.

### P-A — the DSL can do all of it (verdict: **YES**)

`scratchpad/m4/ffi/Main.hs`, ~150 lines, `import Miso` only (Miso re-exports
`module Miso.DSL`, so `asyncCallback1`, `setProp`, `(#)`, `(!!)`, `freeFunction`,
`Function`, `Object`, `jsNull`, `isUndefined`, `createWith` are all already in
scope for `site/app/Main.hs` today).

| Probe | What it proves | Result |
|---|---|---|
| P0 | `navigator.requestMIDIAccess` feature-detect via `(!)` + `isUndefined`/`isNull` | ✅ `True`/`False` correctly |
| P1 | `nav # "requestMIDIAccess" $ opts` → **promise resolved** via `p # "then" $ [Function ok, Function err]` with `asyncCallback1` | ✅ both arms fire |
| P2 | `MIDIInputMap` → `Array.from(inputs.values())`, then `arr ! "length"` and `arr !! i`; `id`/`name`/`manufacturer`/`state` read as `MisoString` | ✅ `3` ports enumerated with full metadata |
| P3 | `setProp "onmidimessage" (Function cb) (Object port)` | ✅ handler installed |
| P4 | `ev ! "data"` → `d ! "length"`, `d !! k` → `Int` | ✅ `[176,80,127]` and `[144,36,127]` read byte-exact |
| P5 | `setProp "onmidimessage" jsNull port` + `freeFunction` | ✅ `subscribedCount()` 1 → 0; a later emit reaches nobody |
| P6 | `setProp "onstatechange" cb (Object access)` (hot-plug) | ✅ fires with the new port |
| P7 | Miso `Sink` dispatch from inside the JS callback re-renders the DOM | ✅ `#probe-out` updates from the `onmidimessage` handler |

One compile-time gotcha for the implementers: `Miso.DSL.(!!)` collides with
`Prelude.(!!)`. `View/Pages.hs` already handles this by `import Miso hiding ((!!))`;
a module that wants the JS indexer must instead write `import Prelude hiding ((!!))`
alongside `import Miso.DSL ((!!))`. **MEASURED** (GHC-87543, fixed, rebuilt clean).

### P-B — the injectable fake works through CDP (verdict: **YES**)

`Page.addScriptToEvaluateOnNewDocument` on a **freshly created** target (created at
`about:blank`, attached, `Page.enable`, script added, *then* `Page.navigate`)
installs the fake before the app's document exists. **MEASURED**: in every
scenario the app's own `requestMIDIAccess` call was recorded by the fake
(`calls == [{sysex:false}]`) and `typeof window.__SXC1_FAKE_MIDI === "object"`
at boot. `browser-check.mjs` already creates fresh targets this way for the NEW5
cold-deep-link assertion — the pattern transfers verbatim.

### P-C — real headless Chrome denies Web MIDI (verdict: a free anti-vacuity control)

**MEASURED**, no fake injected: `typeof navigator.requestMIDIAccess === "function"`,
but the promise **rejects** — the probe landed in `status:"denied"` with zero ports.

Two consequences, both exploited by the design:

1. Feature detection alone is never sufficient; the denied path is a first-class
   UI state, not an edge case.
2. It gives CI a **no-fake negative control**: the same enable flow, in a target
   with no injected script, must reach `denied` and must never confirm. If the
   fake ever stops being injected, the positive assertions cannot pass by accident.

### P-D — M1's P4 finding is scope-limited (recorded, not acted on)

M1's `site/app/Main.hs` Haddock states that a raw `foreign import javascript`
returning `GHC.Wasm.Prim.JSString` "does not link on this toolchain". **MEASURED
today: it does.** `scratchpad/m4/rawffi/Main.hs` declares five raw imports —
`Int -> Int`, `IO Bool`, `JSVal -> IO Int`, `IO JSString`, and a
`foreign import javascript "wrapper"` — and it **compiles, links, and runs**:

```
{ "raw": true, "hash": "#raw", "cb": "function", "dataLen": 3 }
```

The actual blocker is mundane: `GHC.Wasm.Prim` lives in `ghc-experimental`, which
is not in `exe:app`'s `build-depends`. Without it the module does not compile at
all (GHC-87110); with it, everything links. Miso's own `ffi/wasm/Miso/DSL/FFI.hs`
has used exactly these declarations all along.

**This does not change M4's route.** The DSL is proven end to end, needs no new
dependency, no `cabal.project` change (M2's P-G — `site/cabal.project` untouched —
still holds), and its measured cost is affordable. Raw JSFFI is recorded here as a
*documented escape hatch* for a future size crunch, and M1's Haddock claim should
be corrected to name the real cause. That correction is **not** an M4 task
(Main.hs's comment block is rewritten by `device-app` anyway; the corrected text is
specified in that task's prompt).

### P-E — size, measured against an identical-scaffolding baseline

Four binaries, same cabal file, same flags, `-O1`, no `--optimize`:

| Binary | raw | gzip | Δ vs base |
|---|---:|---:|---:|
| `base` — Miso app, IORef log, 2 buttons, `window.__PROBE` mirror, **no MIDI** | 2 873 184 | **648 651** | — |
| `ffi` — base + the P0…P7 probe | 2 967 023 | **662 062** | +13 411 |
| `real` — base + the **full M4 runtime shape** (§3) | 3 057 160 | **678 467** | **+29 816** |
| `rawffi` — raw-JSFFI probe (not comparable; different app) | 1 728 232 | 490 815 | — |

`real` contains: hub state, feature detect, enable (no sysex), port selection with
liberal name matching, per-port fan-out, `decodeMidi`, `matchSpec`, the pad→note
table, the watcher registry, unsubscribe, hot-plug rebind, and the device-state
JSON encoder. **+29 816 gzip is the runtime upper bound** — the real app already
links `Data.Text`, `Data.List` and `Data.Char`, so the in-app delta will be lower.

### P-F — the design works, and its negative controls are red for the right reason

`scratchpad/m4/real` was driven through 10 scenarios by
`scratchpad/m4/drive-real.mjs`. The app registers one watch
(`VerifyCC 80 [127]`, channel 1) on Enable; `watches: 1 → 0` is a confirm.
**MEASURED, all ten as designed:**

```
pos: CC80=127 ch1              confirmed=True  delivered=[1] lastMsg=[176,80,127] lastCh=1
neg: wrong CC (81)             confirmed=False delivered=[1] lastMsg=[176,81,127] lastCh=1
neg: wrong value (0)           confirmed=False delivered=[1] lastMsg=[176,80,0]   lastCh=1
neg: wrong channel (2)         confirmed=False delivered=[1] lastMsg=[177,80,127] lastCh=2
neg: note not CC               confirmed=False delivered=[1] lastMsg=[144,36,127] lastCh=1
neg: system message 0xF0       confirmed=False delivered=[1] lastMsg=None
neg: other device's port       confirmed=False delivered=[0]  (port never bound)
pos: right device among two    confirmed=True  delivered=[1] ports=['CASIO SXC-1 MIDI 1']
pos: unrecognised single port  confirmed=True  delivered=[1] ports=['USB MIDI Device']
pos: second message is inert   confirmed=True  delivered=[1,1] watchesAfter=0
```

Every negative control is falsifiable in the right way: the message was
**delivered to a live, subscribed port** (`delivered=1`, `subscribed=1`) and
**reached Haskell** (`lastMsg` shows the exact bytes) and was still refused. A
control that passed because nothing was listening would show `delivered=0` or
`subscribed=0` and is therefore distinguishable.

One correction the probe forced, now part of the spec (§3.4): `lastMessage` must be
recorded **before** decoding, not inside the `Just` branch — otherwise a system
message (`0xF0…`) leaves no evidence it was received, and the "sysex is ignored"
control becomes indistinguishable from "sysex never arrived".

---

## 2. What M4 changes, and what it does not

**Does not change.** The content format; any `.ex.md` file; `SXC1.Exercise.{Types,
Parse,Lint,Verify,Report,Engine}`; `ProgressEvent`; `ConfirmSource`; the
`VerifySpec` grammar; `site/cabal.project`; `site/static/index.js`;
`WASM_GZIP_CEILING_BYTES`; any existing check's meaning.

**Changes.** `noDeviceVerifier` → `webMidiVerifier hub` in `Main.hs` (the one-value
swap the M2 plan promised), plus the additive plumbing that swap implies: a hub,
a watch-reconciler, a device panel, one new hidden DOM blob, one new pure library
module, one CI-only module, a harness fake, and the checks that hold it all down.

**The M2 contract, implemented verbatim:**

```haskell
data DeviceVerifier = DeviceVerifier
  { dvAvailable :: IO Bool
  , dvWatch     :: VerifySpec -> (ConfirmSource -> IO ()) -> IO (IO ()) }
```

---

## 3. Design

### 3.1 Module split — everything decidable is pure and unit-tested

| Module | Where | Linked into `app.wasm` | Tested by |
|---|---|---|---|
| `SXC1.Midi.Spec` | `site/src/SXC1/Midi/Spec.hs` (lib) | yes | `exe:exercise-check --self-test` (no browser) |
| `SXC1.Midi.Table` | `site/src/SXC1/Midi/Table.hs` (lib) | **no** (CI only) | itself + the agreement proof |
| `Device.Midi` | `site/app/Device/Midi.hs` (exe:app) | yes | browser-check via the fake |

`SXC1.Midi.Spec` is pure and total:

```haskell
data MidiMsg = MsgCC !Int !Int !Int | MsgNote !Int !Int !Int | MsgOther !Int
decodeMidi   :: [Int] -> Maybe MidiMsg          -- Nothing for 0xF0..0xFF
padNoteTable :: [Int]                            -- 64 entries, bank-major A,B,C,D
padNote      :: Int -> Char -> Maybe Int
matchSpec    :: Int -> VerifySpec -> MidiMsg -> Bool   -- Int = expected channel
selectPorts  :: [(Text, Text)] -> [Int]          -- (name, manufacturer) -> indices
describeSpec :: VerifySpec -> Text
```

Nothing here touches IO, so `exercise-check` can prove all of it under `wasm-run`.
`Device.Midi` holds only the JS glue: it never decides anything.

### 3.2 The pad→note table, grounded in `translations/midi.md`

`padNoteTable` is a **literal** 64-entry table, deliberately *not* a formula.
The arithmetic (`A = 35+p`, `B = 51+p`, `C = 67+p`, `D = 83+p`) is wrong for
exactly one cell: `midi.md` §5 prints **Pad 2 / Bank C = 68**, duplicating Pad 1,
where the sequence implies 69. `translations/midi.qa-notes.md` confirms this
against the page image and reproduces it deliberately. A formula plus one guard
would hide the erratum inside a special case; a literal table shows it.

`SXC1.Midi.Table` parses `translations/midi.md`'s "5. Note mapping" table with M1's
own block parser (the same route `SXC1.Exercise.Verify.buildMidiFacts` takes) into
`Map (Int, Char) Int`, and `exercise-check --self-test` asserts, cell by cell:

* the parsed table has exactly **64** `(pad, bank)` entries for banks A–D;
* `padNote p b == Map.lookup (p,b) parsed` for every `p ∈ 1..16`, `b ∈ "ABCD"`;
* `padNote 2 'C' == Just 68` **and** `padNote 1 'C' == Just 68` — the erratum is
  pinned by name, so correcting `midi.md` upstream turns CI red and forces a
  human decision rather than silently changing what a drill verifies;
* `padNote` is `Nothing` outside `1..16` / `ABCD`.

Consequence to state plainly: note 68 is ambiguous in reverse (`pad 1 bank C` and
`pad 2 bank C` both map to it), so a `verify: pad 1 bank C` hook would also be
satisfied by tapping pad 2 in bank C. Mapping is forward-only and no seed content
uses bank C, so this is documented, not fixed.

### 3.3 Decoding

```
status 0x80..0xEF  → channel = (status .&. 0x0F) + 1, kind = status .&. 0xF0
  0xB0 + 2 bytes → MsgCC   chan cc value
  0x90 + 2 bytes → MsgNote chan note velocity
  anything else  → MsgOther chan
status 0xF0..0xFF  → Nothing        (system/sysex: never a verification)
```

Web MIDI delivers complete messages, so running status cannot occur.

**Note-off / velocity 0.** `midi.md` §3 records Velocity as `×` for both Note ON
and Note OFF, so the SXC-1's velocity byte is not meaningful. Convention says
Note On with velocity 0 *is* a Note Off — but if the SXC-1 transmits velocity 0
for every pad hit, honouring that convention would make every `pad`/`note` hook
permanently dead. **Decision: `0x90` matches regardless of velocity; `0x80` never
matches a `note`/`pad` hook.** This is the single assumption in M4 that only the
owner's physical device can settle, so `docs/M4-device-test-protocol.md` §5
requires the owner to record the raw bytes of one pad press. Whatever they report
becomes the pinned test vector.

### 3.4 The hub

One `IORef HubState` created in `main`, threaded into `updateModel` and the view.

```haskell
data HubState = HubState
  { hsStatus    :: !DeviceStatus          -- Off | Pending | Granted | Denied | Unsupported
  , hsPorts     :: [Port]                 -- bound (name, MIDIInput object, its Function)
  , hsAllPorts  :: [Text]                 -- every input port's name, bound or not
  , hsChannel   :: !Int                   -- expected MIDI channel, 1..16, default 1
  , hsLastMsg   :: Maybe [Int]            -- raw bytes, recorded BEFORE decode (P-F)
  , hsLastChan  :: Maybe Int              -- Nothing for system messages
  , hsWatches   :: [Watch]                -- (id, spec, callback)
  , hsNextId    :: !Int
  , hsAccess    :: Maybe JSVal
  , hsStateCb   :: Maybe Function }
```

* **`dvAvailable`** = feature detection only. Never calls `requestMIDIAccess`,
  so it is safe to call at boot (and is, exactly as M2's `main` already does).
* **`dvWatch spec cb`** = pure registry insert, returns an idempotent remover
  keyed on a unique id. **No JS is touched by a watch.** There is exactly one
  `onmidimessage` `Function` per bound port, never one per watch — this is what
  keeps `freeFunction` accounting trivially correct.
* **Watching before enabling is legal** and simply never fires. That is what lets
  `dvWatch` be synchronous and total against an asynchronous permission model.

**Dispatch — snapshot, remove, then fire.**

```
onmidimessage → bytes → hsLastMsg := bytes            (unconditionally)
              → decodeMidi
              → hsLastChan := channel                  (Nothing for system msgs)
              → hit = [w | w <- snapshot, matchSpec hsChannel (wSpec w) msg]
              → hsWatches := hsWatches \\ hit          (BEFORE any callback runs)
              → mapM_ (\w -> wFire w ByDevice) hit
```

Removing before firing is load-bearing: `wFire` dispatches a Miso action that
advances the drill, which re-runs reconciliation and registers the *next* step's
watch. Removing after firing would delete it.

**Unsubscribe semantics (the contract `dvWatch`'s `IO (IO ())` promises):**

1. **Idempotent** — filtering by unique id, so calling it twice, calling it after
   the watch already fired, or calling it after `disable` are all no-ops.
2. **One-shot** — a matched watch is removed by the hub itself. A drill step
   confirms once; the SXC-1's buttons transmit `127` on press *and* `0` on
   release, and pressing again re-sends `127`, so without this a `cc 80 127` hook
   would fire repeatedly. **MEASURED** (P-F, "second message is inert").
3. **Order-independent** — the caller's remover and the hub's auto-removal
   compose in either order.
4. **Port-agnostic** — hot-plug rebinds JS handlers; watches are untouched.
5. **`disable`** clears every port handler, clears `onstatechange`, `freeFunction`s
   all of them, and resets everything except `hsChannel`.

### 3.5 Port selection — liberal, with a sane fallback

`access.inputs` → `Array.from(inputs.values())` → for each port read
`id`, `name`, `manufacturer`, `state`. Then:

```
sxc   = ports whose name or manufacturer contains "sxc-1" | "sxc1" | "sxc 1"  (case-folded)
casio = ports whose name or manufacturer contains "casio"
bind  = if sxc ≠ [] then sxc else if casio ≠ [] then casio else ALL ports
```

The rationale for the fallback is that the device is post-cutoff: nobody in this
project has seen the string the SXC-1 actually presents over USB-MIDI. Binding
nothing because a guessed name did not match would be a total, silent failure for
the one person who owns the hardware. Binding every port when we cannot tell costs
nothing and always works. When we *can* tell, we bind only the SXC-1 — which is
what makes "a message from the other controller must not confirm" a real,
**MEASURED** negative control (P-F: `delivered=0`, the other port is never bound).

Zero ports is a normal state: status `granted`, `ports: []`, and the panel says
"No MIDI input detected — check the USB cable and that the unit is on." Plugging
in later fires `onstatechange` and rebinds. **MEASURED** (P-A/P6, P-F hot-plug).

The owner's device test records the real port name (`docs/M4-device-test-protocol.md`
§4); a follow-up can tighten the match once it is known.

### 3.6 Channel

`midi.md` §1.1: MIDI IN/OUT Ch. default to 1 and are settable 1–16. Default
expected channel is **1**; the panel carries a `1..16` selector. There is no "Any"
option — it would make the wrong-channel negative control meaningless.

The likeliest real-device failure is a learner whose unit is set to another
channel seeing nothing happen. So when a message arrives on a channel other than
the selected one, `#device-status` says so by name ("Received MIDI on channel 3;
this drill is listening on channel 1") and `#btn-device-use-channel` switches to
it in one click. This turns the failure mode into guidance, and `hsLastChan` makes
it assertable.

### 3.7 Wiring into the existing runner

Nothing about the confirmation path is new. The device callback issues **the same
batch the Confirm button already issues**, with `ByDevice` instead of `ByLearner`:

```haskell
ExClocked exid (\mono wall -> [ConfirmStep i ByDevice mono wall, Advance mono wall])
```

so events, `mExResults`, the capped log, and the M3 sink all behave identically.

**Reconciliation.** One function, called after every action that can move the
cursor or the route (`SetRoute`, `ExBatch`, and the device-state action):

```
desired m = case mRoute m of
  RExercise _ exSlug | Just ex <- lookup exSlug
                     , Just p  <- prompt at esCursor
                     , Confirm _ (Just spec) <- prBody p
                     , not (already answered) -> Just (promptId p, spec)
  _ -> Nothing
```

If `desired` differs from the active key, run the old remover and `dvWatch` the new
spec. `mDeviceWatch :: IORef (Maybe (Text, IO ()))` lives beside the hub.

**Stale-confirm guard.** `gradeStep` does **not** check `i == esCursor` — a
`ConfirmStep i` for an already-passed step would re-grade it and emit a duplicate
event. Since the engine cannot change, the guard is in the app: the device
callback dispatches `DeviceConfirm exid promptIdText`, and `updateModel` converts
it into the batch **only if** `promptIdFor exid (esCursor st) == promptIdText`.
Otherwise it is dropped. Negative control D15.

### 3.8 UI and the DOM contract

**`#sxc1-device-state`** — always rendered, always `hidden`, on every route
(exactly like `#sxc1-content-stats`). This is the only DOM difference on a
browser without Web MIDI, and it is invisible, so degradation stays visually
byte-identical to M3.

```json
{"supported":true,"status":"granted","channel":1,
 "ports":["CASIO SXC-1 MIDI 1"],"allPorts":["Arturia KeyStep","CASIO SXC-1 MIDI 1"],
 "watching":{"prompt":"d-2-01#1","spec":"cc 80 127"},
 "lastMessage":[176,80,127],"lastChannel":1,
 "confirms":[{"prompt":"d-2-01#1","source":"device"}]}
```

`confirms` is derived from `esResponses`'s `RConfirmed ByDevice`/`ByLearner` for the
current exercise — which is how CI asserts *who* confirmed without an engine change.

**`#ex-device`** — a `<section>` inside the drill runner, rendered **only** when
`dvAvailable` is true **and** the current exercise has at least one `verify:` hook.
Never on quizzes or lookups, never on a browser without Web MIDI.

| id | element |
|---|---|
| `#btn-device-enable` | the explicit learner action; label tracks status |
| `#device-status` | one plain sentence per status, including the channel mismatch hint |
| `#sel-device-channel` | `<select>` 1–16 |
| `#device-ports` | bound ports, or the "no MIDI input detected" line |
| `#btn-device-use-channel` | shown only on a channel mismatch |

**`#ex-step-N-verify`** — M2 renders a fixed placeholder sentence and ignores the
spec. M4 renders `describeSpec` plus a state class:

* `.ex-verify-idle` — "Device verification is off — confirm manually, or turn it
  on above." (also the text on browsers with no Web MIDI at all)
* `.ex-verify-waiting` — "Waiting for the device: CC 80 = 127 on MIDI channel 1."
* `.ex-verify-confirmed` — "Confirmed by the device: CC 80 = 127."

`describeSpec` renders the spec, not a control name: there is deliberately **no**
CC-number→button-name table in M4. One would need its own grounding proof against
`midi.md` §4 and cost bytes, and the step's authored instruction already tells the
learner which button to press. Recorded as a possible M5 nicety.

The manual `Confirm` button is **never** removed, hidden, or disabled while device
verification is on. Manual confirmation is the default path in every state.

### 3.9 Privacy

`requestMIDIAccess({sysex: false})` — the only call site in the codebase, inside
`hubEnable`, reachable only from `#btn-device-enable`'s handler. No sysex is ever
requested and `0xF0…` messages are dropped at `decodeMidi`. MIDI bytes live in
`HubState` and in the hidden state blob and go nowhere else: no `fetch`, no
storage, no console, and nothing added to `ProgressEvent` or the M3 sink. All four
are enforced by greps in §5 and by a CDP network assertion (D21).

---

## 4. The fake-MIDI harness

`scripts/fake-midi.js` is a **committed repo file**, not a string inside
`browser-check.mjs`: it is reviewable, and the same file drives every scenario.
It is loaded with `Page.addScriptToEvaluateOnNewDocument` on a fresh target
before navigation, so the app's own feature detection sees it. A check asserts it
is never copied into `site/public/`.

It replaces `navigator.requestMIDIAccess` and exposes `window.__SXC1_FAKE_MIDI`:

| member | purpose |
|---|---|
| `calls` | every recorded `{sysex}` — the evidence for "permission only on explicit action" and "never sysex" |
| `setOutcome('grant'\|'deny'\|'absent')` | grant, reject with a `SecurityError`, or make the API undefined entirely |
| `addPort(id,name,mfr)` / `removePort(id)` | topology, firing `onstatechange` |
| `emit(bytes[,portId])` | delivers one message; **returns the number of handlers invoked** |
| `subscribedCount()` | how many ports currently have a handler |
| `ports()` | current ids |

`emit`'s return value and `subscribedCount()` are the anti-vacuity instruments: a
negative control must show `emit(...) >= 1` (or, for the unbound-port case,
`emit(...) === 0` *with* `subscribedCount() >= 1`) so "did not confirm" can never
be confused with "nobody was listening". Ports are plain `Map`s, so `.values()`,
`.size` and `.forEach` behave like a real `MIDIInputMap`. **MEASURED**: the design
probe ran all ten P-F scenarios through this exact file.

**Test vectors come from `translations/midi.md`, not from imagination:**

| bytes | meaning | hook it satisfies |
|---|---|---|
| `[0xB0,0x50,0x7F]` | CC 80 = 127, ch 1 — Bank Select A pressed | `verify: cc 80 127` (d-2-01 step 1) |
| `[0xB0,0x50,0x00]` | CC 80 = 0 — released | nothing (negative) |
| `[0xB0,0x51,0x7F]` | CC 81 — Bank Select B | nothing (negative) |
| `[0xB1,0x50,0x7F]` | CC 80 = 127 on **ch 2** | nothing (negative) |
| `[0x90,0x24,0x7F]` | note 36 — Pad 1, Bank A | `verify: pad 1 bank A` (d-2-02 step 1) |
| `[0x90,0x30,0x7F]` | note 48 — Pad 13, Bank A | `verify: pad 13 bank A` (d-2-02 step 2) |
| `[0x90,0x25,0x7F]` | note 37 — Pad 2, Bank A | nothing (negative for pad 1) |
| `[0xB0,0x6C,0x7F]` | CC 108 = 127 — EFFECT FX1 | `verify: cc 108 127` (d-2-09 step 2) |
| `[0xF0,0x7E,0xF7]` | a system message | nothing (negative) |

### The 22 browser assertions

| # | assertion |
|---|---|
| D1 | `outcome:'absent'` → `supported:false`, `status:"unsupported"`, no `#ex-device` |
| D2 | …and the drill still confirms manually, exactly as in M3, with `.ex-verify-idle` text |
| D3 | fake present, **no click** → `calls.length === 0` (permission never requested at boot) |
| D4 | `#ex-device` present on `#/x/pad-play-banks/d-2-01`, absent on a quiz route |
| D5 | click enable → `calls.length === 1` and `calls[0].sysex === false` |
| D6 | one SXC-1 port → `status:"granted"`, `ports` names it, `watching.spec === "cc 80 127"` |
| D7 | emit `[0xB0,0x50,0x7F]` → step 1 auto-confirms; **exactly one** new event for `d-2-01#1`; `confirms` says `source:"device"` |
| D8 | NEG CC 81 → no confirm, `lastMessage === [176,81,127]`, `emit` returned ≥ 1 |
| D9 | NEG value 0 → no confirm, `lastMessage === [176,80,0]` |
| D10 | NEG channel 2 → no confirm, `lastChannel === 2`, `#device-status` names the mismatch, `#btn-device-use-channel` present |
| D11 | `pad 1 bank A` (d-2-02): note 37 does **not** confirm; note 36 does |
| D12 | two ports, one named SXC-1: `emit(..., 'other-0')` returns 0, `subscribedCount() === 1`, no confirm |
| D13 | one port named "USB MIDI Device": bound anyway (fallback), and confirms |
| D14 | emit the matching message twice → still exactly one event for that prompt |
| D15 | manually confirm step 1, then emit the matching bytes → no second event, cursor unchanged |
| D16 | navigate away from the drill → `watching === null`; a later emit confirms nothing |
| D17 | zero ports at enable → `granted`, `ports: []`; `addPort` then emit → confirms |
| D18 | `removePort` → `ports: []`, no crash, `watching` intact; re-add → confirms again |
| D19 | `outcome:'deny'` → `status:"denied"`, `#device-status` explains, manual confirm still works |
| D20 | **no fake at all** (real Chrome) → `status:"denied"`, no confirm (proves the fake is load-bearing) |
| D21 | zero network requests beyond the app's own assets across a full device scenario |
| D22 | `site/public/` and `site/static/` contain no `fake-midi.js` |

D1/D2/D19/D20 are the graceful-degradation suite; D3/D5 are constraint 2;
D8–D12/D14/D15 are the sabotage-proven negatives; D21/D22 are constraint 3.

### Sabotage sweep (every control must be demonstrated red before it is trusted)

| mutation | must break |
|---|---|
| move `requestMIDIAccess` into `main` | D3 |
| `("sysex", True)` | D5 |
| drop the channel test from `matchSpec` | D10 |
| compare only the CC number, ignore the value list | D9 |
| bind **all** ports instead of the selected ones | D12 |
| bind **only** name-matched ports, no fallback | D13 |
| remove the hub's one-shot removal | D14 |
| remove the stale-confirm guard | D15 |
| skip the remover on reconciliation | D16 |
| render `#ex-device` unconditionally | D1, D4 |
| change one cell of `padNoteTable` | the `SXC1.Midi.Table` agreement self-test |
| "correct" Pad 2/Bank C to 69 in `translations/midi.md` | the same self-test (by design) |
| stop injecting the fake | every positive D-assertion (via D20's contrast) |

---

## 5. Structural invariants (greps, anchored to non-comment lines per M0 n2)

1. `requestMIDIAccess` occurs exactly **once** in `site/app/`, inside `hubEnable`.
2. `sysex` occurs exactly once in `site/app/`, as `False`.
3. `site/app/Device/` contains no `localStorage`/`Storage` (case-insensitive — Miso's
   API is `setLocalStorage`, so a case-sensitive grep would miss it; M2 §4).
4. `site/app/` contains no `fetch`/`getJSON`/`postJSON`/`WebSocket`/`sendBeacon`.
5. `Device/Midi.hs` calls `freeFunction` on every path that drops a `Function`
   (`bindPorts`, `disable`) — asserted by counting `asyncCallback1` vs
   `freeFunction` call sites.
6. `noDeviceVerifier` is **gone** from `Main.hs`, and `dvWatch` has at least one
   real call site (M2's dead-hook shape must not survive).
7. `WASM_GZIP_CEILING_BYTES` is still `1000000` and no M4 task edited it.
8. `SXC1.Midi.Table` is not in `exe:app`'s `other-modules`/import graph.

---

## 6. Size budget

**Measured today at tag `m2`:** `site/public/app.wasm` = 4 759 504 raw,
**988 382 gzip**; ceiling 1 000 000; headroom 11 618. M3's brief records the
gate-cleared figure as 988 367 with ~±1.5 KB per-build variance, and freezes M2.

**M4's provisional budget: 42 000 gzip bytes.**

| component | bytes | basis |
|---|---:|---|
| runtime (hub, decode, match, table, ports, registry, state encoder) | 29 816 | **MEASURED** (P-E, upper bound) |
| view additions (panel, statuses, `describeSpec`, blob wiring, reconciler) | 12 000 | estimated from M2's ~60 gzip bytes/line over ~200 lines |
| **total** | **41 816 → 42 000** | |

**Reserve: 60 000 bytes** held under the frozen 1 000 000 ceiling for M5's
mobile/a11y polish. M5 must not have to fight M4 for bytes.

Therefore M4 requires **`M3_FINAL ≤ 895 000`** (1 000 000 − 60 000 − 42 000, rounded
down for variance). M3's own brief measures the `parseDeck`/`validateDeck` split at
95 358 gzip bytes of browser cost, so this should be comfortable — but it is not
assumed. Wave 0 (`m4-baseline`) measures the merged M3 tree and either writes
`briefs/M4-budget.json` or **stops the milestone**.

Enforcement, mirroring M2's ruling:

1. `device-app`'s verify measures `gzip -c site/public/app.wasm | wc -c` after its
   first successful build and again at the end, and enforces a **task-local**
   ceiling of `min(940 000, M3_FINAL + 42 000)` — so the problem surfaces with the
   author who can fix it.
2. **No M4 task may edit `WASM_GZIP_CEILING_BYTES`.** `verification` and the
   milestone both assert it is still `1000000`.
3. Code-size ladder, in order: derive `Eq` only on the new types (no derived
   `Show`); reuse `Exercises.Corpus`'s JSON combinators rather than writing a
   second encoder; keep `describeSpec` to `Data.Text` concatenation with no
   `printf`-style machinery; keep `-O1`; do **not** enable `--optimize`. If it
   still does not fit, **stop and escalate** — raising the ceiling is a
   coordinator decision, and the escape hatch of last resort is P-D's raw JSFFI.

---

## 7. Real-device protocol

`docs/M4-device-test-protocol.md` (new directory) is written for the owner, in
plain language, and is the only M4 evidence nobody else can produce. It covers:

1. Prerequisites — desktop Chrome/Edge (**not** headless, which denies Web MIDI —
   P-C), SXC-1 firmware ≥ 1.1.1 for MIDI support and ≥ 1.3.0 to match `midi.md`
   v1.2, USB cable, `MIDI OUT Ch.` confirmed via `EDIT`-long-press → system settings.
2. Plug in, open `#/x/pad-play-banks/d-2-01`, click **Enable device verification**,
   grant the browser prompt, and record **the exact port name shown** — this is the
   one fact nobody in the project has, and it decides whether §3.5's matcher can
   be tightened.
3. Drill `d-2-01` (*Reach BANK 1*) step by step. **Step 1 must auto-confirm** when
   the `A` button is pressed (CC 80 = 127). **Steps 2 and 3 carry no `verify:`
   hook and must be confirmed by hand** — that interleaving is the point, not a
   defect.
4. Drill `d-2-02` steps 1–2: pad 1 and pad 13 in bank A auto-confirm.
5. **Byte capture** (settles §3.3): with the device panel open, press pad 1 once
   and copy `lastMessage` out of `#sxc1-device-state`. Report the velocity byte.
   If it is `0`, the CI vector changes and the code's velocity-agnostic
   Note-On rule is *confirmed necessary*.
6. Drill `d-2-09` (*Select and apply effects*): steps 2 and 3 (CC 108/109) must
   auto-confirm. **Step 1 is expected NOT to auto-confirm** — see finding M4-F1
   below. Reporting it as working would be the surprise.
7. Negative check the owner can run: switch the unit's `MIDI OUT Ch.` to 3, press
   `A`, confirm the page says "Received MIDI on channel 3…", click
   **Use channel 3**, press `A` again, and see it confirm.
8. Troubleshooting: no port listed (cable/power/firmware); permission denied
   (re-grant in site settings); confirms on the wrong step; nothing at all
   (fall back to manual — the drill always works).
9. A pass/fail report block to paste back. It is part of the M4 gate evidence.

---

## 8. Findings for the coordinator (not M4 code changes)

* **M4-F1 — `d-2-09` step 1's hook is unreachable in practice.** It reads
  `verify: cc 16 0,127`. CC 16 is **Dial FX1**, which `midi.md` §4 documents as
  transmitting a *continuous* 0–127 value (initial 0, ±1 per detent), not the
  `0`/`127` pair the momentary buttons use. A learner turning the dial a few
  clicks emits 1, 2, 3… and never satisfies the hook. The `verify:` grammar has no
  "any value" form (`parseVerifyValue` requires a non-empty comma list), so this
  cannot be fixed in content alone. Two options for M5: extend the grammar with
  `verify: cc 16` meaning any value (a one-line parser change plus a fixture), or
  re-point step 1 at a button CC. **M4 changes neither** — the brief forbids
  content and validator changes — but the device protocol tells the owner to
  expect it.
* **M4-F2 — M1's P4 Haddock claim is wrong as stated.** See §1 P-D. The corrected
  wording is specified in `device-app`'s prompt.
* **M4-F3 — `gradeStep` does not bound `i` to `esCursor`.** M4 guards it in the app
  (§3.7). A future milestone that is allowed to touch the engine should consider
  moving the guard where it belongs.
* **The two M2-inherited LOWs** (StaticCode totality sweep; `EXERCISE_FIXTURE_FIELDS`
  declared-target validation) are M3's. M4 adds **no** new issue code, so the first
  surface is untouched. Wave 0 records their state; if `EXERCISE_FIXTURE_FIELDS` is
  still open when M4 starts, `device-app` closes it as a rider, since it owns
  `browser-check.mjs` anyway.

---

## 9. Tasks and waves

7 tasks, 5 waves. Ownership is disjoint; every path any verify command reads is
owned by the task or produced by a dependency.

| wave | task | owns |
|---|---|---|
| 0 | `m4-baseline` | `briefs/M4-budget.json` |
| 1 | `midi-spec` | `site/src/SXC1/Midi/`, `site/sxc1-trainer.cabal`, `site/test/CheckExercises.hs` |
| 1 | `device-styles` | `site/static/index.html` |
| 2 | `device-app` | `site/app/`, `scripts/browser-check.mjs`, `scripts/fake-midi.js` |
| 3 | `verification` | `scripts/check-site.sh`, `scripts/build-site.sh` |
| 3 | `device-protocol` | `docs/M4-device-test-protocol.md` |
| 4 | `docs-and-ci` | `README.md`, `.github/workflows/site.yml` |

(`verification` and `device-protocol` are both wave 3 and run in parallel.)

`device-app` owns `browser-check.mjs` alongside `site/app/` for the same reason
M2's `exercise-ui` did: it is the only way a UI task can prove itself end to end
rather than by grep.

### Manifest validation (MEASURED)

`briefs/M4-manifest.json` passes a mechanical validator: M0-schema parity, disjoint
and non-nesting `owned_paths`, an acyclic wave-ordered `depends_on`, dependency
closure over every repo path any of the **71** verify commands reads, `bash -n` on
every command *and* on every inner `bash -c` payload, and `compile()` on all **13**
embedded Python programs.

Every verify command that does not require a full build (40 of the 71) was then
**executed against the pre-M4 tree**: 13 pass (the ownership, frozen-path and
toolchain guards, which must be green from the start), **27 fail with a readable,
specific message** (the M4 checks, which must be red until M4 exists), and
**none** fails silently or with a shell/Python syntax error. The manifest's own
checks are therefore demonstrably falsifiable before a line of M4 is written.

---

## 10. Sign-off conditions

I will withhold sign-off unless:

1. `./scripts/build-site.sh` from a clean `site/public` succeeds, and
   `gzip -c site/public/app.wasm | wc -c` is recorded with its delta from
   `M3_FINAL` and is under the task-local ceiling.
2. `WASM_GZIP_CEILING_BYTES` is literally `1000000` and `git diff` shows no M4
   task touched that line.
3. `./scripts/check-site.sh` prints `result=complete` with zero skipped checks,
   and no new skip axis was added.
4. `exercise-check --self-test` passes, including the `padNote` agreement group;
   I will corrupt one cell of `padNoteTable` in a scratch copy and confirm a
   non-zero exit, then corrupt `translations/midi.md`'s Pad 2/Bank C cell and
   confirm the same.
5. All 22 D-assertions pass, and I will personally re-run at least D3, D5, D10,
   D12, D14, D15 and D20 with their sabotage mutations applied and confirm each
   goes red **for the stated reason** (`emit` return value and `subscribedCount()`
   inspected, not just "did not confirm").
6. A browser with no Web MIDI renders a DOM that differs from M3's only by the
   hidden `#sxc1-device-state` node — I will diff the two.
7. `grep -R fake-midi site/public site/static` is empty.
8. The device protocol names real, resolvable route ids and DOM ids, and I will
   follow it myself against the fake to prove every step is executable before it
   reaches the owner.
9. The owner's pass/fail report is attached to the gate.

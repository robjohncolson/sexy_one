# SXC-1 Trainer — Master exercise inventory

**What this file is.** The consolidated, deduplicated inventory of all exercise candidates for the SXC-1 Trainer, synthesized from the five per-chapter analyst files in `content/inventory/part-1.md` … `part-5.md`. Content-authoring agents should work from this file; the part files remain the source of full drill wording where an entry here is compressed.

**How items cite manual pages.** A bare citation "(p. N)" is a printed page of `translations/guide-book.md`. "Startup Guide p. N" cites `translations/startup-guide.md`. "midi.md p. N" cites `translations/midi.md`. Cross-references of the form "(see PART n, p. N)" reproduce the book's own internal numbering, where the Guide Book labels Pad play–Leveling up as PART 1–4 and leaves Preparation unnumbered.

**IDs.** Every candidate has a stable id `t-c-nn` where `t` is `q` (quiz/flashcard), `d` (device drill), or `l` (reference lookup); `c` is the chapter number **in this inventory's 1–5 order** (1 = Preparation … 5 = Leveling up — note this is offset by one from the book's own PART numbers); `nn` is a two-digit sequence. Ids are stable: never renumber; retired items keep their id with a tombstone note.

**Difficulty tags.** `intro` = first-contact, single-fact or single-action; `core` = the chapter's central skills/facts; `stretch` = advanced, destructive, multi-mode, or spec-level material.

Terminology follows `translations/glossary.md` (binding): on-device labels verbatim, "Part: X" chapter titles, "tap a pad", "assign" (never "register").

---

## Course map

Chapters in teaching order, with deduplicated learning objectives. Preparation objectives already merge the Startup Guide's overlapping setup content (power, volume, troubleshooting) — do not author separate Startup Guide setup exercises.

### Chapter 1 — Part: Preparation (pp. 12–13; Startup Guide pp. 6, 13)
1. Power the unit from an outlet: included USB Type-C cable → POWER/DATA port → USB AC adaptor (p. 12; Startup Guide p. 6).
2. Choose a compliant commercially available USB AC adaptor (USB standard, DC 5 V, 1 A or higher) and cable (USB 2.0, ≤ 1 m) (p. 12).
3. Remove the battery cover (press the raised "−" tab on the rear, slide off) and install four eneloop or AAA alkaline batteries with correct ⊕/⊖ orientation (p. 12; Startup Guide p. 6).
4. Decide between battery and USB AC adaptor power using the battery-life guideline (≈2 h eneloop; ≤1 h alkaline or by conditions) (p. 12).
5. Turn the power on/off with the power switch and confirm the startup screen (Startup Guide p. 6).
6. Recover from Auto Power Off by switching the power switch OFF→ON (p. 12).
7. Output sound via the PHONE jack (headphones), the LINE OUT jack (active speakers/mixer), or the rear built-in speaker; predict when the speaker is silent (p. 13).
8. Adjust volume with the MAIN VOL slider (Startup Guide p. 6).

### Chapter 2 — Part: Pad play (book PART 1, pp. 14–26)
1. Select BANK 1 in Performance mode with the `A`–`D` bank select buttons and directional buttons on the `SELECT BANK` screen (pp. 15–16).
2. Read the Performance mode display: bank indicator, `PAD`, `BPM`, `MASTER BPM` (pp. 15, 18).
3. Explain the bank structure (BANK 1–14 preset area, 15+ user area, up to 80) and change which bank an `A`–`D` button holds (p. 16).
4. Tap pads to play one-shot and looped sounds; stop loops with the pad or `▶/■`; know the BANK1 pad map by role (pp. 17, 20).
5. Describe Beat Sync (time stretch + quantize), OFF by default, turned ON in the system settings; predict MASTER BPM behavior (p. 18).
6. Perform the core finger-drumming layering exercise and read the waveform display (pp. 19–20).
7. Predict playback for all four `ONE SHOT`/`LOOP` button-state combinations (p. 21).
8. Predict switch-vs-layer behavior from pad grouping (p. 22).
9. Layer sounds across banks without interrupting playback (switch banks with `A`–`D`, not the directional buttons) (p. 23).
10. Select effect types and strengths on `FX1`/`FX2` (button unlit = type, lit = strength) and name every effect type (pp. 24–25).

### Chapter 3 — Part: Sampling (book PART 2, pp. 27–34)
1. Select a bank with empty (unlit) pads as the sampling destination (BANK 15; BANK 14's unlit pads also work) (p. 28).
2. Select the input source with `INPUT SELECT` (`MIC` / `♪` / `USB`) and set input level with `INPUT VOL` so the meter does not peak out (p. 28).
3. Enter Sampling mode with `REC`; distinguish `AUTO TRIGGER` from `MANUAL TRIGGER` and switch with `←`/`→` (p. 29).
4. Record a voice sample to an empty pad, stop, and verify (pad lights yellow, plays back) (pp. 29–30).
5. Time recordings against a mental count so samples fit 1 or 2 counts; build a 3-pad voice-percussion kit and play a rhythm with it (pp. 30–31).
6. Change a fresh sample's playback with `ONE SHOT`/`LOOP` (behavior itself taught in Chapter 2) (p. 31).
7. Delete one or more samples with `DEL` + pad selection + `A` confirm (p. 32).
8. State what EDIT mode, resampling, and chop offer (detailed in Chapter 5) (p. 33).
9. Plan a balanced original user bank (rhythm/bass/chord/other) to prepare for the sequencer (p. 34).

### Chapter 4 — Part: Sequencer (book PART 3, pp. 35–45)
1. Enter/leave Sequence mode (long-press an `A`–`D` button; OK with `A`, cancel `B`; long-press the lit button to return) (p. 36).
2. Define a sequence (≤ 8 measures, one bank's samples, ≤ 50 patterns, sequence banks 1–50) and save to bank 5+ (p. 36).
3. Read the Sequence mode display: bank, tempo, metronome, measures, pad number, step grid; scroll for pad 7+ (p. 37).
4. Set the number of measures (p. 38).
5. Record a 2-measure 8-beat drum pattern with real-time input and read the `REC`/`▶/■` LED states (p. 39).
6. Edit with step input (cursor + `A` enter / `B` erase) stopped or during playback (p. 40).
7. Explain sequencer quantize (16th-note smallest unit) (p. 40).
8. Distinguish real-time input from step input; layer one pad at a time (p. 41).
9. Extend to 4 measures and add synth chords for a song-like pattern (pp. 42–43).
10. Know that only one-shot sounds go into a sequence; looped sounds are layered live; practice over playback before inputting (p. 43).
11. Use the sequence EDIT function: SOUND BANK, BPM, CLEAR (TRACK/BAR/ALL), METRONOME, PRECOUNT (p. 44).

### Chapter 5 — Part: Leveling up (book PART 4, pp. 46–61; midi.md)
1. Layer real-time pad performance over sequence playback (`A`–`D` + `▶/■`) and predict Beat Sync tempo behavior in both trigger orders (p. 47).
2. Use SOUND EDIT per pad: `PITCH` (±24 semitones, speed changes too), `VOLUME` (0–100), `GROUP` (1–16 / 0, shared across banks), `COLOR` (1–8), `BPM` (manual or `---` to exclude from Beat Sync) (pp. 48–49).
3. Perform waveform editing of a sample's start point / end point with the dials (p. 49).
4. Resample a pad to an empty pad — within or across banks, optionally adding mic/external sound or baking in an effect (pp. 50–51).
5. Use `AUTO CHOP` to split an external phrase beat by beat (1/2/4/8 beats per pad) across pads, and split manually at chosen timings (pp. 52–54).
6. Operate the system settings (long-press `EDIT`): `AUTO Trig Lv`, `Beat Sync`, `LED Bright`, `Disp Bright`, `APO Time`, `BATTERY Type`, `POWER Supply`, `FW Version`, `SERIAL No.`, `Initialize` (p. 55).
7. Connect to the CASIO Sampler App via the `DATA` port and use it for assigning, copying, waveform editing, sequence editing, data organization, backup, and updates (pp. 56–60).
8. Set MIDI channels (`MIDI IN Ch.` / `MIDI OUT Ch.`) and know the CC / note-mapping basics (midi.md pp. 1–4; firmware 1.1.1+).

---

## Inventory

### Chapter 1 — Part: Preparation

#### Quiz/flashcard candidates
- **q-1-01** (intro) The included USB Type-C cable connects to the POWER/DATA port (p. 12).
- **q-1-02** (intro) The separately available USB AC adaptor is the AD-XA06J Type-C (p. 12; Startup Guide p. 6).
- **q-1-03** (core) A commercially available USB AC adaptor must conform to the USB standard with an output of DC 5 V, 1 A or higher (p. 12).
- **q-1-04** (core) A commercially available USB cable used for power must conform to the USB 2.0 standard and be no longer than 1 m (p. 12).
- **q-1-05** (intro) The unit takes four batteries: eneloop or AAA alkaline (p. 12).
- **q-1-06** (intro) The battery cover is on the rear; it slides off while you press its raised tab ("−" shape) (p. 12).
- **q-1-07** (intro) When installing batteries, the ⊕ and ⊖ ends must face the correct way (p. 12).
- **q-1-08** (core) Continuous operation on batteries: approximately 2 hours on eneloop (p. 12).
- **q-1-09** (core) On alkaline batteries, or depending on usage conditions, continuous operation may drop to 1 hour or less (p. 12).
- **q-1-10** (intro) For extended use, powering with a USB AC adaptor is recommended (p. 12).
- **q-1-11** (intro) Auto Power Off: if no operation is performed for a set period while the power is on, the power turns off automatically (p. 12).
- **q-1-12** (intro) To resume after Auto Power Off, switch the power switch OFF→ON once (p. 12).
- **q-1-13** (intro) The time until Auto Power Off can be set in the system settings (see p. 55) (p. 12). [Reinforced by q-5-55.]
- **q-1-14** (intro) Headphones connect to the PHONE jack (p. 13).
- **q-1-15** (intro) Active speakers or an external mixer connect to the LINE OUT jack (p. 13).
- **q-1-16** (intro) The built-in speaker is on the rear of the unit (p. 13).
- **q-1-17** (core) No sound is output from the built-in speaker while headphones or another device are connected to the PHONE jack (p. 13).
- **q-1-18** (intro) Sliding the power switch to [ON] shows the startup screen and readies the unit for use (Startup Guide p. 6).
- **q-1-19** (intro) The MAIN VOL slider adjusts the volume of the built-in speaker and the PHONE jack: left lower, right raise (Startup Guide p. 6).

#### Device drill candidates
- **d-1-01** (intro) **Power from a power outlet** — Connect the included USB Type-C cable to the POWER/DATA port, the other end to a USB AC adaptor (AD-XA06J Type-C or compliant), plug into an outlet. Success: power switch [ON] brings up the startup screen with no batteries installed. (p. 12; Startup Guide p. 6)
- **d-1-02** (intro) **Install batteries** — Press the "−" tab, slide off the battery cover, install four eneloop or AAA alkaline batteries per the ⊕/⊖ markings, reattach the cover. Success: with no USB power, [ON] brings up the startup screen. (p. 12; Startup Guide p. 6)
- **d-1-03** (intro) **Turn the power on and off** — Slide the power switch to [ON], confirm the startup screen, then [OFF]. Success: startup screen on power-on, display dark on power-off. (Startup Guide p. 6; p. 12)
- **d-1-04** (intro) **Recover from Auto Power Off** — Leave the powered unit untouched until it powers off, then switch OFF→ON. Success: unit powers off on its own after the idle period; startup screen returns after OFF→ON. (p. 12)
- **d-1-05** (intro) **Output sound through headphones and the built-in speaker** — Play a sound with nothing in the PHONE jack (rear speaker sounds), connect headphones, play again (headphones only), adjust MAIN VOL. Success: speaker silent while headphones connected; MAIN VOL audibly changes level. (p. 13; Startup Guide p. 6)
- **d-1-06** (intro) **Output sound through the LINE OUT jack** — Connect active speakers or a mixer to LINE OUT (3.5 mm stereo mini) and play. Success: sound from the external gear. (p. 13)

#### Reference-lookup candidates
- **l-1-01** (intro) Where do you set the time until Auto Power Off? → System settings, `APO Time` (see p. 55; pointer on p. 12).
- **l-1-02** (intro) What output rating must a commercially available USB AC adaptor have, and the cable requirements? → Power notes, p. 12 (also Startup Guide p. 6).
- **l-1-03** (intro) Model number of the separately available USB AC adaptor? → p. 12 (also Startup Guide p. 6).
- **l-1-04** (intro) How long does the unit run on batteries (eneloop vs. alkaline)? → Battery-life guideline, p. 12 (also Startup Guide p. 6).
- **l-1-05** (intro) What to check when no sound comes out? → Troubleshooting, "No sound" (Startup Guide p. 13).
- **l-1-06** (intro) What to check when the power does not turn on? → Troubleshooting, "Power does not turn on" (Startup Guide p. 13).
- **l-1-07** (core) How to replace the batteries when `REPLACE THE BATTERY` appears? → "Replacing the batteries", Operating precautions (p. 9).
- **l-1-08** (core) What precautions apply to USB power supply? → "Precautions concerning USB power" (p. 8).

### Chapter 2 — Part: Pad play

#### Quiz/flashcard candidates
- **q-2-01** (intro) A set of sounds assigned to the 16 pads is called a "BANK (bank)" (p. 15).
- **q-2-02** (intro) On power-on the "SXC-1" logo is displayed; when it disappears, Performance mode starts (p. 15).
- **q-2-03** (intro) If the bank number is not 1 and a `B`–`D` button is lit, press `A` to get "SELECT BANK 1" (p. 15).
- **q-2-04** (core) Which `A`–`D` button is lit and each pad's lighting color come from the state at last power-off (p. 15).
- **q-2-05** (core) On the `SELECT BANK` screen, ↑/↓ change the bank number by 1; ←/→ by 10 (p. 16).
- **q-2-06** (intro) Using the dedicated app (CASIO Sampler App), you can name banks (p. 16). [Reinforced by q-5-77.]
- **q-2-07** (core) BANK 1–14 are preset (preset area); BANK 15 and above are the user area (p. 16).
- **q-2-08** (core) You can create up to 80 banks (p. 16).
- **q-2-09** (core) Running "Initialize" in the system settings returns the unit to its factory default state; sounds you assigned yourself are erased (p. 16). [Procedure in q-5-60.]
- **q-2-10** (intro) By default, BANK 1–4 are assigned to the `A`–`D` buttons (p. 16).
- **q-2-11** (core) After pressing an `A`–`D` button, the directional buttons change the bank assigned to that button (p. 16).
- **q-2-12** (core) BANK1 pad map: pad 1 = bass drum (kick), pad 2 = snare drum, pad 3 = hi-hat, pad 4 = sound effects — all one-shot sounds (p. 17).
- **q-2-13** (core) BANK1 pads 5–8 = keyboard chord playing, one-shot sounds (p. 17).
- **q-2-14** (core) BANK1 pads 9–12 = bass phrases and piano phrases, looped sounds (p. 17).
- **q-2-15** (core) BANK1 pads 13–16 = drums and percussion rhythm loops; pads 13/14 row also holds the rhythm without drums — looped sounds (p. 17).
- **q-2-16** (intro) A tapped pad lights up white; when the sound finishes, it returns to its original color (p. 17).
- **q-2-17** (intro) One-shot sound: a single sound plays just once (p. 17).
- **q-2-18** (intro) Looped sound: tap once and it loops; tap the same pad again and it stops (p. 17).
- **q-2-19** (core) Beat Sync makes multiple looped sounds play so they sound natural when layered (p. 18).
- **q-2-20** (core) Beat Sync is OFF by default; turn it ON in the system settings (p. 18). [Setting itself: q-5-49–50 area, drill d-5-02.]
- **q-2-21** (core) Beat Sync has two components: time stretch and quantize (p. 18).
- **q-2-22** (core) Time stretch: a sound with a different BPM plays matched to the tempo of the sound already playing; pitch stays the same (p. 18).
- **q-2-23** (core) The BPM at the upper right of the display is the sound's tempo information; the same value appears in the MASTER BPM area (p. 18).
- **q-2-24** (core) While a MASTER BPM is set, other sounds play at the MASTER BPM tempo regardless of their original tempo (p. 18).
- **q-2-25** (core) Stopping playback resets the MASTER BPM (p. 18).
- **q-2-26** (core) Quantize (Beat Sync) corrects slight timing errors when triggering a second looped sound, aligning loop starts precisely (p. 18). [Sequencer quantize is q-4-33.]
- **q-2-27** (intro) When you tap a pad, the sound's waveform is displayed; a vertical line moves left to right as it plays (p. 19).
- **q-2-28** (intro) Waveform axes: vertical = loudness, horizontal = passage of time (p. 19).
- **q-2-29** (intro) The waveform display is also used in systems employed for professional recording (p. 19).
- **q-2-30** (core) `ONE SHOT` ON (lit): tap and the sound plays to the end; tapping again before it finishes restarts from the beginning (p. 21).
- **q-2-31** (core) `ONE SHOT` OFF (unlit): the sound plays only while the pad is held and stops on release; tapping again restarts (p. 21).
- **q-2-32** (core) `LOOP` ON (lit): the sound plays repeatedly; stops on pad tap or `▶/■` (p. 21).
- **q-2-33** (core) `LOOP` OFF (unlit): the sound plays to the end, then stops (p. 21).
- **q-2-34** (core) The ONE SHOT/LOOP setting is remembered as is for each pad (p. 21).
- **q-2-35** (intro) Preset sounds come preconfigured with ONE SHOT/LOOP settings that suit their content (p. 21).
- **q-2-36** (core) ONE SHOT unlit + LOOP lit: the sound repeats while the pad is held (p. 21).
- **q-2-37** (stretch) Advanced uses: cut off the tail of a long sound for a percussive effect, or loop a short sound (p. 21).
- **q-2-38** (core) Whether a second tapped pad switches or layers the sound is determined by pad grouping (p. 22).
- **q-2-39** (core) Grouped pads: the sound switches to the pad tapped later (e.g. BANK1 rhythm pads 13 → 14) (p. 22).
- **q-2-40** (core) Pads in a different group or not grouped: the later pad's sound is layered on top (e.g. bass pad 9 + piano pad 11) (p. 22).
- **q-2-41** (core) BANK1 groups: rhythm = pads 13–16, bass = pads 9–10, piano = pads 11–12 (p. 22).
- **q-2-42** (intro) Each pad's group and lighting color can be set individually (see PART 4, pp. 48–49) (p. 22).
- **q-2-43** (core) Switching banks with the directional buttons during playback interrupts the sound — set the banks you plan to use to the `A`–`D` buttons in advance (p. 23).
- **q-2-44** (core) Two effect lines are provided, `FX1` and `FX2`; you can apply one or both at once (p. 24).
- **q-2-45** (core) With the `FX1`/`FX2` button unlit, turning the dial selects the effect type (p. 24).
- **q-2-46** (core) With the `FX1`/`FX2` button lit, turning the dial changes how strongly the effect is applied (p. 24).
- **q-2-47** (core) When multiple pads' sounds are layered, the effect is applied to the entire sound playing, and to pads tapped after selecting the effect (p. 24).
- **q-2-48** (core) FX1 effect types: FILTER, FLANGER, PHASER, BIT CRUSHER (p. 25).
- **q-2-49** (core) FX2 effect types: ROLL 1, ROLL 1/2, ROLL 1/4, ROLL PATTERN, DELAY 3/4, DELAY 3/16 (p. 25).
- **q-2-50** (stretch) FILTER muffles or lightens the sound; cutoff frequency, resonance, and filter type change in combination (p. 25).
- **q-2-51** (stretch) FLANGER adds a metallic swirl; depth, rate, feedback, and mix change in combination (p. 25).
- **q-2-52** (stretch) PHASER adds a swirl differently than the flanger; stages, rate, depth, feedback, and mix change in combination (p. 25).
- **q-2-53** (stretch) BIT CRUSHER adds digital noise and distorts; bit depth, sample rate, and dry/wet change in combination (p. 25).
- **q-2-54** (stretch) ROLL 1 / ROLL 1/2 / ROLL 1/4 sound like rapid pad hits at progressively finer spacing; ROLL PATTERN uses a fixed pattern (p. 25).
- **q-2-55** (stretch) DELAY 3/4 and DELAY 3/16 add a delayed copy of the sound for an echo-like effect (p. 25).
- **q-2-56** (core) FX2 varies continuously from dry (effect 0) to wet (effect 100) (p. 25).
- **q-2-57** (core) Finger-drumming trick: fix which finger taps each pad (kick = thumb, snare = index, hi-hat = middle) and start from a slow tempo (p. 26).

#### Device drill candidates
- **d-2-01** (intro) **Select BANK 1** — Power on, wait for the logo to clear, press `A` if a `B`–`D` button is lit, then use ↑/↓ (±1) or ←/→ (±10) to reach 1. Success: "SELECT BANK 1" / bank "A:1". (pp. 15–16)
- **d-2-02** (intro) **Tap the pads: one-shot vs. looped** — In BANK 1, tap pads 1–4 (each plays once), 5–8 (chords), then pad 13 (loops) and pad 13 again (stops). Success: white lighting on tap; one-shots play once, the loop repeats until tapped again. (p. 17)
- **d-2-03** (core) **Finger drum along with a looped sound** — Pad 13 → pad 15 (rhythm without drums) → layer pads 1–2 → add bass pad 9 on the loop start → layer chords 5–8. Success: loops plus live taps layered; waveform line moves left to right. (pp. 19–20)
- **d-2-04** (intro) **Stop multiple loops at once with `▶/■`** — Start two loops (e.g. 13 and 9), press `▶/■`. Success: all loops stop at once. (p. 20)
- **d-2-05** (core) **Observe Beat Sync (time stretch + quantize)** — With Beat Sync ON (system settings, p. 55 — see d-5-02), play a BPM-tagged pad, note BPM and MASTER BPM, trigger a second loop with a different BPM, then stop and replay. Success: second sound follows MASTER BPM with pitch unchanged; stopping resets MASTER BPM; off-timed taps are corrected. (p. 18)
- **d-2-06** (core) **Explore the ONE SHOT and LOOP button states** — On one pad, try all four combinations (tap / hold-release / tap once / hold). Success: behaviors match the p. 21 table and the setting is remembered per pad. (p. 21)
- **d-2-07** (core) **Hear grouping: switch vs. layer** — Tap pad 13 then 14 (switch); tap pad 9 then 11 (layer). Success: grouped rhythm pads replace each other; bass + piano sound together. (p. 22)
- **d-2-08** (stretch) **Layer sounds across two banks** — `B` → BANK2, play pads 16 + 9, `A` → BANK1, layer bass pad 9, kick and snare. Success: both banks sound together; BANK1 bass follows the faster tempo (time stretch); no dropout because banks were switched with `A`–`D`. (p. 23)
- **d-2-09** (core) **Select and apply effects with FX1/FX2** — With a loop playing: FX1 unlit + dial = type (watch `EFFECT INFO`), FX1 lit + dial = strength; repeat for FX2; apply both. Success: display shows `FX1:`/`FX2:` types; the whole mix audibly changes; FX2 sweeps dry (0) to wet (100). (pp. 24–25)
- **d-2-10** (stretch) **Finger-drumming technique practice** — Assign fingers (kick=thumb, snare=index, hi-hat=middle), start ~50 BPM, practice kick+snare then hi-hat+snare, raise tempo (100, 150 BPM…). Success: steady pattern with assigned fingers at increasing tempos. (p. 26)

#### Reference-lookup candidates
- **l-2-01** (core) What does each `ONE SHOT`/`LOOP` state combination do? → tables and four-row state diagram (p. 21).
- **l-2-02** (intro) Which sounds are on which BANK1 pads? → pad-layout callout figure (p. 17).
- **l-2-03** (core) Which effect types are on FX1/FX2 and what does each dial change? → "Effects explained" list (p. 25).
- **l-2-04** (intro) Range of the FX2 dry/wet sweep? → dry (0) to wet (100) note (p. 25).
- **l-2-05** (intro) How many banks, and which are preset vs. user area? → "About the SXC-1's 'banks'" (p. 16).
- **l-2-06** (intro) How do directional buttons change the bank number (±1 vs. ±10)? → diagram note (p. 16).
- **l-2-07** (intro) Where do I turn Beat Sync ON? → Beat Sync intro pointing to system settings (see PART 4, p. 55) (p. 18).
- **l-2-08** (intro) Where is pad grouping (and lighting color) set up in detail? → pointer to PART 4, pp. 48–49 (p. 22).
- **l-2-09** (intro) Where can I name and manage banks from the app? → pointer to PART 4, p. 60 (p. 16).
- **l-2-10** (intro) What does "Initialize" do to my own sounds? → note under "About the SXC-1's 'banks'" (p. 16).
- **l-2-11** (intro) Which BANK1 pads belong to which group? → grouping example figure (p. 22).
- **l-2-12** (intro) What do the waveform display's axes mean? → waveform sidebar (p. 19).

### Chapter 3 — Part: Sampling

*Deduplicated out of this chapter (kept in Chapter 2): the ONE SHOT/LOOP behavior card (see q-2-30…q-2-36, l-2-01 — the p. 31 tip merely points back to p. 21) and the "details in PART 4" quiz item (kept only as lookup l-3-06). Reinforcement opportunity: when drilling d-3-07, re-ask q-2-30–33.*

#### Quiz/flashcard candidates
- **q-3-01** (intro) The sampling feature lets you record, play back, and edit any sound you like (p. 28).
- **q-3-02** (intro) Sampling can be done easily with the built-in microphone, and recorded sounds can be played on the pads right away (p. 27).
- **q-3-03** (core) Pads with no sample assigned do not light up (p. 28).
- **q-3-04** (core) In BANK 14, you can sample to the pads that are unlit (p. 28).
- **q-3-05** (intro) The `INPUT SELECT` switch positions are `MIC`, `♪`, and `USB` (p. 28).
- **q-3-06** (intro) `INPUT SELECT` = `MIC` selects the built-in microphone (p. 28).
- **q-3-07** (core) To record an instrument or external device on the AUDIO IN (♪) jack, set `INPUT SELECT` to `♪` (p. 28).
- **q-3-08** (core) To record playback sound from a smartphone on the DATA port, set `INPUT SELECT` to `USB` (p. 28).
- **q-3-09** (core) When sampling with the built-in microphone, set `INPUT VOL` to maximum (p. 28).
- **q-3-10** (intro) Use the included USB cable to connect to a smartphone (p. 28).
- **q-3-11** (core) Adjust the device volume and `INPUT VOL` so the level meter does not peak out while recording (p. 28).
- **q-3-12** (intro) Before connecting external devices, read "Connections" on p. 8 (p. 28).
- **q-3-13** (intro) Pressing the `REC` button in Performance mode enters Sampling mode (p. 29).
- **q-3-14** (intro) In Sampling mode, the `REC` button flashes and the empty pads flash (p. 29).
- **q-3-15** (intro) The Sampling mode display shows `SAMPLING MODE` with the trigger setting and L/R level meters (p. 29).
- **q-3-16** (intro) The trigger setting is selected with the directional buttons `←`/`→` (p. 29).
- **q-3-17** (core) `AUTO TRIGGER` starts recording automatically when sound is input (p. 29).
- **q-3-18** (core) With `MANUAL TRIGGER`, recording starts the moment you select a pad — choose it to decide the start timing yourself (p. 29).
- **q-3-19** (core) With AUTO TRIGGER, after selecting a pad, speaking toward the microphone starts recording automatically (p. 30).
- **q-3-20** (intro) During recording, the `REC` button is lit and the level meter swings with the sound (p. 30).
- **q-3-21** (core) To stop recording, press the selected pad again or press the `REC` button (p. 30).
- **q-3-22** (intro) After recording stops, the `REC` button goes unlit (p. 30).
- **q-3-23** (core) A pad with a sample assigned lights up yellow (p. 30).
- **q-3-24** (intro) Tap the pad after recording to check the sound (p. 30).
- **q-3-25** (core) Counting "1, 2, 3, 4" in your head, then speaking and stopping with good timing, creates samples that are easy to work with (p. 30).
- **q-3-26** (intro) The pad lighting color can be changed later (see PART 4, p. 49) (p. 30). [Detail in q-5-14.]
- **q-3-27** (core) A sample immediately after recording is treated as a one-shot sound (p. 31).
- **q-3-28** (intro) Pressing the `DEL` button makes the pads with samples assigned flash (p. 32).
- **q-3-29** (core) In DEL mode, a pad selected for deletion lights up white; the other assigned pads keep flashing (p. 32).
- **q-3-30** (core) You can select multiple pads and delete them all at once (p. 32).
- **q-3-31** (core) Deletion is confirmed with the `A` button; the display reads `DELETING` and the pad goes out (p. 32).
- **q-3-32** (core) In EDIT mode you can change the pitch and volume of a sample, adjust the playback position, and more (p. 33).
- **q-3-33** (core) Preset samples that are already assigned can also be edited (p. 33).
- **q-3-34** (core) The `SOUND EDIT` menu shows `PITCH`, `VOLUME`, `GROUP`, and `COLOR` (p. 33). [Chapter 5 adds `BPM` to this list at pp. 48–49.]
- **q-3-35** (stretch) You can cut out part of a sample and play it (p. 33).
- **q-3-36** (intro) With the dedicated app (CASIO Sampler App), waveform editing is even more convenient (p. 33).
- **q-3-37** (core) Resampling means sampling a sample assigned to a pad once again onto a different pad (p. 33). [Detailed procedure: q-5-21 onward.]
- **q-3-38** (core) While resampling you can copy the same sample, add new sounds, or apply effects (p. 33).
- **q-3-39** (core) Chop means splitting a sample into small pieces and distributing them across multiple pads (p. 33).
- **q-3-40** (core) There is a feature that samples a long phrase and automatically distributes it beat by beat (auto chop) (p. 33). [Detail in q-5-35 onward.]
- **q-3-41** (intro) Sampling — music from existing sounds as material — was born in the 1980s and became heavily used in hip-hop, house, and other genres (p. 34).
- **q-3-42** (core) Putting rhythm-type, bass-type, chord-type, and other samples together in one bank in a balanced way helps both pad performance and song creation with the sequencer (p. 34).

#### Device drill candidates
- **d-3-01** (intro) **Prepare for mic sampling** — Select BANK 15 (unassigned pads), set `INPUT SELECT` to `MIC`, `INPUT VOL` to maximum. Success: `SELECT BANK 15` shown, pads unlit. (pp. 28–29)
- **d-3-02** (intro) **Enter Sampling mode and read the trigger setting** — Press `REC`, confirm `AUTO TRIGGER`, browse trigger settings with `←`/`→` and return. Success: `REC` and empty pads flash; display shows `SAMPLING MODE: AUTO TRIGGER` with L/R meters. (p. 29)
- **d-3-03** (core) **Sample your voice to pad 4 (AUTO TRIGGER)** — Select pad 4, count "1, 2, 3, 4", speak "Den-tak!" (recording auto-starts), stop with the pad or `REC`, tap to check. Success: meter swings, `REC` lit then unlit, pad 4 lights yellow and plays back. (pp. 29–30)
- **d-3-04** (core) **Sample with MANUAL TRIGGER** — Enter Sampling mode, select `MANUAL TRIGGER`, select a pad (recording starts immediately), make the sound, stop. Success: recording starts on pad selection; pad lights yellow. (pp. 29–30)
- **d-3-05** (core) **Build a 3-pad voice-percussion kit** — Record "Don" to pad 8 and "Chh" to pad 12, each within 1 count, alongside pad 4. Success: pads 4, 8, 12 lit yellow, each plays its own sample. (p. 31)
- **d-3-06** (core) **Play a rhythm pattern with the 3 pads** — Don (8), Chh (12), Don, Chh, with "Den-tak" (4) under hits 1 and 3, repeated in time. Success: steady voice-percussion rhythm from your own sounds. (p. 31)
- **d-3-07** (core) **Change a sample between one-shot and looped playback** — Use `ONE SHOT`/`LOOP` (behavior per p. 21 / Chapter 2) on a fresh sample and compare states. Success: same pad plays once vs. repeats, matching button states. (p. 31) [Reinforces d-2-06 on user material.]
- **d-3-08** (core) **Delete samples from pads** — `DEL` → assigned pads flash → select pad(s) (lit white) → confirm with `A`. Success: `DELETING` shown, pad goes out, tapping produces no sound. (p. 32)
- **d-3-09** (stretch) **Record from an external source** — Connect instrument to AUDIO IN (♪) or smartphone to DATA (read "Connections", p. 8), set `INPUT SELECT` to `♪`/`USB`, level so the meter doesn't peak, sample as in d-3-03. Success: no peaking; pad lights yellow with the external sound. (pp. 28–30)

#### Reference-lookup candidates
- **l-3-01** (intro) Which bank besides BANK 15 has empty pads to sample to? → note on p. 28 (BANK 14, unlit pads).
- **l-3-02** (intro) Where are the connection instructions to read before recording external devices? → "Connections", p. 8 (referenced from p. 28).
- **l-3-03** (core) What trigger settings exist in Sampling mode and what does each do? → steps 3–4, p. 29 (`AUTO TRIGGER`, `MANUAL TRIGGER`).
- **l-3-04** (intro) How do you change a pad's lighting color? → note pointing to PART 4, p. 49 (p. 30).
- **l-3-05** (intro) What settings appear on the `SOUND EDIT` screen? → screenshot on p. 33 (`PITCH`, `VOLUME`, `GROUP`, `COLOR`).
- **l-3-06** (intro) Where are resampling and chop explained in detail? → "For details, go to PART 4" (p. 33).

### Chapter 4 — Part: Sequencer

#### Quiz/flashcard candidates
- **q-4-01** (intro) The sequencer feature arranges samples freely and plays rhythms, melodies, and more automatically (p. 36).
- **q-4-02** (intro) The production style the sequencer lets you experience is called "step-based music production" (p. 36).
- **q-4-03** (core) Enter Sequence mode: in Performance mode, long-press one of the `A`–`D` buttons (p. 36).
- **q-4-04** (core) On the sequence selection display, choose "OK (A)" with `A`; cancel with `B` (p. 36).
- **q-4-05** (intro) The sequence selection screen shows `SEQUENCE SLCT` / `BANK = 1` / `OK(A) CANCEL(B)` (p. 36).
- **q-4-06** (intro) During sequence selection the `A` button flashes; once Sequence mode is displayed it is lit (p. 36).
- **q-4-07** (core) Return to Performance mode by long-pressing the lit button (p. 36).
- **q-4-08** (core) A "sequence" is a performance pattern of up to 8 measures made with the samples of one bank (p. 36).
- **q-4-09** (core) You can create up to 50 sequence patterns (p. 36).
- **q-4-10** (core) Sequences are saved as sequence banks 1–50 (p. 36).
- **q-4-11** (core) By default, sequence banks 1–4 are assigned to the `A`–`D` buttons (A→BANK1 … D→BANK4) (p. 36).
- **q-4-12** (core) To save to sequence bank 5 or higher, choose the bank number with the directional buttons at sequence selection; on OK, the sequence is assigned to the currently selected `A`–`D` button (p. 36).
- **q-4-13** (intro) Sequence banks are easy to manage using the dedicated app (see PART 4, p. 60) (p. 36). [Detail in q-5-79.]
- **q-4-14** (intro) Display, bank area: shows which bank select button `A`–`D` (sound bank) is selected (p. 37).
- **q-4-15** (intro) Display, tempo area: shows the tempo of the sequence (p. 37).
- **q-4-16** (intro) Display, metronome area: shows whether the metronome will sound during recording/playback (p. 37).
- **q-4-17** (intro) Display, number of measures: shows measure count and which measure's cells are displayed (p. 37).
- **q-4-18** (core) For pad 7 and beyond, scroll with the directional buttons (p. 37).
- **q-4-19** (core) Pad input area: divides 1 measure into 16 parts and shows which pad's sample sounds at which timing (p. 37).
- **q-4-20** (core) Sequence mode samples default to BANK1; change with "SOUND BANK" in the EDIT function (p. 38).
- **q-4-21** (core) Set the number of measures: up directional button to the measure row, right button to move the ▲, confirm with `A` (p. 38).
- **q-4-22** (core) Pressing the `B` button lets you reduce the number of measures (p. 38).
- **q-4-23** (core) Pressing the lit `REC` button makes the `▶/■` button flash together with it (p. 39).
- **q-4-24** (core) After the metronome count sounds 4 times, start playing (p. 39).
- **q-4-25** (core) The tempo defaults to BPM = 120; change it with "BPM" in the EDIT function (p. 39).
- **q-4-26** (core) The cells at the timing where you tapped a pad are filled in white (p. 39).
- **q-4-27** (core) Once you finish tapping through the measures, playback continues even if you stop tapping (p. 39).
- **q-4-28** (core) Pressing `▶/■` ends recording; the buttons return from flashing to lit (p. 39).
- **q-4-29** (core) With recording stopped (buttons lit), pressing `▶/■` plays back what you entered (p. 39).
- **q-4-30** (core) Editing is possible with recording/playback stopped and also during recording/playback (p. 40).
- **q-4-31** (core) In the step grid, `B` erases the sound the cursor is on; `A` enters a sound at the cursor's timing (p. 40).
- **q-4-32** (core) The smallest unit of sound in Sequence mode is the 16th note — one measure of 4/4 divided into 16 (p. 40).
- **q-4-33** (core) Tap timing off by less than a 16th note is corrected to the nearest timing — "quantize" (p. 40). [Beat Sync's quantize (q-2-26) is a different context.]
- **q-4-34** (intro) If you don't need the metronome sound, turn it OFF with `METRONOME` in the EDIT function (p. 41).
- **q-4-35** (core) Recording your pad performance exactly as you play it is called "real-time input" (p. 41).
- **q-4-36** (core) When playing multiple pads at once is hard, input one pad at a time (hi-hat first, then kick, then snare) (p. 41).
- **q-4-37** (core) Inputting by filling in on-screen cells one note at a time is called "step input" (p. 41).
- **q-4-38** (intro) Using the dedicated app, you can copy and paste patterns you have input (see PART 4, p. 59) (p. 42).
- **q-4-39** (core) The CASIO Sampler App sequence toolbar offers Cut / Copy / Paste / Duplicate to next measure / Clear (p. 42). [Also surfaced as the app's pad-number long-press menu, p. 59.]
- **q-4-40** (core) Only one-shot sounds can be incorporated into a sequence (p. 43).
- **q-4-41** (core) Looped sounds can be layered by performing in real time during sequence playback (see PART 4, p. 47) (p. 43).
- **q-4-42** (core) Practicing over a playing sequence: `▶/■` flashing, `REC` lit; inputting: both flashing (p. 43).
- **q-4-43** (core) In Sequence mode, press `EDIT` to open the sequence settings screen; press `EDIT` again to return (p. 44).
- **q-4-44** (core) On the `SEQUENCE EDIT` screen, ↑/↓ selects an item and ←/→ sets it (p. 44).
- **q-4-45** (core) EDIT item SOUND BANK: sets the sound bank used for creating and playing the sequence (p. 44).
- **q-4-46** (core) EDIT item BPM: changes the tempo of the sequence (p. 44).
- **q-4-47** (core) EDIT item CLEAR deletes sounds in bulk with three scopes: `TRACK`, `BAR`, `ALL` (p. 44).
- **q-4-48** (core) CLEAR `TRACK`: deletes one measure's worth of the sound of the pad where the cursor is placed (p. 44).
- **q-4-49** (core) CLEAR `BAR`: deletes all the sounds in the measure where the cursor is placed (p. 44).
- **q-4-50** (core) CLEAR `ALL`: deletes all the sounds in the currently selected sequence (p. 44).
- **q-4-51** (core) Executing CLEAR: press `A`, then on the confirmation display (e.g. `CLEAR ALL?  OK(A)  CANCEL(B)`) press `A` to execute or `B` to cancel (p. 44).
- **q-4-52** (core) EDIT item METRONOME: ON/OFF, plus `VOLUME` (1–3) and `PATTERN` (1 or 2) (p. 44).
- **q-4-53** (core) EDIT item PRECOUNT: whether a pre-count (4 counts) sounds when creating a sequence with real-time input (p. 44).
- **q-4-54** (intro) The sequencer was once standalone hardware; today it is built into DAWs and gear like the SXC-1 (p. 45).
- **q-4-55** (intro) You can start building a song from any part — a rhythm pattern, a chord progression, or a melody (p. 45).

#### Device drill candidates
- **d-4-01** (core) **Enter and leave Sequence mode** — Long-press `A`, OK with `A` (try `B` once for cancel), confirm Sequence mode, long-press the lit `A` to return. Success: `SEQUENCE SLCT` screen with `A` flashing, then step grid (`BANK A:1  BPM:120`) with `A` lit; long-press restores Performance mode. (p. 36)
- **d-4-02** (core) **Select a sequence bank 5 or higher** — At sequence selection, change the bank number to 5 with the directional buttons, OK with `A`. Success: `BANK = 5`, sequence assigned to the current `A`–`D` button. (p. 36)
- **d-4-03** (core) **Set the number of measures to 2** — Cursor to the measure row (up), move ▲ to 2 (right), press `A`; optionally `B` to see reduction. Success: measure indicator shows "1 2". (p. 38)
- **d-4-04** (core) **Record an 8-beat drum pattern with real-time input** — Press lit `REC`, wait 4 metronome counts, tap pads 1–3 for 2 measures, let it loop, `▶/■` to end, `▶/■` to play back. Success: buttons flash while recording, cells fill white at tap timings, pattern keeps playing untapped, playback works after stop. (p. 39)
- **d-4-05** (core) **Fix a note with step input** — Cursor to the wrong cell, `B` to erase, cursor to the right cell, `A` to enter, `▶/■` to check. Success: corrected timing on playback. (p. 40)
- **d-4-06** (core) **Program the three example drum patterns** — Enter Example 1 (dance beat), 2 (16-beat), 3 (half time) on pads 1–3; optionally METRONOME OFF. Success: grid matches each chart and playback sounds like the intended groove. (p. 41)
- **d-4-07** (core) **Layer inputs one pad at a time** — Record hi-hat, then kick on a second pass, then snare. Success: all three rows filled, full pattern plays together. (p. 41)
- **d-4-08** (stretch) **Extend to 4 measures and add synth chords** — Set 4 measures, repeat the drum pattern in measures 3–4, then real-time input pads 5–8 at the top of measures 1–4. Success: "1 2 3 4" shown; one chord at each measure start; drums + chords play. (pp. 42–43)
- **d-4-09** (core) **Practice before inputting** — Play the sequence, rehearse taps (`REC` lit, `▶/■` flashing), then press `REC` to commit. Success: practice taps sound without filling cells; after `REC` (both flashing) taps are recorded. (p. 43)
- **d-4-10** (core) **Work through the SEQUENCE EDIT settings** — `EDIT`; change SOUND BANK (and back), BPM, METRONOME (ON/OFF, VOLUME 1–3, PATTERN 1/2), PRECOUNT; `EDIT` to return. Success: values change on screen, tempo audibly changes, PRECOUNT OFF removes the 4-count. (p. 44)
- **d-4-11** (stretch) **Clear sounds in bulk (TRACK / BAR / ALL)** — Place the cursor, `EDIT` → CLEAR → `TRACK` → `A`, `A`; repeat for `BAR` and `ALL`. Success: confirmation before each execute; scopes empty exactly one pad-measure, one measure, then the whole grid. (p. 44)

#### Reference-lookup candidates
- **l-4-01** (intro) Maximum sequence length and maximum number of sequences? → "What is a sequence?" box (p. 36).
- **l-4-02** (intro) Default sequence-bank assignments and reaching bank 5+? → "Where sequences are saved" (p. 36).
- **l-4-03** (intro) What does each area of the Sequence mode display mean? → annotated screen (p. 37).
- **l-4-04** (core) How do I change which sound bank a sequence uses? → SOUND BANK under the EDIT function (p. 44; pointed to from p. 38).
- **l-4-05** (intro) Default sequence tempo and where to change it? → p. 39 (BPM = 120) and the BPM item (p. 44).
- **l-4-06** (core) The sequencer's timing resolution (quantize unit)? → "About quantize" box (p. 40).
- **l-4-07** (intro) Ready-made drum pattern examples to program? → Examples 1–3 (p. 41).
- **l-4-08** (core) Real-time vs. step input — differences and when to use each? → tip callout (p. 41).
- **l-4-09** (core) The three CLEAR scopes and exactly what each deletes? → CLEAR item table (p. 44).
- **l-4-10** (intro) Metronome setting ranges and ON/OFF? → METRONOME item (p. 44).
- **l-4-11** (intro) What does PRECOUNT do and how many counts sound? → PRECOUNT item (p. 44).
- **l-4-12** (core) Can looped sounds go into a sequence? → note under step 3 (p. 43), workaround referenced to PART 4, p. 47.
- **l-4-13** (intro) Where is sequence copy/paste and bank management done more conveniently? → dedicated app notes (pp. 36, 42) referencing PART 4, pp. 59–60.

### Chapter 5 — Part: Leveling up

*Deduplicated out of this chapter (kept in the earliest chapter): resampling and chop definitions (q-3-37/38/39), the `SOUND EDIT` menu list (q-3-34; pp. 48–49 add `BPM`), "sound of the pad tapped last takes priority" and "ungrouped pads layer / grouped pads cut off" (q-2-38–40), "Beat Sync default OFF" (q-2-20), "Initialize deletes sampled data" (q-2-09), and the app pad-number long-press menu Cut/Copy/Paste/Duplicate/Clear (q-4-39). Reinforcement opportunity: re-ask those cards when their Chapter 5 procedures are drilled (d-5-06, d-5-09, d-5-14).*

#### Quiz/flashcard candidates
- **q-5-01** (core) To start sequence playback, press the `A`–`D` button holding the sequence bank together with the `▶/■` button (p. 47).
- **q-5-02** (core) During sequence playback, the assigned `A`–`D` button is lit and `▶/■` is flashing (p. 47).
- **q-5-03** (core) Before layering, select in Performance mode the bank with the sounds you want to perform in real time (p. 47).
- **q-5-04** (intro) BANK2 is stocked with EDM-style sounds: handclaps, sound effects, synth riffs, rhythm loops (p. 47).
- **q-5-05** (stretch) With Beat Sync ON, triggering a BPM-tagged loop during sequence playback makes the sample play in time with the sequence tempo (p. 47).
- **q-5-06** (stretch) Triggering the loop sample first and then playing back the sequence makes the sequence play at the sample's tempo (p. 47).
- **q-5-07** (core) To edit a sample: in Performance mode press `EDIT`, tap the pad, ↑/↓ to select an item, ←/→ to change the value (p. 48).
- **q-5-08** (intro) Samples are edited for each pad individually (p. 48).
- **q-5-09** (core) `PITCH` range: ±2 octaves in semitone steps (±24) (p. 48).
- **q-5-10** (core) Changing `PITCH` also changes the sample's playback speed (p. 48).
- **q-5-11** (core) `VOLUME` range: 0–100 (p. 48).
- **q-5-12** (core) `GROUP`: numbers 1–16 group pads; 0 = no grouping (p. 48).
- **q-5-13** (stretch) Group settings are shared across all banks — a same-group sound in a different bank can stop a sound playing in another bank (p. 48).
- **q-5-14** (core) `COLOR` sets the pad's lighting color; values: 1 Neon Yellow, 2 Orange, 3 Red, 4 Purple, 5 Blue, 6 Light Blue, 7 Green, 8 Light Green (p. 49).
- **q-5-15** (core) `BPM` shows a value auto-analyzed during recording; it can also be set manually (p. 49).
- **q-5-16** (stretch) Long-pressing the left button sets `BPM` to ---, excluding that sample from Beat Sync (p. 49).
- **q-5-17** (core) Turning a dial in EDIT mode brings up the waveform editing display (p. 49).
- **q-5-18** (core) Waveform editing changes where sample playback starts and ends (start point / end point) (p. 49).
- **q-5-19** (core) You can adjust the start and end points with both dials at once (p. 49).
- **q-5-20** (core) Adjust the start/end points while tapping the pad and listening (p. 49).
- **q-5-21** (core) To resample: in Sampling mode (press `REC` in Performance mode), select `RESAMPLING` with the directional buttons (p. 50).
- **q-5-22** (core) In `RESAMPLING`, pads available for assignment flash white; all others go out (p. 50).
- **q-5-23** (core) After selecting the copy-destination pad, it changes to lit white and the others flash; display shows `WAIT FOR SOUND / PAD COPY` (p. 50).
- **q-5-24** (core) `INPUT SELECT` during resampling: `MIC` when adding built-in-mic sound; `♪` or `USB` when adding external input or adding nothing (p. 50).
- **q-5-25** (core) Resampling starts when you tap the copy-source pad (p. 51).
- **q-5-26** (intro) During resampling, the `▶/■`, `REC`, and `ONE SHOT` buttons are lit (p. 51).
- **q-5-27** (core) Resampling ends automatically when the copy-source sample finishes sounding; the destination pad lights yellow (p. 51).
- **q-5-28** (core) When copying a looped sound, resampling ends after the sample has sounded once (p. 51).
- **q-5-29** (stretch) Resampling across banks: after selecting the destination pad, select the copy source's bank with the `A`–`D` buttons, then tap the copy-source pad (p. 51).
- **q-5-30** (stretch) For cross-bank resampling, assign the banks containing the sounds you want to copy to the `A`–`D` buttons in advance (p. 51).
- **q-5-31** (stretch) Sound input from the mic or an external input while the sample sounds is recorded mixed together with it (p. 51).
- **q-5-32** (stretch) If you apply an effect when tapping the copy-source pad, the sound is recorded with the effect applied (p. 51).
- **q-5-33** (stretch) During resampling with an effect, the effect is also applied to newly added sound (AUDIO IN or USB) (p. 51).
- **q-5-34** (core) Resampling uses: distribute one sound across pads for repeated hits, express effect ON/OFF on different pads, gather favorite sounds from multiple banks into one bank (p. 51).
- **q-5-35** (core) When sampling from an external input, the unit can analyze the phrase's BPM, split it beat by beat, and automatically assign it to multiple pads (p. 52). [Reinforces q-3-40.]
- **q-5-36** (core) Auto chop procedure: in Sampling mode select `AUTO CHOP`, select the multiple pads to assign to, then specify beats per pad (p. 52).
- **q-5-37** (core) The number of beats distributed to each pad can be 1, 2, 4, or 8 (p. 52).
- **q-5-38** (intro) The auto chop screen shows `WAIT FOR SOUND / AUTO CHOP <beats> X <pads>` (e.g. `AUTO CHOP 4 X 4`) (p. 52).
- **q-5-39** (core) In auto chop, recording starts when the phrase is input and ends automatically when analysis of beats × pads completes (4 × 4 = 4 measures) (p. 53).
- **q-5-40** (core) Start/end points of auto-chop-distributed samples can be changed with waveform editing in SOUND EDIT (p. 53).
- **q-5-41** (stretch) Each distributed sample's range can be extended forward or backward without affecting the other distributed samples (p. 53).
- **q-5-42** (stretch) Warning: an extended sample may no longer connect smoothly with the samples before and after it (p. 53).
- **q-5-43** (core) Warning: an edited sample cannot be returned to its pre-edit state — copy the original by resampling before editing (p. 53).
- **q-5-44** (intro) "Chopping" — rearranging broken-up samples or shifting their timing to create new phrases — is a technique unique to samplers (p. 53).
- **q-5-45** (stretch) Setting auto-chopped samples to the same group lets you perform as if rearranging the song itself (p. 53).
- **q-5-46** (stretch) To split at your own timing: select `AUTO TRIGGER` or `MANUAL TRIGGER`, press one empty pad, input the phrase, press the next empty pad at each split point (p. 54).
- **q-5-47** (stretch) With `MANUAL TRIGGER` recording starts when you press the first empty pad; with `AUTO TRIGGER`, when the phrase is input (p. 54).
- **q-5-48** (stretch) End a manual-split recording by pressing the last pad again or pressing `REC` (p. 54).
- **q-5-49** (core) Open the system settings by long-pressing the `EDIT` button in Performance mode (p. 55).
- **q-5-50** (core) In the system settings, select an item with ↑/↓ and change it with ←/→ (p. 55).
- **q-5-51** (stretch) `AUTO Trig Lv` sets the volume at which AUTO TRIGGER recording starts: 5 levels 1–5 (-28 dB to -12 dB in 4 dB steps); default 3 (p. 55).
- **q-5-52** (core) The smaller the `AUTO Trig Lv` value, the quieter the sound at which recording starts (p. 55).
- **q-5-53** (core) `LED Bright`: pad/button LED brightness, 5 levels 0–4 (0 = unlit); default 3 (p. 55).
- **q-5-54** (core) `Disp Bright`: display brightness, 5 levels 1–5; default 5 (p. 55).
- **q-5-55** (core) `APO Time`: 20 minutes, 1 hour, 2 hours, or off; default 20 minutes (p. 55). [Answers pointer q-1-13.]
- **q-5-56** (core) `BATTERY Type`: BAT-A (alkaline) or BAT-e (eneloop); default BAT-A (p. 55).
- **q-5-57** (intro) `POWER Supply` shows a power-cord icon on USB power, or remaining battery charge in 3 levels on batteries (p. 55).
- **q-5-58** (intro) `FW Version` displays the firmware version (view only) (p. 55).
- **q-5-59** (intro) `SERIAL No.` displays the serial number when you press the right directional button (view only) (p. 55).
- **q-5-60** (stretch) `Initialize`: press the right directional button, confirm with `A`; the unit then restarts in its factory default state (p. 55). [Effect on user sounds: q-2-09.]
- **q-5-61** (intro) The dedicated app is the iOS/Android "CASIO Sampler App" (p. 56).
- **q-5-62** (core) Connect the unit's `DATA` port to the smartphone with the included USB Type-C cable (p. 56).
- **q-5-63** (intro) If you cannot connect with the included USB Type-C cable, see the support page (p. 56).
- **q-5-64** (core) After launching the app, turn on the unit's power; the app's pads are displayed to match the state of the unit (p. 56).
- **q-5-65** (core) To assign a sample in the app: tap an empty pad, then tap "Assign Sound" (p. 57).
- **q-5-66** (intro) If the pad view is not displayed, select the Pad tab in the tab bar at the bottom (p. 57).
- **q-5-67** (core) Assign Sound source options: "Select from file" or "Select from another bank" (p. 57).
- **q-5-68** (core) "Select from file" accepts WAV, MP3, and FLAC sound files or .cswp files (p. 57).
- **q-5-69** (core) To copy a sample within a bank in the app: tap the pad, then swipe it straight to the copy destination pad (p. 58).
- **q-5-70** (core) The app can also copy a sample to another bank ("Copy to another bank") (p. 58).
- **q-5-71** (stretch) Tip: copy a single piano note and prepare multiple samples with the pitch changed in SOUND EDIT for keyboard-like pad play (p. 58).
- **q-5-72** (core) Reach the app's EDIT view: select a pad, then tap EDIT in the app or press the `EDIT` button on the unit (p. 59).
- **q-5-73** (core) In the app's EDIT view you adjust start/end points by swiping; a slider zooms the waveform for highly precise adjustment (p. 59).
- **q-5-74** (core) The app's sequence view (Sequence tab) shows tracks for all pads; enter notes by tapping cells, as on the unit (p. 59).
- **q-5-75** (core) The app can copy sequences by track or by measure (p. 59).
- **q-5-76** (core) Long-pressing a measure number in the app opens: Cut / Copy / Paste / Clear / Disable measure (p. 59). [Pad-number menu = q-4-39.]
- **q-5-77** (core) The app can copy and delete banks and sequences, download them to the smartphone, assign downloaded data to the unit, and rename banks and sequences (p. 60). [Extends q-2-06.]
- **q-5-78** (intro) Data organization is reached by tapping the icon at the top right of the screen (p. 60).
- **q-5-79** (core) The sequence management menu offers: Assign Sequence / Delete Sequence / Copy Sequence / Download / Rename (p. 60).
- **q-5-80** (intro) If a software update is available for the unit, it can be applied from the app's Home tab (p. 60).
- **q-5-81** (core) The app's settings screen (gear icon) offers: System Update, System Information, Unit Settings, Backup, Restore, System Initialization (p. 60).
- **q-5-82** (stretch) Firmware Ver. 1.1.1 and later supports MIDI IN/OUT and transmission/reception of Control Change commands (midi.md p. 1).
- **q-5-83** (stretch) MIDI channels are set with the `MIDI IN Ch.` and `MIDI OUT Ch.` items in the system settings (midi.md p. 1).
- **q-5-84** (stretch) By default, both `MIDI IN Ch.` and `MIDI OUT Ch.` are set to 1 (midi.md p. 1).
- **q-5-85** (stretch) Changed MIDI channel settings are retained even when the power is turned off (midi.md p. 1).
- **q-5-86** (intro) Press the `EDIT` button again to exit the system settings (midi.md p. 1).
- **q-5-87** (stretch) The SXC-1 transmits note numbers 36–99 and receives 36–115 (midi.md p. 2).
- **q-5-88** (stretch) The `MAIN VOL` slider transmits/receives CC 7; the `INPUT VOL` slider CC 11 (midi.md p. 3).
- **q-5-89** (stretch) The `FX1` dial is CC 16 and the `FX2` dial CC 17; buttons transmit 127 when pressed and 0 when released (midi.md p. 3).
- **q-5-90** (stretch) `INPUT SELECT` transmits CC 110 with MIC: 0, AUDIO IN: 64, USB: 127 (midi.md p. 3).
- **q-5-91** (stretch) Pad 1 of Bank A is note number 36; each bank spans 16 consecutive notes (A: 36–51, B: 52–67, C: 68–83, D: 84–99) (midi.md p. 4).
- **q-5-92** (stretch) Receive-only note numbers 100–115 trigger pads 1–16 of the current bank regardless of bank or mode (midi.md p. 4).

#### Device drill candidates
- **d-5-01** (core) **Open and navigate the system settings** — Long-press `EDIT` in Performance mode, select an item (e.g. `LED Bright`) with ↑/↓, change with ←/→, exit with `EDIT`. Success: `SYSTEM SETTING` screen shown; LED brightness visibly changes. (p. 55; exit per midi.md p. 1)
- **d-5-02** (core) **Turn Beat Sync ON** — In the system settings, set `Beat Sync` to ON, exit. Success: screen shows `Beat Sync :ON`. (p. 55) [Enables d-2-05 and d-5-03.]
- **d-5-03** (stretch) **Layer pad performance over sequence playback** — Select the performing bank (e.g. BANK2), press the sequence's `A`–`D` button + `▶/■`, tap along; with Beat Sync ON trigger a BPM-tagged loop. Success: `A` lit, `▶/■` flashing; pads play over the sequence; loops lock to the sequence tempo. (p. 47)
- **d-5-04** (core) **Edit a sample's PITCH and VOLUME in SOUND EDIT** — `EDIT`, tap the pad, change `PITCH` (±24) and `VOLUME` (0–100), tapping to compare. Success: higher pitch = faster, lower = slower; loudness changes. (p. 48)
- **d-5-05** (core) **Change a pad's lighting color** — In SOUND EDIT, step `COLOR` through 1–8 and settle on a role-matching color. Success: pad steps through the 8 colors. (p. 49)
- **d-5-06** (core) **Group two pads so they cut each other off** — Set both pads' `GROUP` to the same number, tap in turn, then set back to 0 and compare. Success: grouped = only the last-tapped sound plays; 0 = sounds layer. (p. 48) [Reinforces q-2-38–41.]
- **d-5-07** (core) **Edit a sample's start and end points (waveform editing)** — In EDIT mode, turn a dial for the waveform display, adjust start/end (both dials at once works) while tapping. Success: pad plays only the selected portion. (p. 49)
- **d-5-08** (stretch) **Set or clear a sample's BPM** — In SOUND EDIT `BPM`: note the auto value, set one manually, long-press the left button for `---`. Success: manual value shown, then `---` (excluded from Beat Sync). (p. 49)
- **d-5-09** (stretch) **Resample a pad to an empty pad within a bank** — `REC` → `RESAMPLING` → select empty destination (lit white, `WAIT FOR SOUND / PAD COPY`) → `INPUT SELECT` to `♪`/`USB` (adding nothing) → tap the copy-source pad. Success: `▶/■`/`REC`/`ONE SHOT` lit during; ends automatically; destination lights yellow and plays the copy. (pp. 50–51)
- **d-5-10** (stretch) **Resample with an effect (or across banks / adding mic sound)** — As d-5-09 through destination selection; select the source bank with `A`–`D` for cross-bank copies; apply an effect on the source tap, or set `MIC` and add your voice. Success: destination plays the sound with the effect baked in or mixed with the added input. (p. 51)
- **d-5-11** (stretch) **Auto chop a phrase across 4 pads** — External input connected and selected; `AUTO CHOP`; select pads 1–4; set beats per pad (1/2/4/8); play the phrase. Success: `WAIT FOR SOUND / AUTO CHOP 4 X 4` before input; each pad then plays one consecutive slice in order. (pp. 52–53)
- **d-5-12** (stretch) **Perform a chop with grouped pads** — Set the chopped samples to one `GROUP`, tap freely out of order; optionally trim slices (resample originals first — edits cannot be undone). Success: each tap cuts off the previous slice — a coherent rearranged phrase. (p. 53)
- **d-5-13** (stretch) **Split a sample manually at your own timing** — `AUTO TRIGGER` or `MANUAL TRIGGER`; press one empty pad; input the phrase; press the next empty pad at each split point; end with the last pad or `REC`. Success: each pad plays its own segment split at your timings. (p. 54)
- **d-5-14** (stretch) **Initialize the unit (optional, destructive)** — System settings → `Initialize` → right button → confirm `A`, after backing up (app backup, p. 60). Success: unit restarts in its factory default state. Sampled data is deleted. (p. 55)
- **d-5-15** (core) **Connect the unit to the CASIO Sampler App** — Install the app (iOS/Android), connect `DATA` port ↔ smartphone with the included USB Type-C cable, launch the app, power the unit on. Success: the app's pads match the state of the unit. (pp. 56, 60)
- **d-5-16** (core) **Assign a sample from another bank using the app** — Pad tab → empty pad → "Assign Sound" → "Select from another bank" (or "Select from file": WAV/MP3/FLAC/.cswp) → pick and Select. Success: the pad holds and plays the sample in app and on the unit. (p. 57)
- **d-5-17** (core) **Copy a sample by swiping in the app** — Tap the source pad, swipe straight to the destination (or "Copy to another bank"); optionally re-pitch the copy in SOUND EDIT. Success: "Copy complete!" and both pads contain the sample. (p. 58)
- **d-5-18** (stretch) **Edit a sequence in the app (copy/paste by track or measure)** — Sequence tab; tap cells to enter notes; long-press a pad number (Cut/Copy/Paste/Duplicate to next measure/Clear) and a measure number (Cut/Copy/Paste/Clear/Disable measure). Success: grid edits mirrored on the unit. (p. 59)
- **d-5-19** (stretch) **Set the MIDI transmit/receive channels** — System settings → `MIDI IN Ch.` / `MIDI OUT Ch.` → change with ←/→ → exit with `EDIT`. Success: new channel shown (e.g. `MIDI IN Ch. :3`) and retained after power off. Requires firmware 1.1.1+. (midi.md p. 1)

#### Reference-lookup candidates
- **l-5-01** (intro) Which COLOR number gives which pad lighting color? → COLOR table (1–8) (p. 49).
- **l-5-02** (core) Ranges and defaults of every system setting? → system settings page (p. 55).
- **l-5-03** (stretch) What dB values do `AUTO Trig Lv` levels 1–5 correspond to? → AUTO Trig Lv entry (-28 dB to -12 dB, 4 dB steps) (p. 55).
- **l-5-04** (intro) Where is the Beat Sync feature itself explained? → cross-reference from the setting to p. 18 (p. 55).
- **l-5-05** (intro) Where is applying effects during resampling explained? → cross-reference to PART 1, p. 24 (p. 51).
- **l-5-06** (intro) Where do you check the firmware version and serial number? → `FW Version` / `SERIAL No.` items (p. 55).
- **l-5-07** (intro) Where do you download the CASIO Sampler App? → QR code and URL (p. 56).
- **l-5-08** (intro) What to do if the included USB Type-C cable won't connect? → support-page note (p. 56).
- **l-5-09** (core) Which file formats can "Select from file" assign? → note in the assign procedure (WAV, MP3, FLAC, .cswp) (p. 57).
- **l-5-10** (core) What do the app's sequence long-press menus offer? → pad-number and measure-number menus (p. 59).
- **l-5-11** (core) What management operations exist for sequences in the app? → Sequence Management menu (p. 60).
- **l-5-12** (core) What does the app's settings screen offer? → settings list (p. 60).
- **l-5-13** (stretch) Which CC number corresponds to each control? → Control Change list (midi.md p. 3).
- **l-5-14** (stretch) Which MIDI note number triggers which pad in which bank? → note mapping table (midi.md p. 4).
- **l-5-15** (stretch) What MIDI messages does the SXC-1 transmit/receive at all? → MIDI implementation chart (midi.md p. 2).
- **l-5-16** (stretch) How do received FX1/FX2 dial CC values behave with the FX button ON vs OFF? → footnote *1 table (midi.md p. 3).
- **l-5-17** (stretch) Which firmware version first supported MIDI, and what changed since? → overview and revision history (midi.md pp. 1, 5).

---

## Drill dependency graph

`drill-id -> requires` (all chapters; "|" = any one of the listed alternatives suffices). Drills with no entry after `->` have no drill prerequisites.

- d-1-01 ->
- d-1-02 ->
- d-1-03 -> d-1-01 | d-1-02
- d-1-04 -> d-1-03
- d-1-05 -> d-1-03
- d-1-06 -> d-1-03
- d-2-01 -> d-1-03
- d-2-02 -> d-2-01, d-1-05 | d-1-06
- d-2-03 -> d-2-02
- d-2-04 -> d-2-03
- d-2-05 -> d-2-03, d-5-02  *(forward dependency: the Beat Sync toggle procedure is taught in Chapter 5; authors may inline the toggle steps here)*
- d-2-06 -> d-2-02
- d-2-07 -> d-2-02
- d-2-08 -> d-2-03, d-2-05
- d-2-09 -> d-2-03
- d-2-10 -> d-2-03
- d-3-01 -> d-2-01
- d-3-02 -> d-3-01
- d-3-03 -> d-3-02
- d-3-04 -> d-3-03
- d-3-05 -> d-3-03
- d-3-06 -> d-3-05
- d-3-07 -> d-3-03, d-2-06
- d-3-08 -> d-3-03
- d-3-09 -> d-3-03, d-1-06  *(external connections per "Connections", p. 8)*
- d-4-01 -> d-2-01
- d-4-02 -> d-4-01
- d-4-03 -> d-4-01
- d-4-04 -> d-4-03, d-2-02  *(pad-map knowledge)*
- d-4-05 -> d-4-04
- d-4-06 -> d-4-04
- d-4-07 -> d-4-04
- d-4-08 -> d-4-04, d-4-03
- d-4-09 -> d-4-04
- d-4-10 -> d-4-01
- d-4-11 -> d-4-04, d-4-10
- d-5-01 -> d-2-01
- d-5-02 -> d-5-01
- d-5-03 -> d-5-02, d-4-08  *(needs a sequence assigned to an `A`–`D` button)*
- d-5-04 -> d-2-02 | d-3-03  *(needs an assigned sample, preset or user)*
- d-5-05 -> d-5-04
- d-5-06 -> d-5-04
- d-5-07 -> d-5-04
- d-5-08 -> d-5-04
- d-5-09 -> d-3-02, d-3-03  *(Sampling-mode navigation plus a source sample)*
- d-5-10 -> d-5-09, d-2-09
- d-5-11 -> d-5-09, d-3-09
- d-5-12 -> d-5-06, d-5-07, d-5-11
- d-5-13 -> d-5-11 | d-3-04
- d-5-14 -> d-5-01  *(destructive; back up first via app, p. 60)*
- d-5-15 -> d-1-03
- d-5-16 -> d-5-15
- d-5-17 -> d-5-15
- d-5-18 -> d-5-15, d-4-04
- d-5-19 -> d-5-01  *(firmware 1.1.1+)*

---

## Coverage notes

- **Chapter 1 is thin by design.** Part: Preparation spans only guide-book pp. 12–13 plus the overlapping Startup Guide pp. 6 and 13; nearly everything is intro-level setup. The analyst already merged the Startup Guide overlap (power, volume, startup screen, troubleshooting), so authors must not duplicate it from the Startup Guide side.
- **Guide-book pp. 1–11 were not inventoried by any analyst** (Safety precautions pp. 3–6, Operating precautions/Connections pp. 8–9, Names of parts p. 10, Operation overview p. 11). Every chapter *assumes* Names of parts (p. 10) — pads, directional buttons, function buttons, bank select buttons, dials, sliders, jacks — and Chapters 3/5 lean on "Connections" (p. 8). If the trainer needs panel-orientation exercises, this is an uncovered gap; the citations above (l-1-07, l-1-08, l-3-02) are the only hooks into that range.
- **Startup Guide coverage is partial**: only its pp. 6 and 13 were cross-read (via Chapter 1). Its remaining pages were not inventoried.
- **midi.md is folded into Chapter 5** and yields spec-level (stretch) material only; everything MIDI requires firmware Ver. 1.1.1+, and midi.md p. 5 (revision history) yielded only a lookup.
- **Forward dependency flagged**: Beat Sync is introduced in Chapter 2 (p. 18) but the ON/OFF toggle lives in the Chapter 5 system settings (p. 55). Drills d-2-05 and d-2-08 need the toggle early — see the note in the dependency graph.
- **Destructive operations flagged by analysts**: `Initialize` erases user sounds/sampled data (pp. 16, 55; d-5-14); waveform edits cannot be undone — resample a copy first (p. 53; q-5-43); switching banks with the directional buttons during playback interrupts sound (p. 23; q-2-43).
- **Thin/low-yield page ranges**: pp. 26, 34, 45 are CREATIVE NOTE / history sidebars (technique tips and context cards only); p. 27 is a chapter opener; pp. 56–60 (app) yield app-side procedures that device-only training sessions cannot drill without a smartphone — d-5-15…d-5-18 should be marked optional-equipment.
- **Analyst file naming offset**: the source files `part-1.md`…`part-5.md` are one off from the book's own PART numbers (part-1 = unnumbered Preparation, part-5 = book PART 4). This inventory's chapter ids use file order 1–5; in-text "(see PART n …)" citations keep the book's numbering — do not "fix" either.

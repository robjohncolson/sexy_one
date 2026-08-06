# Exercise inventory — PART 4: Part: Leveling up (guide-book.md, pp. 46–61)

Source: /home/mrcolson/repos/casio-sxc1/translations/guide-book.md, "PART 4 — Part: Leveling up" (pp. 46–61), cross-read with /home/mrcolson/repos/casio-sxc1/translations/midi.md for MIDI-adjacent facts.
(Workflow slot: part-5 inventory file. Citations "(midi.md p. N)" refer to midi.md; all others to guide-book.md.)

## 1. Learning objectives

1. Layer real-time pad performance from one bank (e.g. BANK2) over playback of a sequence assigned to an `A`–`D` button, starting playback by pressing that button together with `▶/■`. (p. 47)
2. Predict the Beat Sync tempo behavior when combining a sequence with a looped sound that has a BPM set: sequence first → sample follows the sequence tempo; sample first → sequence plays at the sample's tempo. (p. 47)
3. Open SOUND EDIT for one pad (press `EDIT` in Performance mode, tap the pad) and change items with the directional buttons (↑/↓ select, ←/→ change value). (p. 48)
4. Set a sample's `PITCH` in semitone steps within ±2 octaves (±24), knowing the playback speed changes with it. (p. 48)
5. Set a sample's `VOLUME` in the range 0–100. (p. 48)
6. Group pads with the `GROUP` setting (1–16, 0 = no grouping) so that the last-tapped pad's sound stops the previous grouped sound, including across banks. (p. 48)
7. Set a pad's lighting color with the `COLOR` setting (1–8), using the preset banks as a reference for color-coding by sound content. (p. 49)
8. Set a sample's `BPM` manually, or long-press the left button to set it to --- and exclude the sample from Beat Sync. (p. 49)
9. Perform waveform editing — turn a dial in EDIT mode and adjust a sample's start point and end point while tapping the pad to listen. (p. 49)
10. Resample a pad's sample onto an empty pad (select `RESAMPLING` in Sampling mode, choose the destination pad, set `INPUT SELECT`, tap the copy-source pad), including across banks, while adding new sound from the mic or an external input, and with an effect applied. (p. 50–51)
11. Use `AUTO CHOP` to sample a phrase from an external input (AUDIO IN or USB), letting the unit analyze its BPM, split it beat by beat (1, 2, 4, or 8 beats per pad), and automatically assign it across multiple pads. (p. 52–53)
12. Split a sample at timings you choose by pressing successive empty pads during recording with `AUTO TRIGGER` or `MANUAL TRIGGER`. (p. 54)
13. Open the system settings by long-pressing the `EDIT` button in Performance mode and adjust `AUTO Trig Lv`, `Beat Sync`, `LED Bright`, `Disp Bright`, `APO Time`, `BATTERY Type`, view `POWER Supply`, `FW Version`, `SERIAL No.`, and run `Initialize` (knowing sampled data is deleted). (p. 55)
14. Connect the unit's `DATA` port to a smartphone with the included USB Type-C cable and link with the CASIO Sampler App so the app's pads match the state of the unit. (p. 56)
15. Use the CASIO Sampler App to assign samples (from files or another bank), copy samples by swiping, edit waveforms precisely, edit sequences with cut/copy/paste, and perform data organization, backup, and system updates. (p. 57–60)
16. Set the MIDI transmit/receive channels with the `MIDI IN Ch.` and `MIDI OUT Ch.` items in the system settings. (midi.md p. 1)

## 2. Quiz/flashcard candidates

### Layering pad play over sequence playback (p. 47)
- To start sequence playback, press the `A`–`D` button to which the sequence bank is assigned together with the `▶/■` button. (p. 47)
- During sequence playback, the assigned `A`–`D` button is lit and the `▶/■` button is flashing. (p. 47)
- Before layering, select in Performance mode the bank that has the sounds you want to perform in real time. (p. 47)
- BANK2 is stocked with EDM-style sounds: handclaps, sound effects, synth riffs, and rhythm loops. (p. 47)
- With Beat Sync ON, triggering a loop sample that has a BPM set during sequence playback makes the sample play in time with the sequence tempo. (p. 47)
- Triggering the loop sample first and then playing back the sequence makes the sequence play at the sample's tempo. (p. 47)

### SOUND EDIT (p. 48–49)
- To edit a sample: in Performance mode press `EDIT`, tap the pad, then use ↑/↓ to select an item and ←/→ to change the value. (p. 48)
- Samples are edited for each pad individually. (p. 48)
- The `SOUND EDIT` menu items are `PITCH`, `VOLUME`, `GROUP`, `COLOR`, and `BPM`. (p. 48–49)
- `PITCH` range: ±2 octaves in semitone steps (±24). (p. 48)
- Changing `PITCH` also changes the sample's playback speed. (p. 48)
- `VOLUME` range: 0–100. (p. 48)
- `GROUP`: numbers 1–16 group pads; 0 = no grouping. (p. 48)
- When pads are grouped, the sound of the pad tapped last takes priority (it stops the previous grouped sound). (p. 48)
- Group settings are shared across all banks — a same-group sound in a different bank can stop a sound playing in another bank. (p. 48)
- Ungrouped pads layer their sounds; grouped pads cut each other off. (p. 48)
- `COLOR` sets the pad's lighting color. (p. 49)
- COLOR values: 1 Neon Yellow, 2 Orange, 3 Red, 4 Purple, 5 Blue, 6 Light Blue, 7 Green, 8 Light Green. (p. 49)
- `BPM` shows a value for samples whose BPM was automatically analyzed during recording; it can also be set manually. (p. 49)
- Long-pressing the left button sets `BPM` to ---, which excludes that sample from Beat Sync. (p. 49)
- Turning a dial in EDIT mode brings up the waveform editing display. (p. 49)
- Waveform editing changes where sample playback starts and ends (start point / end point). (p. 49)
- You can adjust the start and end points with both dials at once. (p. 49)
- Adjust the start/end points while tapping the pad and listening to the sound. (p. 49)

### Resampling (p. 50–51)
- Sampling a saved sample again is called "resampling." (p. 50)
- Resampling copies a sample assigned to a pad to another pad; you can also add new sounds or apply effects as you do so. (p. 50)
- To resample: in Sampling mode (press `REC` in Performance mode), select `RESAMPLING` with the directional buttons. (p. 50)
- In `RESAMPLING`, pads available for assignment flash white; all others go out. (p. 50)
- After you select the copy-destination pad, it changes to lit white and the other pads flash; the display shows `WAIT FOR SOUND / PAD COPY`. (p. 50)
- `INPUT SELECT` during resampling: `MIC` when adding sound from the built-in mic; `♪` or `USB` when adding sound from an external input, or when adding nothing. (p. 50)
- Resampling starts when you tap the copy-source pad. (p. 51)
- During resampling, the `▶/■`, `REC`, and `ONE SHOT` buttons are lit. (p. 51)
- Resampling ends automatically when the copy-source sample finishes sounding; the copy-destination pad lights yellow. (p. 51)
- When copying a looped sound, resampling ends after the sample has sounded once. (p. 51)
- Resampling across banks: after selecting the copy-destination pad, select the copy source's bank with the `A`–`D` buttons, then tap the copy-source pad. (p. 51)
- For cross-bank resampling, assign the banks containing the sounds you want to copy to the `A`–`D` buttons in advance. (p. 51)
- If you input sound from the mic or an external input while the sample is sounding, the source sample and the input sound are recorded mixed together. (p. 51)
- If you apply an effect when tapping the copy-source pad, the sound is recorded with the effect applied. (p. 51)
- During resampling with an effect, the effect is also applied to newly added sound (AUDIO IN or USB). (p. 51)
- Resampling uses: distribute one sound across multiple pads for repeated hits, express effect ON/OFF on different pads, gather favorite sounds from multiple banks into one bank. (p. 51)

### Auto chop and manual splitting (p. 52–54)
- When sampling from an external input (AUDIO IN or USB), the unit can analyze the input phrase's BPM, split it beat by beat, and automatically assign it to multiple pads. (p. 52)
- Auto chop procedure: in Sampling mode select `AUTO CHOP` with the directional buttons, select the multiple pads to assign to, then specify the number of beats per pad. (p. 52)
- The number of beats to distribute to each pad can be 1, 2, 4, or 8. (p. 52)
- The auto chop screen shows `WAIT FOR SOUND / AUTO CHOP <beats> X <pads>` (e.g. `AUTO CHOP 4 X 4`). (p. 52)
- In auto chop, recording starts when the phrase is input and ends automatically when analysis of the specified beats × pads is complete (e.g. 4 beats × 4 pads = 4 measures). (p. 53)
- The start and end points of auto-chop-distributed samples can be changed with waveform editing in SOUND EDIT. (p. 53)
- Each distributed sample's range can be extended forward or backward without affecting the other distributed samples. (p. 53)
- Warning: an extended sample may no longer connect smoothly with the samples before and after it. (p. 53)
- Warning: a sample that has been edited cannot be returned to its pre-edit state — copy the original by resampling before editing. (p. 53)
- "Chopping" — rearranging broken-up samples or shifting their playback timing to create new phrases — is a technique unique to samplers. (p. 53)
- Setting auto-chopped samples to the same group lets you perform as if rearranging the song itself. (p. 53)
- To split at your own timing: in Sampling mode select `AUTO TRIGGER` or `MANUAL TRIGGER`, press one empty pad, input the phrase, then press the next empty pad at each point where you want to split. (p. 54)
- With `MANUAL TRIGGER`, recording starts when you press the first empty pad; with `AUTO TRIGGER`, recording starts when the phrase is input. (p. 54)
- End a manual-split recording by pressing the last pad again or by pressing the `REC` button. (p. 54)

### System settings (p. 55)
- Open the system settings by long-pressing the `EDIT` button in Performance mode. (p. 55)
- In the system settings, select an item with the up/down directional buttons and change it with the left/right buttons. (p. 55)
- `AUTO Trig Lv` sets the volume at which recording starts with AUTO TRIGGER: 5 levels, 1–5 (-28 dB to -12 dB in 4 dB steps); default 3. (p. 55)
- The smaller the `AUTO Trig Lv` value, the quieter the sound at which recording starts. (p. 55)
- `Beat Sync` sets automatic beat matching ON/OFF; default OFF. (p. 55)
- `LED Bright` sets pad/button LED brightness in 5 levels, 0–4 (0 = unlit); default 3. (p. 55)
- `Disp Bright` sets display brightness in 5 levels, 1–5; default 5. (p. 55)
- `APO Time` sets the Auto Power Off time: 20 minutes, 1 hour, 2 hours, or off; default 20 minutes. (p. 55)
- `BATTERY Type` switches between BAT-A (alkaline batteries) and BAT-e (eneloop); default BAT-A. (p. 55)
- `POWER Supply` shows a power-cord icon on USB power, or the remaining battery charge in 3 levels on batteries. (p. 55)
- `FW Version` displays the firmware version (view only). (p. 55)
- `SERIAL No.` displays the serial number when you press the right directional button (view only). (p. 55)
- `Initialize` returns the unit to its factory default state: press the right directional button, confirm with the `A` button; the unit then restarts. (p. 55)
- Warning: initializing deletes the data you have sampled. (p. 55)

### CASIO Sampler App (p. 56–60)
- The dedicated app is the iOS/Android "CASIO Sampler App". (p. 56)
- Connect the unit's `DATA` port to the smartphone with the included USB Type-C cable. (p. 56)
- If you cannot connect with the included USB Type-C cable, see the support page. (p. 56)
- After launching the app, turn on the unit's power; the app's pads are displayed to match the state of the unit. (p. 56)
- To assign a sample in the app: tap an empty pad, then tap "Assign Sound". (p. 57)
- If the pad view is not displayed, select the Pad tab in the tab bar at the bottom of the screen. (p. 57)
- Assign Sound source options: "Select from file" or "Select from another bank". (p. 57)
- With "Select from file", WAV, MP3, and FLAC sound files or .cswp files can be used. (p. 57)
- To copy a sample within a bank in the app: tap the pad with the sound, then swipe it straight to the copy destination pad. (p. 58)
- The app can also copy a sample to another bank ("Copy to another bank"). (p. 58)
- Tip: copy a single piano note and prepare multiple samples with the pitch changed in SOUND EDIT for keyboard-like pad play. (p. 58)
- To reach the EDIT view: select a pad, then tap EDIT in the app or press the `EDIT` button on the unit. (p. 59)
- In the app's EDIT view you adjust start/end points by swiping, and a slider zooms in on the waveform for highly precise adjustment. (p. 59)
- The app's sequence view (Sequence tab) displays tracks for all pads; you enter notes by tapping the cells, just as on the unit. (p. 59)
- The app can copy sequences by track or by measure. (p. 59)
- Long-pressing a pad number in the app's sequence view opens a menu: Cut / Copy / Paste / Duplicate to next measure / Clear. (p. 59)
- Long-pressing a measure number opens a menu: Cut / Copy / Paste / Clear / Disable measure. (p. 59)
- The app can copy and delete banks and sequences, download them to the smartphone, assign downloaded data to the unit, and rename banks and sequences. (p. 60)
- Data organization is reached by tapping the icon at the top right of the screen. (p. 60)
- The sequence management menu offers: Assign Sequence / Delete Sequence / Copy Sequence / Download / Rename. (p. 60)
- If a software update is available for the unit, it can be applied from the app's Home tab. (p. 60)
- The app's settings screen (gear icon, top right) offers: System Update, System Information, Unit Settings, Backup, Restore, System Initialization. (p. 60)

### MIDI-adjacent facts (midi.md)
- Firmware Ver. 1.1.1 and later supports MIDI IN/OUT and the transmission and reception of Control Change commands. (midi.md p. 1)
- MIDI channels are set with the `MIDI IN Ch.` and `MIDI OUT Ch.` items in the system settings (long-press `EDIT` from Performance mode). (midi.md p. 1)
- By default, both `MIDI IN Ch.` and `MIDI OUT Ch.` are set to 1. (midi.md p. 1)
- Changed MIDI channel settings are retained even when the power is turned off. (midi.md p. 1)
- Press the `EDIT` button again to exit the system settings. (midi.md p. 1)
- The SXC-1 transmits note numbers 36–99 and receives 36–115 (see note mapping). (midi.md p. 2)
- The `MAIN VOL` slider transmits/receives CC 7; the `INPUT VOL` slider CC 11. (midi.md p. 3)
- The `FX1` dial is CC 16 and the `FX2` dial CC 17; buttons transmit 127 when pressed and 0 when released. (midi.md p. 3)
- `INPUT SELECT` transmits CC 110 with MIC: 0, AUDIO IN: 64, USB: 127. (midi.md p. 3)
- Pad 1 of Bank A is note number 36; each bank spans 16 consecutive notes (A: 36–51, B: 52–67, C: 68–83, D: 84–99). (midi.md p. 4)
- Receive-only note numbers 100–115 trigger pads 1–16 of the current bank regardless of bank or mode. (midi.md p. 4)

## 3. Device drill candidates

Ordered by prerequisite; each later drill assumes the earlier ones it lists.

1. **Open and navigate the system settings** — Goal: reach the SYSTEM SETTING screen and change one value.
   Steps: (1) In Performance mode, long-press `EDIT`; (2) select an item with ↑/↓ (e.g. `LED Bright`); (3) change the value with ←/→; (4) press `EDIT` to exit.
   Success: display shows `SYSTEM SETTING` with items such as `AUTO Trig Lv:3`, `Beat Sync :ON`, `LED Bright :3`, `Disp Bright :5`; the pad/button LED brightness visibly changes as you adjust `LED Bright`. (p. 55; exit step midi.md p. 1)
   Prerequisites: Performance mode basics from Part: Pad play.

2. **Turn Beat Sync ON** — Goal: enable automatic beat matching for the layering drill.
   Steps: (1) Long-press `EDIT`; (2) move the cursor to `Beat Sync` with ↑/↓; (3) set it to ON with ←/→; (4) exit with `EDIT`.
   Success: the system settings screen shows `Beat Sync :ON`. (p. 55)
   Prerequisites: drill 1.

3. **Layer pad performance over sequence playback** — Goal: play pads in real time over a sequence you created.
   Steps: (1) In Performance mode, select the bank to perform with (e.g. BANK2); (2) press the `A`–`D` button holding the sequence (e.g. the PART 3 sequence in sequence bank 1 on `A`) together with `▶/■`; (3) tap pads along with the sequence; (4) with Beat Sync ON, trigger a loop sample with a BPM set and hear it lock to the sequence tempo.
   Success: the `A` button is lit and `▶/■` flashes during playback; your pad sounds play over the sequence, and BPM-tagged loop samples play in time with it. (p. 47)
   Prerequisites: drill 2; a sequence assigned to an `A`–`D` button (PART 3, p. 42 onward); bank selection from Part: Pad play.

4. **Edit a sample's PITCH and VOLUME in SOUND EDIT** — Goal: change how one pad's sample sounds.
   Steps: (1) In Performance mode, press `EDIT`; (2) tap the pad to edit; (3) select `PITCH` with ↑/↓ and change it with ←/→ (range ±24); (4) tap the pad to hear the change; (5) select `VOLUME` and set a value 0–100; (6) tap again to compare.
   Success: the `SOUND EDIT` screen shows the changed values; raising `PITCH` makes the sample higher and faster, lowering it makes it lower and slower; `VOLUME` audibly changes loudness. (p. 48)
   Prerequisites: an assigned sample (preset or from Part: Sampling); EDIT mode entry.

5. **Change a pad's lighting color** — Goal: color-code a pad with `COLOR`.
   Steps: (1) Press `EDIT` and tap the pad; (2) select `COLOR` with ↑/↓; (3) step through values 1–8 with ←/→; (4) settle on a color matching the sound's role, using the preset banks as reference.
   Success: the pad's lighting color changes as you step through the 8 colors (Neon Yellow, Orange, Red, Purple, Blue, Light Blue, Green, Light Green). (p. 49)
   Prerequisites: drill 4 (SOUND EDIT navigation).

6. **Group two pads so they cut each other off** — Goal: use `GROUP` to keep sounds from overlapping.
   Steps: (1) Pick two pads whose sounds overlap when tapped in turn; (2) in SOUND EDIT, set both pads' `GROUP` to the same number 1–16; (3) tap pad 1 then pad 2; (4) set `GROUP` back to 0 and compare.
   Success: when grouped, tapping the second pad stops the first pad's sound so only the last-tapped sound plays; at 0 the sounds layer. (p. 48)
   Prerequisites: drill 4.

7. **Edit a sample's start and end points (waveform editing)** — Goal: play only part of a sample.
   Steps: (1) Enter EDIT mode and select the pad; (2) turn a dial to bring up the waveform editing display; (3) adjust the start point and end point (both dials at once works); (4) tap the pad while adjusting and listen.
   Success: the waveform screen shows the two movable points, and the pad now plays only the selected portion of the sample. (p. 49)
   Prerequisites: drill 4.

8. **Set or clear a sample's BPM** — Goal: control whether a sample participates in Beat Sync.
   Steps: (1) In SOUND EDIT, select `BPM`; (2) note any auto-analyzed value; (3) set a value manually with ←/→; (4) long-press the left button to set it to ---.
   Success: the `BPM` field shows your manual value, then `---` after the long-press (the sample is now excluded from Beat Sync). (p. 49)
   Prerequisites: drill 4.

9. **Resample a pad to an empty pad within a bank** — Goal: copy a sample by resampling.
   Steps: (1) Press `REC` in Performance mode to enter Sampling mode; (2) select `RESAMPLING` with the directional buttons; (3) select an empty destination pad (it lights white, others flash; screen shows `WAIT FOR SOUND / PAD COPY`); (4) set `INPUT SELECT` to `♪` or `USB` (adding nothing); (5) tap the copy-source pad.
   Success: `▶/■`, `REC`, and `ONE SHOT` light during resampling; it ends automatically when the source finishes sounding, the destination pad lights yellow, and tapping it plays the copied sound. (p. 50–51)
   Prerequisites: Sampling mode entry and `INPUT SELECT` from Part: Sampling; an assigned source sample.

10. **Resample with an effect applied (or across banks / adding mic sound)** — Goal: transform a sample while copying it.
    Steps: (1) Set up resampling as in drill 9 through destination-pad selection; (2) for cross-bank copies, select the source bank with `A`–`D` (assign banks in advance); (3) apply an effect (PART 1, p. 24) as you tap the copy-source pad — or set `INPUT SELECT` to `MIC` and add your voice while the sample sounds; (4) let resampling end automatically.
    Success: the destination pad lights yellow and plays the source sound with the effect baked in (or mixed with the added input). (p. 51)
    Prerequisites: drill 9; effect operation from Part: Pad play (PART 1, p. 24).

11. **Auto chop a phrase across 4 pads** — Goal: sample an external phrase and have it split beat by beat automatically.
    Steps: (1) Connect an external input (AUDIO IN or USB) and set `INPUT SELECT` accordingly; (2) in Sampling mode, select `AUTO CHOP` with the directional buttons; (3) select the multiple pads to assign to (e.g. pads 1–4); (4) specify beats per pad (1, 2, 4, or 8) with ←/→; (5) play the phrase — recording starts on input and ends automatically when analysis completes.
    Success: screen shows `WAIT FOR SOUND / AUTO CHOP 4 X 4` before input; afterward each selected pad plays one consecutive slice of the phrase in order. (p. 52–53)
    Prerequisites: drill 9 (Sampling mode navigation); external-input setup from Part: Sampling.

12. **Perform a chop with grouped pads** — Goal: rearrange an auto-chopped phrase like a track remix.
    Steps: (1) Set the auto-chopped samples to the same `GROUP` number (p. 48); (2) tap the pads freely, out of order and on new timings; (3) optionally fine-tune slice start/end points with waveform editing (copy originals by resampling first — edits cannot be undone).
    Success: each tap cuts off the previous slice, so free tapping produces a coherent rearranged phrase rather than overlapping mush. (p. 53)
    Prerequisites: drills 6, 7, 11.

13. **Split a sample manually at your own timing** — Goal: distribute a phrase across pads at points you choose.
    Steps: (1) In Sampling mode, select `AUTO TRIGGER` or `MANUAL TRIGGER`; (2) press one empty pad (MANUAL TRIGGER: recording starts now); (3) input the phrase (AUTO TRIGGER: recording starts now); (4) press the next empty pad at each split point; (5) end by pressing the last pad again or pressing `REC`.
    Success: each pressed pad lights in turn during recording, and afterward each pad plays its own segment split at your chosen timings. (p. 54)
    Prerequisites: drill 11 (or Part: Sampling trigger drills).

14. **Initialize the unit (optional, destructive)** — Goal: return the unit to its factory default state.
    Steps: (1) Long-press `EDIT` to open the system settings; (2) select `Initialize`; (3) press the right directional button; (4) confirm with the `A` button — noting that sampled data will be deleted.
    Success: the unit restarts and is in its factory default state. (p. 55)
    Prerequisites: drill 1. Do only after backing up anything you want to keep (app backup, p. 60).

15. **Connect the unit to the CASIO Sampler App** — Goal: link the unit with a smartphone.
    Steps: (1) Install the CASIO Sampler App (iOS/Android) from the download page; (2) connect the unit's `DATA` port to the smartphone with the included USB Type-C cable; (3) launch the app; (4) turn on the unit's power.
    Success: the app displays the pads to match the state of the unit (home screen reports it is connected to the sampler). (p. 56, p. 60)
    Prerequisites: none beyond power-on (Part: Preparation); needed by drills 16–18.

16. **Assign a sample from another bank using the app** — Goal: fill an empty pad from the app.
    Steps: (1) In the app's Pad tab, tap an empty pad; (2) tap "Assign Sound"; (3) choose "Select from another bank" (or "Select from file" for WAV/MP3/FLAC/.cswp); (4) select the source bank, tap the sample's pad, and confirm with Select.
    Success: the previously empty pad in the app (and on the unit) now holds and plays the sample. (p. 57)
    Prerequisites: drill 15.

17. **Copy a sample by swiping in the app** — Goal: duplicate a sound within a bank.
    Steps: (1) In the app's pad view, tap the pad with the sound to copy; (2) swipe it straight to the copy destination pad (or use "Copy to another bank"); (3) confirm the copy; (4) optionally change the copy's `PITCH` in SOUND EDIT for keyboard-like play.
    Success: the app shows "Copy complete!" and both pads contain the sample. (p. 58)
    Prerequisites: drill 15.

18. **Edit a sequence in the app (copy/paste by track or measure)** — Goal: use the app's sequence view for faster editing.
    Steps: (1) Open the Sequence tab — tracks for all pads are shown; (2) enter notes by tapping cells; (3) long-press a pad number and use Cut / Copy / Paste / Duplicate to next measure / Clear; (4) long-press a measure number and use Cut / Copy / Paste / Clear / Disable measure.
    Success: notes and whole tracks/measures move as commanded in the grid, mirrored on the unit. (p. 59)
    Prerequisites: drill 15; sequence basics from Part: Sequencer.

19. **Set the MIDI transmit/receive channels** — Goal: configure `MIDI IN Ch.` and `MIDI OUT Ch.`.
    Steps: (1) From Performance mode, long-press `EDIT`; (2) scroll down to `MIDI IN Ch.` or `MIDI OUT Ch.`; (3) change the channel with the left/right buttons; (4) press `EDIT` to exit.
    Success: the SYSTEM SETTING screen shows the new channel value (e.g. `MIDI IN Ch. :3`), and the setting is retained after power off. (midi.md p. 1)
    Prerequisites: drill 1; firmware Ver. 1.1.1 or later (midi.md p. 1).

## 4. Reference-lookup candidates

- Which COLOR number gives which pad lighting color? — COLOR table (1–8, Neon Yellow through Light Green). (p. 49)
- What are the ranges and defaults of every system setting (`AUTO Trig Lv`, `Beat Sync`, `LED Bright`, `Disp Bright`, `APO Time`, `BATTERY Type`)? — System settings page. (p. 55)
- What dB values do the `AUTO Trig Lv` levels 1–5 correspond to? — AUTO Trig Lv entry (-28 dB to -12 dB in 4 dB steps). (p. 55)
- Where is the Beat Sync feature itself explained? — Cross-reference from the `Beat Sync` setting to p. 18. (p. 55)
- Where is applying effects during resampling explained? — Cross-reference to PART 1, p. 24. (p. 51)
- Where do you check the unit's firmware version and serial number? — `FW Version` and `SERIAL No.` system-setting items (view only). (p. 55)
- Where do you download the CASIO Sampler App? — QR code and URL on the app introduction page. (p. 56)
- What to do if the included USB Type-C cable won't connect? — Note pointing to the support page. (p. 56)
- Which file formats can the app's "Select from file" assign? — Note in the assign procedure (WAV, MP3, FLAC, .cswp). (p. 57)
- What edit operations do the app's sequence long-press menus offer? — Pad-number and measure-number menus. (p. 59)
- What management operations exist for sequences in the app? — Sequence Management menu (Assign / Delete / Copy / Download / Rename). (p. 60)
- What does the app's settings screen offer? — Settings list (System Update, System Information, Unit Settings, Backup, Restore, System Initialization). (p. 60)
- Which CC number corresponds to each control (sliders, dials, buttons, `INPUT SELECT`)? — Control Change list. (midi.md p. 3)
- Which MIDI note number triggers which pad in which bank? — Note mapping table. (midi.md p. 4)
- What MIDI messages does the SXC-1 transmit/receive at all? — MIDI implementation chart. (midi.md p. 2)
- How do received FX1/FX2 dial CC values behave with the FX button ON vs OFF? — Footnote *1 table under the Control Change list. (midi.md p. 3)
- Which firmware version first supported MIDI, and what changed since? — Overview and revision history. (midi.md p. 1, p. 5)

## 5. Cross-chapter dependencies

- A sequence created and assigned to sequence bank 1 in PART 3 ("Try creating a pattern that includes non-drum sounds too", p. 42 onward) is the material for the layering exercise. (p. 47)
- Sequence playback via `A`–`D` + `▶/■` and sequence-bank assignment come from Part: Sequencer. (p. 47)
- Bank selection in Performance mode and the `A`–`D` bank select buttons come from Part: Pad play. (p. 47, p. 51)
- The Beat Sync feature itself is introduced in Part: Pad play (p. 18); this chapter only toggles and exploits it. (p. 47, p. 55)
- Applying effects with the `FX1`/`FX2` buttons and dials is from Part: Pad play (PART 1, p. 24). (p. 51)
- One-shot vs. looped sounds and the `ONE SHOT`/`LOOP` buttons are from Part: Pad play. (p. 47, p. 51)
- Entering Sampling mode with `REC`, the `AUTO TRIGGER`/`MANUAL TRIGGER` settings, and empty-pad selection are from Part: Sampling. (p. 50, p. 54)
- The `INPUT SELECT` switch (`MIC`/`♪`/`USB`) and input-level setup with `INPUT VOL` are from Part: Sampling. (p. 50, p. 52)
- The `SOUND EDIT` menu was previewed in Part: Sampling (p. 33); this chapter details each item. (p. 48)
- Connections (AUDIO IN, DATA port, included USB Type-C cable) and powering on are from Part: Preparation. (p. 52, p. 56)
- The app sequence view assumes cell/track/measure concepts from Part: Sequencer. (p. 59)
- MIDI channel setup assumes the system-settings entry method taught in this chapter (long-press `EDIT`) and a firmware version per the User's Guide update procedure. (midi.md p. 1)

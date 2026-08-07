# SXC-1 live-device test protocol (M4)

This is the one piece of M4 evidence nobody but you can produce: a walk through
the trainer's new "device verification" feature with the real Casio SXC-1 in
your hands. When you perform an instructed action on the unit — press the `A`
button, tap a pad — the matching drill step should confirm itself on the page,
with no click from you.

The whole walk takes about fifteen minutes. Nothing here can break anything:
the ordinary **Confirm** button keeps working in every state, no drill can ever
be blocked by MIDI, and nothing you press on the unit leaves your browser.

Work through the sections in order — the trainer listens for exactly **one**
step at a time (the step you are currently on), so a button press meant for a
later step is ignored until you get there.

Facts about the unit below cite the English translation of Casio's MIDI
implementation document, `translations/midi.md` (called "MIDI doc" here), by
section and printed page.

At the end there is a report block to fill in and send back. **PASS** always
means "it behaved exactly as this document said it would" — including the one
step that is *supposed* to do nothing.

---

## 0. Before you start

1. **Browser.** Use desktop **Chrome** or **Edge**, in a normal window.
   **Firefox** and **Safari** will not work — they have no Web MIDI support.
   Automated or headless browser windows will not work either: measured
   2026-08-07, a headless browser exposes the MIDI API but always refuses the
   permission.
2. **Firmware.** MIDI IN/OUT and Control Change arrived in firmware
   Ver. 1.1.1 (MIDI doc §1, p. 1), and the MIDI doc itself describes
   Ver. 1.3.0 (MIDI doc §2, p. 2; revision history, p. 5). To check yours:
   long-press the `EDIT` button to enter the system settings, then scroll down
   to `FW Version` (view only) — see the User's Guide translation,
   `translations/guide-book.md`, "FW Version", p. 55. If it is below 1.1.1,
   update the firmware first (the MIDI doc's own footnote points at the User's
   Guide for that — §1, p. 1).
3. **Cable.** A USB cable that carries **data**. A charge-only cable will
   power the unit but no MIDI port will ever appear.
4. **Know where the MIDI channel lives** (you will need this in section 5):
   long-press `EDIT` to enter the system settings, scroll to `MIDI OUT Ch.`,
   change it with the left/right buttons, press `EDIT` again to exit. Both
   channels default to 1 and changed values survive power-off (MIDI doc §1.1,
   p. 1). **Leave it at 1 for now.**

---

## 1. First contact — record the port name (check 1)

1. Connect the SXC-1 to the computer over USB and turn it on. Wait for the
   logo to clear (Performance mode).
2. Open the trainer and go to the drill **Reach BANK 1**. Two ways:
   * add `#/x/pad-01/d-2-01` to the end of the trainer's web address and press
     Enter, or
   * from the home screen click **Training**, open the chapter
     **Part: Pad play**, open the deck **Banks: choosing and understanding
     them**, and click the drill **Reach BANK 1**.
3. Near the top of the drill you should see the device panel: a button
   labelled **"Enable device verification"**, the line **"Device verification
   is off."**, a channel picker showing **1**, and the line **"No device bound
   yet."**
4. Click **Enable device verification**.
5. The browser asks for permission to use your MIDI devices (the button reads
   "Requesting MIDI access…" while it waits). **Allow** it.

**Expect:** the button's label changes to **"Disable device verification"**,
the status line reads **"Device verification is on, listening on MIDI channel
1."**, and the ports line reads **"Bound MIDI input: "** followed by a name.

6. **Write that name down, exactly, character for character:**

   > Port name: `________________________________________`

   This is the single fact nobody in this project has. The name is whatever
   your operating system gives the USB device — it may mention SXC-1, CASIO,
   or neither. Today the trainer binds your unit either way (with one device
   plugged in it always will), but the exact name decides whether the
   port-matching can be tightened in a later milestone, so copy it verbatim
   into the report — do not paraphrase it.

If no name appears, jump to Troubleshooting (section 6), fix it, and come
back.

---

## 2. Drill "Reach BANK 1" — auto and manual interleaved (checks 2 and 3)

Route: `#/x/pad-01/d-2-01` — you are already on it.

Under step 1 you should now see the live line:
**"Waiting for the device: CC 80 = 127 on MIDI channel 1."**

1. Do step 1 on the unit: if a `B`–`D` button is lit, press `A`. (Press `A`
   even if it is already lit — the trainer is listening for the press itself.
   Pressing `A` transmits Control Change number 80 with value 127, and 0 when
   released — MIDI doc §4, p. 3.)

   **Expect (check 2):** the moment you press `A`, step 1's line changes to
   **"Confirmed by the device: CC 80 = 127."** and the drill advances to step
   2 — no click needed. The progress counter reads "2 / 3".

2. Do step 2 on the unit (use the directional buttons until the `SELECT BANK`
   screen reads 1), then click **Confirm** under it.

3. Do step 3 (confirm bank 1 is selected and Performance mode has returned),
   then click **Confirm** under it.

   **Expect (check 3):** steps 2 and 3 do **not** confirm themselves — you
   click Confirm for each, and the drill ends with "You've completed this
   exercise."

   Steps 2 and 3 needing your click is the **design**, not a fault: only
   step 1 of this drill carries a device hook, so the other two are yours to
   judge and confirm by hand. Mixing the two in one drill is exactly what
   this check is verifying.

---

## 3. Drill "Tap a one-shot pad and a looped pad" — the pads (checks 4 and 5)

1. Go to `#/x/pad-03/d-2-02` (or: **Training** → **Part: Pad play** → deck
   **Tap the pads, then meet Beat Sync** → drill **Tap a one-shot pad and a
   looped pad**).
2. If the panel's button reads **"Enable device verification"**, click it —
   the browser will not ask again.
3. Make sure the unit is in BANK 1 (you just did that in section 2).
4. Do step 1: tap pad `1` (the bass drum). In bank A, pad 1 transmits note
   number 36 (MIDI doc §5, p. 4).

   **Expect (check 4):** step 1's line changes to **"Confirmed by the device:
   pad 1 in bank A (note 36)."** with no click.

5. Do step 2: tap pad `13` (the rhythm loop starts). Pad 13 in bank A is note
   48 (MIDI doc §5, p. 4).

   **Expect (check 5):** **"Confirmed by the device: pad 13 in bank A (note
   48)."**

6. Do step 3: tap pad `13` again to stop the loop, and click **Confirm** —
   this step has no device hook, by the same design as before.

Stay on this page for the next section.

---

## 4. The byte capture — the most valuable two minutes (check 6)

The trainer keeps the last MIDI message it received in a hidden element on the
page, as three plain numbers. We need you to read them out once. Here is why:
the **third** number is the *velocity* byte — how hard a pad was hit. Casio's
MIDI doc records velocity as **unsupported** on this unit (§3, p. 2: Note ON
and Note OFF velocity are both "×"), so the trainer was built to accept a pad
press *whatever* the velocity byte says. Your captured number is the only way
to see what the unit really transmits, and it confirms (or refutes) that that
leniency was necessary.

Still on the `#/x/pad-03/d-2-02` page, with device verification on:

1. Tap pad `1` once.
2. Right-click anywhere on the page and choose **Inspect**. A panel opens
   showing the page's HTML (the "Elements" panel).
3. Click once inside that panel, then press **Ctrl+F** (Mac: **Cmd+F**). A
   small search bar appears at the bottom of the panel.
4. Type `sxc1-device-state` and press Enter. A line like
   `<div id="sxc1-device-state" hidden>` is highlighted.
5. Click the small triangle at the left of that line to expand it. Inside is
   one long line of text starting `{"supported":true,`.
6. Find the part that reads `"lastMessage":[` — three numbers in square
   brackets, for example `"lastMessage":[144,36,127]`.
7. **Copy the three numbers into the report verbatim** — all of them, exactly,
   whatever they are.

One caveat: the element holds the *most recent* message, and releasing a pad
may itself send one. If your third number is `0`, or the first number is
`128`, you have probably captured the pad *release* rather than the press. In
that case: press and **hold** pad `1` with one hand, re-run the search's Enter
(or just re-read the expanded text) while still holding, and copy what you see
then. If you are unsure, copy both sets of numbers into the notes — more data
is better.

Close the Inspect panel with its **X** (or press F12) when done.

---

## 5. Drill "Select and apply effects with FX1 and FX2" (checks 7, 8, 9)

Go to `#/x/pad-07/d-2-09` (or: **Training** → **Part: Pad play** → deck
**Every FX1 and FX2 effect** → drill **Select and apply effects with FX1 and
FX2**). Enable the device panel if its button offers to. Start a loop playing
(tap pad `13`) so the steps make sound.

### Step 1 is EXPECTED NOT to auto-confirm (check 7)

Step 1 asks you to turn the FX1 dial with the `FX1` button unlit, and its line
reads **"Waiting for the device: CC 16 = 0 or 127 on MIDI channel 1."** That
hook is watching the dial for the values 0 or 127 — but the dial transmits a
*continuous* value that starts at 0 and moves by one per click, stopping at
the ends of the 0–127 range (MIDI doc §4, p. 3). Turning it a few clicks sends
1, 2, 3… and never lands on the two values the hook wants.

1. Do the step: turn the FX1 dial a few clicks and watch the effect type
   change on the unit's display.

   **Expect:** the page stays on **"Waiting for the device: …"** — nothing
   confirms, no matter how far you turn.

2. Click **Confirm** under step 1 by hand.

This is a known, recorded content defect (finding **M4-F1**), already
scheduled for the next milestone. **Do not report it as a bug** — mark check 7
PASS when step 1 did *not* auto-confirm. If it ever *does* auto-confirm from a
few dial clicks, that is the surprise: describe it in the notes.

(Small cosmetic quirk, safe to ignore: once you hand-confirm step 1, the grey
line under it reads "Device verification is off — confirm manually, or turn it
on above." even though verification is still on.)

### Steps 2 and 3 — the FX buttons (checks 8 and 9)

3. Do step 2: press the `FX1` button so it lights, then turn the dial to
   change the effect strength. Pressing `FX1` transmits CC 108 = 127 (MIDI
   doc §4, p. 3).

   **Expect (check 8):** the moment `FX1` lights, step 2's line reads
   **"Confirmed by the device: CC 108 = 127."** — before you even turn the
   dial.

4. Do step 3: turn the FX2 dial with `FX2` unlit to pick a type, then press
   `FX2`. Pressing `FX2` transmits CC 109 = 127 (MIDI doc §4, p. 3).

   **Expect (check 9):** **"Confirmed by the device: CC 109 = 127."** and
   "You've completed this exercise."

---

## 6. The channel check — you can run this negative test yourself (check 10)

The likeliest real-world failure is the unit transmitting on a MIDI channel
the trainer is not listening on. The trainer detects that and offers a
one-click fix; this section proves the whole loop with your hardware.

1. Go back to `#/x/pad-01/d-2-01`. It will say "You've completed this
   exercise." — click **Restart** at the bottom of the page.

   **Expect:** step 1's line returns to **"Waiting for the device: CC 80 =
   127 on MIDI channel 1."**

2. On the unit: long-press `EDIT`, scroll to `MIDI OUT Ch.`, set it to **3**
   with the left/right buttons, press `EDIT` to exit (MIDI doc §1.1, p. 1).
3. Press the `A` button on the unit.

   **Expect:** step 1 does **not** confirm. Instead the panel's status line
   changes to **"Received MIDI on channel 3; this drill is listening on
   channel 1."** and a new button appears: **"Use channel 3"**.

4. Click **Use channel 3**.

   **Expect:** the status line reads **"Device verification is on, listening
   on MIDI channel 3."**, and the channel picker now shows 3.

5. Press `A` on the unit again.

   **Expect:** **"Confirmed by the device: CC 80 = 127."**

6. Put everything back: set the unit's `MIDI OUT Ch.` back to **1** (same
   system-settings path), and set the trainer's channel picker back to **1**.

---

## 7. Troubleshooting

One symptom per row. Whatever happens, the **Confirm** button under the
current step always works — device verification can never block a drill.

| Symptom | What to do |
|---|---|
| The ports line reads "No MIDI input detected — check the USB cable and that the unit is on." | Check the unit is powered on and the logo has cleared; swap in a USB cable you know carries data (a charge-only cable never shows a port); try another USB socket; confirm firmware is at least Ver. 1.1.1 (section 0). Then simply unplug and replug — the page notices hot-plug by itself, no reload needed. Meanwhile the Confirm button always works; no drill can be blocked by MIDI. |
| The browser never asked for permission, or the status line reads "The browser denied MIDI access. Confirm each step manually, or re-grant access in your browser's site settings and try again." | Make sure this is desktop Chrome or Edge in a normal window — Firefox and Safari have no Web MIDI, and headless or automated windows always deny it. Then click **Retry device access**; if it stays denied, click the icon at the left of the address bar, open the site settings, set MIDI to Allow, reload the page, and enable again. Meanwhile the Confirm button always works; no drill can be blocked by MIDI. |
| The page confirms a step you did not perform, or confirms on the wrong action. | Note exactly what you pressed and what confirmed, in the report's notes — that is a real finding we want. Remember the trainer listens for one step at a time, so a press meant for a later step does nothing until that step is current. Meanwhile the Confirm button always works; no drill can be blocked by MIDI. |
| Nothing happens at all when you press buttons or tap pads. | Check the status line reads "Device verification is on, listening on MIDI channel 1." (if not, enable it); check a port is bound (first row); run the channel check (section 6) in case the unit transmits on another channel — the "Received MIDI on channel …" sentence plus the offered **Use channel** button fixes that in one click. If it stays silent, finish the drill manually and say so in the notes. The Confirm button always works; no drill can be blocked by MIDI. |

---

## 8. Your report — copy, fill in, send back

PASS means "it behaved exactly as this document said it would" (so check 7 is
a PASS when d-2-09 step 1 did **not** auto-confirm). Use NA for anything you
could not attempt.

```text
SXC-1 device test report (M4)
Date:
Browser and version (Menu > Help > About):
Operating system:
Firmware version (FW Version, system settings):
Exact MIDI port name (copied from "Bound MIDI input:"):
Captured lastMessage bytes (verbatim, e.g. [144,36,127]):

 1. Port name recorded ............................................ PASS / FAIL / NA
 2. d-2-01 step 1 auto-confirmed when A was pressed ............... PASS / FAIL / NA
 3. d-2-01 steps 2 and 3 needed the Confirm click (as designed) ... PASS / FAIL / NA
 4. d-2-02 step 1 auto-confirmed on pad 1 ......................... PASS / FAIL / NA
 5. d-2-02 step 2 auto-confirmed on pad 13 ........................ PASS / FAIL / NA
 6. Byte capture copied above ..................................... PASS / FAIL / NA
 7. d-2-09 step 1 did NOT auto-confirm from the dial (expected) ... PASS / FAIL / NA
 8. d-2-09 step 2 auto-confirmed when FX1 was pressed ............. PASS / FAIL / NA
 9. d-2-09 step 3 auto-confirmed when FX2 was pressed ............. PASS / FAIL / NA
10. Channel check: mismatch shown, Use channel 3 worked, restored . PASS / FAIL / NA

Notes (anything odd, surprising, or broken — your own words):
```

---

## Appendix: element names used by the project's automated checks

You do not need these to follow the protocol; they map the words above to the
page's element ids so the repository's checks can verify this document against
the app.

* The device panel: `#ex-device`
* The enable/disable button ("Enable device verification"): `#btn-device-enable`
* The status line: `#device-status`
* The channel picker: `#sel-device-channel`
* The bound-ports line: `#device-ports`
* The one-click channel fix ("Use channel 3"): `#btn-device-use-channel`
* The hidden state element of section 4: `#sxc1-device-state` (its
  `lastMessage` field holds the captured bytes)

Routes walked: `#/x/pad-01/d-2-01`, `#/x/pad-03/d-2-02`, `#/x/pad-07/d-2-09`.

# SXC-1: About the MIDI implementation

> This document is an English translation of *SXC-1_MIDI_JA.pdf* (Japanese original by CASIO).
> Translation date: 2026-08-06.

<!-- page 1 -->

Version 1.2

2026.7.29

## 1. Overview

This document describes the MIDI functions included in this unit and their implementation. Firmware Ver. 1.1.1\* and later supports MIDI IN/OUT and the transmission and reception of Control Change commands. Settings for the transmit/receive channels for MIDI messages are made with the `MIDI IN Ch.` and `MIDI OUT Ch.` items in the unit's system settings.

\* For information on updating the unit's firmware, see the User's Guide.

### 1.1 Configuring the MIDI transmit/receive channels

This section explains the procedure for setting the transmit/receive channels on this unit.

1. From normal Performance mode, long-press the `EDIT` button to enter the system settings.

   *[Figure: screen showing the SYSTEM SETTING menu with the cursor (▶) on "AUTO Trig Lv:3", followed by "Beat Sync :OFF", "LED Bright :3", "Disp Bright :5"]*

2. Scroll with the down button to move the cursor to `MIDI IN Ch.` or `MIDI OUT Ch.`

   *[Figure: screen showing the SYSTEM SETTING menu with "LED Bright :3", "Disp Bright :5", the cursor (▶) on "MIDI IN Ch. :1", and "MIDI OUT Ch. :1"]*

3. You can change the channel with the left/right buttons.

   *[Figure: screen showing the SYSTEM SETTING menu with "LED Bright :3", "Disp Bright :5", the cursor (▶) on "MIDI IN Ch. :3", and "MIDI OUT Ch. :1"]*

4. Press the `EDIT` button again to exit the system settings.

   \* By default, both IN and OUT are set to 1. Changed setting values are retained even when the power is turned off.

<!-- page 2 -->

## 2. Product information

| | |
|---|---|
| Product name | CASIO Standalone Sampler |
| Model name | SXC-1 |
| Unit firmware version | Ver.1.3.0 |
| MIDI version | MIDI 1.0 |

## 3. MIDI implementation chart

| Function | | Transmit | Receive | Remarks |
|---|---|---|---|---|
| **Basic channel** | Default | 1 | 1 | |
| | Changed | 1–16 | 1–16, All | |
| **Mode** | Default | Mode 3 | Mode 3 | |
| | Messages | × | × | |
| | Altered | × | × | |
| **Note number** | | 36–99 | 36–115 | See Note mapping |
| **Velocity** | Note ON | × | × | |
| | Note OFF | × | × | |
| **After touch** | Key's | × | × | |
| | Channel's | × | × | |
| **Pitch bend** | | × | × | |
| **Control Change** | | ○ | ○ | See Control Change list |
| **Program Change** | | × | × | |
| **System Exclusive** | | × | × | |
| **Common** | Song Position | × | × | |
| | Song Select | × | × | |
| | Tune | × | × | |
| **Real-time messages** | Clock | × | × | |
| | Start | × | × | |
| | Continue | × | × | |
| | Stop | × | × | |
| **Other** | All Sound Off | × | × | |
| | Reset All Controllers | × | × | |
| | Local ON/OFF | × | × | |
| | All Notes Off | × | × | |
| | Active Sensing | × | × | |
| | Reset | × | × | |

Mode 1: Omni On, Poly&nbsp;&nbsp;&nbsp;&nbsp;Mode 2: Omni On, Mono&nbsp;&nbsp;&nbsp;&nbsp;○: Yes
Mode 3: Omni Off, Poly&nbsp;&nbsp;&nbsp;&nbsp;Mode 4: Omni Off, Mono&nbsp;&nbsp;&nbsp;&nbsp;×: No

<!-- page 3 -->

## 4. Control Change list

| Function | | CC No. | Transmit | Receive | Remarks |
|---|---|---|---|---|---|
| SLIDE BAR | INPUT VOL | 11 | 0-127 | 0-127 | Changes continuously from 0 at the left end to 127 at the right end |
| | MAIN VOL | 7 | 0-127 | 0-127 | Changes continuously from 0 at the left end to 127 at the right end |
| Dial | FX1 | 16 | 0-127 | \*1 | When transmitting: initial value 0, +1 for clockwise rotation, -1 for counterclockwise rotation; stops when 0-127 would be exceeded. When receiving: see \*1 |
| | FX2 | 17 | 0-127 | | |
| Bank Select | A | 80 | 0,127 | 0,127 | 127 when pressed, 0 when released |
| | B | 81 | 0,127 | 0,127 | |
| | C | 82 | 0.127 | 0,127 | |
| | D | 83 | 0,127 | 0,127 | |
| Directional | Up | 85 | 0,127 | 0,127 | 127 when pressed, 0 when released |
| | Down | 86 | 0,127 | 0,127 | |
| | Right | 87 | 0,127 | 0,127 | |
| | Left | 89 | 0,127 | 0,127 | |
| | ▶/■ | 102 | 0,127 | 0,127 | 127 when pressed, 0 when released |
| | REC | 103 | 0,127 | 0,127 | |
| | ONE SHOT | 104 | 0,127 | 0,127 | |
| | LOOP | 105 | 0,127 | 0,127 | |
| | DEL | 106 | 0,127 | 0,127 | |
| | EDIT | 107 | 0,127 | 0,127 | |
| EFFECT | FX1 | 108 | 0,127 | 0,127 | 127 when pressed, 0 when released |
| | FX2 | 109 | 0,127 | 0,127 | |
| | INPUT SWITCH | 110 | 0,64,127 | 0,64,127 | MIC:0, AUDIO IN:64, USB:127 |

\*1 The parameters and behavior when Dial FX1 and FX2 are received are as follows. The meaning of the received parameter value differs depending on whether each FX button is ON or OFF.

| | | When the FX1 button is OFF | When the FX1 button is ON |
|---|---|---|---|
| Dial | FX1 | Effect selection<br>0 : FILTER<br>1 : FLANGER<br>2 : PHASER<br>3 : BIT CRUSHER<br>4 : MASTER PAN<br>5 and up : NOP (invalid) | Parameter of the currently selected effect<br>0–100 : effect parameter value (values of 100 or more received are treated as 100)<br>- FILTER: 0 – 50 – 100<br>&nbsp;&nbsp;\* 0 : -100, 50 : 0, 100 : +100<br>&nbsp;&nbsp;(imagine it changing in steps of 2 marks)<br>- FLANGER/PHASER: 0 – 100<br>&nbsp;&nbsp;\* 0 : 0, 100 : 100<br>- BIT CRUSHER: 0 – 16<br>&nbsp;&nbsp;\* 0 : 0, 100 : 16 (divided at equal intervals)<br>- MASTER PAN: 0 – 100<br>&nbsp;&nbsp;\* 0 : L50, 50 : 0, 100 : R50 |
| | | **When the FX2 button is OFF** | **When the FX2 button is ON** |
| Dial | FX2 | Effect selection<br>0 : ROLL1<br>1 : ROLL1/2<br>2 : ROLL1/4<br>3 : ROLLPATTERN<br>4 : DELAY3/4<br>5 : DELAY3/16<br>6 and up : NOP (invalid) | Parameter of the currently selected effect<br>0–100 : effect parameter value (values of 100 or more received are treated as 100)<br>- 0 (DRY) – 100 (WET)<br>ROLL types: 0–100 (0 : 0, 100 : 100)<br>DELAY types: 0–100 (0 : 0, 100 : 100) |

<!-- page 4 -->

## 5. Note mapping

| Pad | Bank A | Bank B | Bank C | Bank D | Active (receive only)\* |
|---|---|---|---|---|---|
| Pad 1 | 36 | 52 | 68 | 84 | 100 |
| Pad 2 | 37 | 53 | 68 | 85 | 101 |
| Pad 3 | 38 | 54 | 70 | 86 | 102 |
| Pad 4 | 39 | 55 | 71 | 87 | 103 |
| Pad 5 | 40 | 56 | 72 | 88 | 104 |
| Pad 6 | 41 | 57 | 73 | 89 | 105 |
| Pad 7 | 42 | 58 | 74 | 90 | 106 |
| Pad 8 | 43 | 59 | 75 | 91 | 107 |
| Pad 9 | 44 | 60 | 76 | 92 | 108 |
| Pad 10 | 45 | 61 | 77 | 93 | 109 |
| Pad 11 | 46 | 62 | 78 | 94 | 110 |
| Pad 12 | 47 | 63 | 79 | 95 | 111 |
| Pad 13 | 48 | 64 | 80 | 96 | 112 |
| Pad 14 | 49 | 65 | 81 | 97 | 113 |
| Pad 15 | 50 | 66 | 82 | 98 | 114 |
| Pad 16 | 51 | 67 | 83 | 99 | 115 |

\* Regardless of the bank or the unit's mode, these behave the same as pressing the current pad. (Example: 100 → Pad 1)

<!-- page 5 -->

## Revision history

This section lists the revision history of this document.

| Version | Revision date | Supported FW version | Revisions |
|---|---|---|---|
| Version 1.0 | 2026/5/28 | 1.1.1 | First edition published<br>- Support for MIDI IN/OUT (NOTE ON/OFF, Control Change) |
| Version 1.1 | 2026/6/22 | 1.2.0 | - Support for receiving Control Change from the Dials (FX1, FX2)<br>&nbsp;&nbsp;For details, see 4. Control Change list |
| Version 1.2 | 2026/7/29 | 1.3.0 | - Control Change list revised due to the addition of MASTER PAN to FX1<br>&nbsp;&nbsp;For details, see 4. Control Change list |

<!-- page 6 -->

*[Figure: CASIO logo with registered trademark symbol, centered on an otherwise blank page]*

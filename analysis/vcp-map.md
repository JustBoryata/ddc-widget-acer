# Acer Display Widget: VCP code map

Interoperability notes for Acer monitors' DDC/CI interface. Derived from analysing how Acer Display Widget 1.0.2.0 (Windows) talks to the monitor and verified on an XV275U P3. No Acer code or binaries are included in this repository.
All features go through the standard Windows DDC/CI API (dxva2 `SetVCPFeature` / `GetVCPFeatureAndVCPFeatureReply`). No custom USB or driver protocol is used.

## Monitor detection

- `acer_query_monitor_model_name`: treats any monitor whose device ID contains vendor `ACR` as an Acer monitor. There's no hard-coded model list.
- `0xE4` (read): model category. `0xE3` (read): supported display modes / profiles.

## Standard MCCS codes

| Feature | VCP | Notes |
|---|---|---|
| Brightness | 0x10 | via SetMonitorBrightness |
| Contrast | 0x12 | via SetMonitorContrast |
| R / G / B gain | 0x16 / 0x18 / 0x1A | via SetMonitorRedGreenOrBlueGain |
| Input source | 0x60 | Mac currently reads 15 (DP-1, i.e. USB-C) |
| Speaker volume | 0x62 | |
| Saturation | set 0x87, get 0x8A | Acer code uses different codes for set and get (as decompiled) |
| Power mode | 0xD6 | |
| Factory reset | 0x04 = 1 | destructive, so only with confirmation |

## Acer direct codes

| Feature | VCP |
|---|---|
| Display mode / profile | 0xE2 (get/set), 0xE3 supported list |
| Black Boost | 0xE5 |
| Calibration mode | 0xE9 |
| Color space | 0xEA |

## Acer indexed registers (write index to A, then read/write value at B)

Set = `A <- index`, then `B <- value`. Get = `A <- index`, then read `B`.

### Bank E0 -> E1
| idx | Feature |
|---|---|
| 0 | Key lock |
| 1 | Power key |
| 2 | Power indicator (LED) |
| 3 | Serial number (read) |
| 4 | Overdrive (OD) |
| 5 | Refresh rate |
| 6 | Aim point type (crosshair) |
| 7 | ColorSense |
| 8 | Lighting selection |
| 9 | LightSense |
| 10 | ProxiSense |
| 11 | Firmware version (read) |

### Bank E7 -> E8
| idx | Feature |
|---|---|
| 0 | Blue light filter |
| 1 | Gamma |
| 2 | Color temperature |
| 3 | USB port select |

### Bank EB -> EC
| idx | Feature |
|---|---|
| 0 | FreeSync |
| 1 | VRB |
| 2 | Ultra Low Latency |
| 3 | Advanced Black Boost |
| 4 | Aim point color |
| 5 | Sniper ratio |
| 6 | Sniper size |
| 7 | Sniper night vision |
| 8 | Ultra-wide mode |
| 9 | Ultra-wide screen position |
| 10 / 15 | Timer / Wide mode. Acer's code swaps these between set and get (Set_Timer=10, Get_Timer=15; Set_WideMode=15, Get_WideMode=10). Verify on hardware. |
| 11 | Adaptive dimming |

### Bank ED -> EE
| idx | Feature |
|---|---|
| 0 | Image retention refresh |
| 1 | Pixel centering |
| 2 | Static image upkeep |
| 3 | Edge protection |
| 4 | AI protection |

## Value meanings

**Input source (0x60):** 1 VGA, 15 DP1, 16 DP2, 17 HDMI1, 18 HDMI2, 19 USB-C. These codes plus 10 (22, 25 to 29) select inputs on the second picture when two inputs are shown side by side. The Mac currently reads 15.

**Display mode (0xE2):** 0 User, 1 Standard, 2 ECO, 3 Graphics, 4 Movie, 5 Game 1, 6 Game 2, 7 Game 3, 8 AdobeRGB, 9 sRGB, 10 REC709, 11 HDR, 12 Reading, 13 Dark room, 14 DCI-P3, 15 CAD/CAM.

**Overdrive (E0 idx 4):** 0 Off, 1 Normal, 2 Extreme.

**Gamma (E7 idx 1):** 0 = 1.8, 1 = 2.0, 2 = 2.2, 3 = 2.4, 4 = 2.6.

**Color temperature (E7 idx 2):** 0 Warm, 1 Normal, 2 Cool, 3 Bluelight, 4 User (then R/G/B gain sliders apply).

**Blue light filter (E7 idx 0):** 0 Off, 1 = 80%, 2 = 70%, 3 = 60%, 4 = 50%.

**Refresh rate (E0 idx 5):** 0 / 1 (normal / overclocked, presumably).

**Key lock / power key / power indicator:** 0 / 1. **Power mode (0xD6):** 1 = on, 5 = off (standard MCCS).

**USB port select (E7 idx 3):** 0 to 3.

**Sliders:** brightness, contrast, R/G/B gain, saturation, volume and Black Boost use the slider value directly. Read the maximum from the monitor (the reply to a get includes it).

**Game features** (FreeSync, VRB, Ultra Low Latency, Adv. Black Boost, aim point, Sniper, Timer, wide mode): the UI passes variables, not literals. They're most likely 0 = off / 1 = on, with an index for multi-choice options. Verify on hardware.

## How the widget decides what's supported

`AcerMCCS_API.cs` parses the monitor's MCCS **capabilities string**:
- `60(...)`: which inputs exist (0F to DP1, 11 to HDMI1, 13 to USB-C, ...)
- `E0(...)`, `E7(...)`, `EB(...)`: which indexes exist in each Acer bank (e.g. `EB(... 00 ...)` means FreeSync is supported)

So our app should read the capabilities string the same way and show only the supported controls.

## XV275U P3: what the monitor actually supports

Read with `app/.build/debug/acer-ddc caps` on 2026-10-13 (raw string in `xv275u-p3-capabilities.txt`). MCCS 2.1.

| Area | Capabilities | Meaning |
|---|---|---|
| Inputs `60(11 12 0F)` | HDMI1, HDMI2, DP1 | No separate USB-C code, so USB-C shows as **DP1 (15)**, which matches the current reading. |
| Acer bank E0 `(00 04 05 06)` | Key lock, Overdrive, Refresh rate, Aim point | E1 values `00 01 02`, e.g. OD Off/Normal/Extreme |
| Acer bank E7 `(00 01 02)` | Blue light, Gamma, Color temp | E8 values `00 01 02`. Note this is narrower than the widget's 0–4 range, so verify. |
| E5 | Black Boost | |
| ED | Image retention / pixel-care bank | no index list given |
| D6 `(01 04 05)` | Power mode on / standby / off | |
| 14 `(05 06 08 0B)` | Standard color preset: 6500K, 7500K, 9300K, User 1 | |
| 10, 12, 16/18/1A, 62, 8A-ish | Brightness, contrast, RGB gain, volume | Saturation 0x8A isn't listed, so treat it as unsupported. |
| **EB bank absent** | No FreeSync / VRB / Ultra Low Latency / Sniper / Adv. Black Boost over DDC | |

Live reads: brightness 0x10 = 50/100, input 0x60 = 15, display mode 0xE2 = 0 (User, max 27), 0xE3 = 452 (0x1C4, a bitmask of supported modes; the widget treats bit *n* as mode *n*: bits 2, 6, 7, 8), 0xE4 = 257 (0x0101).

## Verified on hardware (2026-10-13)

Indexed reads give stable results across 4 rounds:

| Setting | Read | Meaning |
|---|---|---|
| E0 idx 0 Key lock | 0 | off |
| E0 idx 4 Overdrive | 2 | Extreme |
| E0 idx 5 Refresh rate | 0 | normal (no overclock) |
| E0 idx 6 Aim point | 0 | off |
| E7 idx 0 Blue light | 0 | off |
| E7 idx 1 Gamma | 2 | 2.2 |
| E7 idx 2 Color temp | 0 | Warm |
| E5 Black Boost | 5 / 10 | |
| 14 Color preset | 5 | 6500K |

Write test: brightness 50 to 60 (read back 60) to 50 (read back 50). Writes work.

### Timing rules (XV275U P3 over USB-C, M1)

- Send every request **twice**, 10 ms apart. A single request gets the null reply `6E 80 BE`.
- After a Set that changes a setting, wait **~0.5 s** before the next request. Sooner gets a null reply or a garbage value, and can corrupt the next index select.
- Selecting an Acer index needs ~150 ms before reading or writing its value. If the read fails, redo the select too.
- Acer's DLL also sleeps between the select and the read (`VCP_code_DelayTime`, set at runtime).

## Still to verify on hardware

- The display-mode bitmask in 0xE3 against the modes in the monitor's on-screen menu
- Whether blue light, gamma and color temp accept values above 2 (the capabilities list only 00 to 02)
- How the monitor's HDR setting is exposed (display mode 11 "HDR" in the widget, but 0xE3 bit 11 isn't set)

## HDR and local dimming (2026-10-13)

- **macOS HDR**: the private MonitorPanel `MPDisplay.preferHDRModes` (the System Settings switch) toggles it, and SkyLight `SLSDisplayIsHDRModeEnabled` reads the live state. Both verified on the XV275U P3.
- **Monitor HDR mode**: the monitor stays in its current mode when it receives an HDR signal. The app writes display mode 11 (HDR) itself. 0xE3 bit 2 (HDR supported) is set on this model.
- **Local dimming (Off/Low/Average/Fast, Gaming menu): not controllable over DDC on this model.**
  - Acer maps it only as Adaptive Dimming (EB[0x0B]). The monitor answers "unsupported" and ignores writes.
  - Plain VCP scans with dimming Fast vs Off are identical (`scan-dimming-*.txt`). ED and the unlisted E0 indexes don't track it either.
  - It's a single global setting: changing it in Gaming mode also changes it in User mode, so per-mode presets can't stand in for it.
  - Acer's USB HID channel (042E:AC11) is for sensors only. The Mac is also connected through a USB-C to DP cable, so there's no USB path to the monitor.
- **Aim point is E0[06]** (max 3) on this model. A dropped index select once wrote to it, so indexed writes now wake the bus, send the select twice and read back to verify.
- 0xE2 sometimes reads 0x0100 or 0xE200 for mode 0. The app keeps the low byte when a value exceeds the max.

### Local dimming workaround (verified 2026-10-13)

The monitor's **HDR mode (0xE2 = 11) turns local dimming on**, and **User mode (0xE2 = 0) turns it off**. The user confirmed both visually; the OSD's Local Dimming item doesn't update. The app's Local Dimming toggle switches to HDR mode and back to the mode it was in before, and the HDR toggle does the same alongside macOS HDR. The level (Low/Average/Fast) still can't be chosen over DDC.

Plain VCP writes can be dropped too (a 0xE2 write was ignored once), so the app reads back every write and retries.

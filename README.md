# disintegrate

*slowly disintegrating audio loops for monome norns*

---

A single audio loop ages in real time, accumulating the sonic signatures of physical deterioration — oxide loss, high-frequency rolloff, wow and flutter. It does not simply fade. It decays toward a ghost of itself.

Inspired by William Basinski's [Disintegration Loops](https://en.wikipedia.org/wiki/The_Disintegration_Loops) — recordings made as twenty-year-old tapes shed their magnetic oxide in real time, the loops rewriting themselves with each pass until they became something else entirely.

---

## requirements

- norns
- audio file (WAV, AIFF — must be 48kHz for accurate playback)

---

## install

via maiden: `;install https://github.com/mattbx/disintegrate`

or: SSH into norns and clone into `/home/we/dust/code/`

---

## controls

| control | action |
|---|---|
| **E1** | half-life — how long until the loop reaches half amplitude (minutes) |
| **E2** | filter floor — spectral destination: where the LP cutoff settles at full decay |
| **E3** | varispeed — playback rate |
| **K2** | load file (if none loaded) / toggle decay on/off |
| **K3** | freeze / unfreeze decay state |
| **K1+K2** | reset decay to pristine |
| **K1+K3** | open file picker (reload) |

---

## how it works

softcut's `pre_level` is a per-pass amplitude multiplier. Each time the write head sweeps over the buffer, existing audio is multiplied by this value. At `pre=1.0` nothing changes. As `pre` descends, the loop slowly erases itself.

The decay is triggered once per loop cycle (locked to the actual loop boundary, not a fixed timer). The step size is derived from the **half-life** parameter:

```
step_multiplier = 0.5 ^ (loop_length / half_life_in_seconds)
```

This means the half-life is consistent regardless of loop length — a 2-second loop and a 30-second loop feel like they decay at the same perceptual rate.

The `pre_filter` LP cutoff is coupled to the `pre_level`: as the loop decays, the filter descends from bright (16kHz) toward the **filter floor** parameter. High frequencies erode first, exactly like magnetic oxide loss on physical tape.

The **decay floor** parameter sets the ghost state — the loop decays *toward* this value, not past it. At the default (0.05), the loop becomes barely-there rather than silence.

---

## params

### DISINTEGRATE
| param | description | range |
|---|---|---|
| half-life | time to reach half amplitude | 0.5 – 120 min |
| decay floor | pre_level floor (ghost state) | 0.0 – 0.5 |
| filter floor | LP cutoff destination | 200 – 6000 Hz |
| filter Q | resonance of pre filter | 0.1 – 2.0 |
| flutter depth | wow/flutter LFO depth | 0.0 – 0.04 |
| flutter rate | wow/flutter LFO rate | 0.1 – 8 Hz |
| varispeed | base playback rate | 0.25 – 2.0× |
| output level | output amplitude | 0.0 – 1.0 |

### LOOP
| param | description |
|---|---|
| loop start | start of playback window (seconds) |
| loop end | end of playback window (seconds) |

---

## display

The waveform display shows the current state of the buffer in real time. As `pre_level` descends, the waveform dims and shrinks — the visual decay mirrors the sonic decay. The horizontal bar below the status label shows how much of the loop remains before reaching the ghost state.

---

## screen

```
hold          ───────────────────── t½ 20m
━━━━━━━━━━━━━━━━░░░░░░░░░          500Hz
5.0s
         ┌─────────────────────┐
         │  ▄▄▄  ▄▄ ▄▄ ▄▄▄ ▄▄ │  waveform
         └─────────────────────┘
```

---

## roadmap

- **v0.2** — live recording input, dropout probability (random amplitude zeroing), noise floor accumulation
- **v0.3** — multiple decay modes (scatter, consume/feedback, crumble)
- **v0.4** — grid support, second voice at offset decay rate
- **v0.5** — tape disintegration screen graphic

---

## credits

Written from scratch using the [softcut studies](https://github.com/monome/softcut-studies) as reference — particularly studies 4 (rec/dub), 5 (filters), 6 (routing), 7 (files), and 8 (waveform).

Informed by studying: [cranes](https://github.com/monome/cranes), [ndls](https://github.com/andr-ew/ndls), [samsara](https://github.com/21echoes/samsara).

---

*v0.1.0 — alpha*

-- disintegrate.lua
-- slowly disintegrating audio loops for monome norns
-- v0.1.1 @mattbx
--
-- inspired by william basinski's disintegration loops:
-- a single loop ages in real time, accumulating the sonic
-- signatures of physical deterioration. it does not fade —
-- it decays toward a ghost of itself.
--
-- E1: decay rate (half-life in minutes)
-- E2: filter floor (spectral destination)
-- E3: varispeed
--
-- K2: load file / toggle decay
-- K3: freeze / unfreeze
-- K1 (hold) + K2: reset decay to full
-- K1 (hold) + K3: open file picker
--
-- params: full control over all decay parameters + PSET save

-- engine.name = "none"  -- softcut only, no supercollider engine

-- ============================================================
-- REQUIRES
-- ============================================================

local fileselect = require "fileselect"

-- ============================================================
-- CONSTANTS
-- ============================================================

local VOICE       = 1      -- softcut voice index
local BUF         = 1      -- softcut buffer index
local SCREEN_W    = 128
local FC_MAX      = 16000  -- max filter cutoff (Hz) — top of audible range
local FC_FLOOR    = 200    -- absolute minimum filter floor (Hz)
local WAVE_CENTRE = 48     -- y centre of waveform on screen
local WAVE_AMP    = 14     -- max waveform amplitude in pixels

-- ============================================================
-- STATE
-- ============================================================

local loaded        = false  -- has a file been loaded?
local decaying      = false  -- is decay active?
local frozen        = false  -- is decay paused (freeze)?
local k1_held       = false  -- K1 modifier held?

-- decay state (all start at "pristine")
local pre           = 1.0    -- current pre_level (1.0 = pristine, floor = ghost)
local filter_fc     = FC_MAX -- current LP cutoff (Hz)
local flutter_phase = 0.0    -- LFO phase accumulator [0.0, 1.0)

-- loop geometry
local loop_start    = 0.0
local loop_end      = 5.0

-- display data
local waveform      = {}     -- rendered buffer floats [-1, 1]
local playhead_pos  = 0.0    -- current playhead position (seconds)
local prev_pos      = nil    -- previous phase poll position (for crossing detection)

-- metros
local flutter_metro = nil

-- ============================================================
-- PARAMS
-- ============================================================

local function setup_params()
  params:add_separator("DISINTEGRATE")

  -- ---- decay --------------------------------------------------

  -- decay rate: expressed as "half-life" — the time (in minutes)
  -- for the loop to decay from full (pre=1.0) to half amplitude.
  -- normalises automatically for loop length, so a 2s loop and a
  -- 30s loop with the same half-life decay at the same perceptual rate.
  params:add_control("decay_rate", "half-life",
    controlspec.new(0.5, 120.0, "exp", 0.1, 20.0, "min"))

  -- decay floor: the pre_level the loop decays *toward* (not past).
  -- 0.0 = total silence. 0.05 = ghost (barely there).
  params:add_control("decay_floor", "decay floor",
    controlspec.new(0.0, 0.5, "lin", 0.01, 0.05, ""))

  -- ---- filter / oxide loss ------------------------------------

  -- filter floor: where the LP cutoff descends to by the time
  -- pre reaches the decay floor. start state is always FC_MAX.
  -- lower = more muffled ghost. higher = ghost retains more air.
  params:add_control("filter_floor", "filter floor",
    controlspec.new(FC_FLOOR, 6000, "exp", 10, 500, "Hz"))

  -- filter Q (resonance) — constant across decay
  params:add_control("filter_q", "filter Q",
    controlspec.new(0.1, 2.0, "lin", 0.05, 0.5, ""))
  params:set_action("filter_q", function(v)
    softcut.pre_filter_rq(VOICE, v)
  end)

  -- ---- wow / flutter ------------------------------------------

  params:add_control("flutter_depth", "flutter depth",
    controlspec.new(0.0, 0.04, "lin", 0.001, 0.005, ""))

  params:add_control("flutter_rate", "flutter rate",
    controlspec.new(0.1, 8.0, "exp", 0.05, 1.5, "Hz"))

  -- ---- varispeed ----------------------------------------------

  params:add_control("base_rate", "varispeed",
    controlspec.new(0.25, 2.0, "exp", 0.01, 1.0, ""))

  -- ---- output -------------------------------------------------

  params:add_control("output_level", "output level",
    controlspec.new(0.0, 1.0, "lin", 0.01, 0.85, ""))
  params:set_action("output_level", function(v)
    softcut.level(VOICE, v)
  end)

  -- ---- loop ---------------------------------------------------

  params:add_separator("LOOP")

  params:add_control("loop_start_param", "loop start",
    controlspec.new(0.0, 300.0, "lin", 0.01, 0.0, "s"))
  params:set_action("loop_start_param", function(v)
    loop_start = util.clamp(v, 0, loop_end - 0.1)
    softcut.loop_start(VOICE, loop_start)
    softcut.position(VOICE, loop_start)
  end)

  params:add_control("loop_end_param", "loop end",
    controlspec.new(0.1, 300.0, "lin", 0.01, 5.0, "s"))
  params:set_action("loop_end_param", function(v)
    loop_end = math.max(v, loop_start + 0.1)
    softcut.loop_end(VOICE, loop_end)
  end)

  -- ---- file ---------------------------------------------------

  params:add_separator("FILE")

  params:add_trigger("load_file", "load file")
  params:set_action("load_file", function()
    open_file_picker()
  end)
end

-- ============================================================
-- SOFTCUT SETUP
-- ============================================================

local function setup_softcut()
  softcut.enable(VOICE, 1)
  softcut.buffer(VOICE, BUF)
  softcut.level(VOICE, 0.85)  -- default; params:bang() will correct from saved PSET
  softcut.rate(VOICE, 1.0)
  softcut.loop(VOICE, 1)
  softcut.loop_start(VOICE, loop_start)
  softcut.loop_end(VOICE, loop_end)
  softcut.position(VOICE, loop_start)
  softcut.play(VOICE, 1)

  -- IMPORTANT: rec must be ENABLED (=1) for the write head to run.
  -- The write head is what applies pre_level on each pass — without it,
  -- pre_level has no effect and the loop never decays.
  -- We keep rec_level=0.0 so no new audio is written, only the
  -- pre_level multiplication happens on each pass.
  softcut.rec(VOICE, 1)
  softcut.rec_level(VOICE, 0.0)
  softcut.pre_level(VOICE, 1.0)  -- start pristine: preserve everything

  -- pre filter: LP tap only, start at top of audible range.
  -- this filter shapes what gets PRESERVED on each write pass.
  -- as filter_fc descends, high frequencies are lost first — oxide loss.
  softcut.pre_filter_dry(VOICE, 0.0)
  softcut.pre_filter_lp(VOICE, 1.0)
  softcut.pre_filter_hp(VOICE, 0.0)
  softcut.pre_filter_bp(VOICE, 0.0)
  softcut.pre_filter_br(VOICE, 0.0)
  softcut.pre_filter_fc(VOICE, filter_fc)
  softcut.pre_filter_rq(VOICE, 0.5)  -- default; params:bang() will correct

  -- post filter: flat / dry (no output colouring)
  softcut.post_filter_dry(VOICE, 1.0)
  softcut.post_filter_lp(VOICE, 0.0)

  -- route audio input to softcut (available for future live recording)
  audio.level_adc_cut(1)

  -- phase poll: fires ~20x per second, gives us playhead position.
  -- used to: update display, detect loop crossing for decay step.
  softcut.phase_quant(VOICE, 0.05)
  softcut.event_phase(on_phase)
  softcut.poll_start_phase()

  -- waveform render callback
  softcut.event_render(on_render)
end

-- ============================================================
-- FILE LOADING
-- ============================================================

local function get_file_duration(filepath)
  -- use soxi (part of SoX, installed on norns) to read duration from file metadata
  local handle = io.popen("soxi -D \"" .. filepath .. "\" 2>/dev/null")
  if handle then
    local result = handle:read("*n")
    handle:close()
    if result and result > 0 then
      return result
    end
  end
  return nil
end

local function on_file_loaded(duration)
  -- called ~0.5s after buffer_read_mono to allow async read to complete
  local dur  = duration or 5.0
  loop_start = 0.0
  loop_end   = dur

  -- update params to match file
  params:set("loop_start_param", loop_start)
  params:set("loop_end_param",   loop_end)

  softcut.loop_start(VOICE, loop_start)
  softcut.loop_end(VOICE,   loop_end)
  softcut.position(VOICE,   loop_start)

  -- reset decay state to pristine
  pre       = 1.0
  filter_fc = FC_MAX
  decaying  = false
  frozen    = false
  loaded    = true

  softcut.pre_level(VOICE, pre)
  softcut.pre_filter_fc(VOICE, filter_fc)

  -- write head stays on (rec=1, rec_level=0) — no change needed

  -- request initial waveform render
  request_waveform()
  redraw()
end

function open_file_picker()
  fileselect.enter("/home/we/dust/audio", function(filepath)
    if filepath == "cancel" then return end

    -- get duration from file metadata before loading
    local dur = get_file_duration(filepath)

    -- clear buffer then load file (async operation)
    softcut.buffer_clear()
    softcut.buffer_read_mono(filepath, 0, 0, -1, 1, BUF)

    -- wait 0.5s for async read to complete, then initialise loop points.
    -- conservative delay — fine for files up to ~5 minutes.
    local t       = metro.init()
    t.time        = 0.5
    t.count       = 1
    t.event       = function() on_file_loaded(dur) end
    t:start()
  end)
end

-- ============================================================
-- DECAY ENGINE
-- ============================================================
--
-- Core mechanism: softcut's pre_level is a per-pass amplitude multiplier.
-- Each time the write head sweeps the buffer, existing audio is scaled by
-- pre_level. At pre=1.0 nothing changes. At pre<1.0 the loop erases itself.
--
-- One decay step fires per loop cycle (detected via phase poll loop crossing).
-- The step multiplier derives from the "half-life" param:
--
--   step_mult = 0.5 ^ (loop_length_sec / half_life_sec)
--
-- This normalises for loop length — perceptual decay speed is consistent
-- regardless of whether the loop is 2s or 30s long.
--
-- Filter cutoff is coupled to pre_level:
--   pre=1.0  → filter_fc = FC_MAX  (bright, pristine)
--   pre=floor → filter_fc = filter_floor (muffled ghost)
-- Emulates oxide loss: high frequencies erode first.

local function compute_step_multiplier()
  local loop_len      = loop_end - loop_start
  local half_life_sec = params:get("decay_rate") * 60.0
  return math.pow(0.5, loop_len / half_life_sec)
end

local function update_filter_from_pre()
  local floor    = params:get("decay_floor")
  local fc_floor = params:get("filter_floor")

  -- normalised position: 1.0 = pristine, 0.0 = at floor
  local t = (pre - floor) / math.max(0.001, 1.0 - floor)
  t = util.clamp(t, 0.0, 1.0)

  -- exponential interpolation (we hear frequency logarithmically,
  -- so this makes the descent feel perceptually even)
  filter_fc = fc_floor * math.pow(FC_MAX / fc_floor, t)
  softcut.pre_filter_fc(VOICE, filter_fc)
end

local function do_decay_step()
  if not decaying or frozen or not loaded then return end

  local floor = params:get("decay_floor")

  -- already at floor: nothing more to do, decay naturally completes
  if pre <= floor + 0.001 then
    pre = floor
    softcut.pre_level(VOICE, pre)
    softcut.pre_filter_fc(VOICE, params:get("filter_floor"))
    decaying = false
    return
  end

  -- apply step multiplier
  local mult = compute_step_multiplier()
  pre        = math.max(floor, pre * mult)
  softcut.pre_level(VOICE, pre)

  -- keep filter coupled to pre
  update_filter_from_pre()
end

local function reset_decay()
  pre       = 1.0
  filter_fc = FC_MAX
  decaying  = false
  frozen    = false
  softcut.pre_level(VOICE, pre)
  softcut.pre_filter_fc(VOICE, filter_fc)
  redraw()
end

-- ============================================================
-- FLUTTER LFO
-- ============================================================
--
-- Sine LFO modulating playback rate around the base varispeed value.
-- Very low depth = gentle wow (analogue tape drift).
-- Higher depth = obvious flutter (damaged capstan / pinch roller).

local function setup_flutter()
  flutter_metro       = metro.init()
  flutter_metro.time  = 1 / 30   -- 30Hz update (plenty for sub-8Hz LFO)
  flutter_metro.count = -1        -- infinite

  flutter_metro.event = function()
    if not loaded then return end

    local depth = params:get("flutter_depth")
    local rate  = params:get("flutter_rate")

    flutter_phase = flutter_phase + (rate / 30.0)
    if flutter_phase >= 1.0 then
      flutter_phase = flutter_phase - 1.0
    end

    local lfo_val    = math.sin(flutter_phase * 2.0 * math.pi)
    local base       = params:get("base_rate")
    softcut.rate(VOICE, base + (lfo_val * depth))
  end

  flutter_metro:start()
end

-- ============================================================
-- PHASE POLL & LOOP CROSSING DETECTION
-- ============================================================
--
-- softcut calls on_phase ~20x per second with current playhead position.
-- We detect when position jumps backward (loop boundary crossed) and use
-- that event to trigger one decay step — locking decay to the loop cycle.

function on_phase(voice, pos)
  playhead_pos = pos

  if prev_pos ~= nil then
    local loop_len = loop_end - loop_start
    -- a backward jump > half the loop length = boundary crossing
    if pos < (prev_pos - loop_len * 0.5) then
      do_decay_step()
      request_waveform()
    end
  end

  prev_pos = pos
  redraw()
end

-- ============================================================
-- WAVEFORM RENDERING
-- ============================================================

function request_waveform()
  if not loaded then return end
  local loop_len = loop_end - loop_start
  softcut.render_buffer(BUF, loop_start, loop_len, SCREEN_W)
end

function on_render(ch, start, sec_per_sample, data)
  waveform = data
  -- data is stored; next redraw() call (driven by phase poll) will use it
end

-- ============================================================
-- SCREEN
-- ============================================================
--
-- Layout:
--   Top strip  (y 1–26):  state label, pre_level bar, half-life, filter fc
--   Bottom half (y 30–62): waveform + playhead
--
-- The pre_level bar is the primary decay readout:
--   full = pristine · shrinking = decaying · sliver = ghost
--
-- Waveform brightness is tied to pre_level:
--   bright = healthy loop · dim = fading ghost

function redraw()
  screen.clear()

  -- ---- attract screen (no file loaded) -----------------------
  if not loaded then
    screen.level(6)
    screen.move(64, 24)
    screen.text_center("disintegrate")
    screen.level(3)
    screen.move(64, 36)
    screen.text_center("K2 to load file")
    screen.move(64, 44)
    screen.text_center("or params > load file")
    screen.update()
    return
  end

  -- ---- waveform ----------------------------------------------

  -- baseline rule
  screen.level(2)
  screen.move(0, WAVE_CENTRE)
  screen.line(SCREEN_W, WAVE_CENTRE)
  screen.stroke()

  if #waveform > 0 then
    -- brightness scales with pre_level: ghost = dim, pristine = bright
    local wf_level = math.floor(util.linlin(0, 1, 2, 12, pre))
    screen.level(wf_level)

    -- draw all bars, then stroke once (much faster than per-bar stroke)
    for i = 1, #waveform do
      local x   = i - 1
      local amp = math.abs(waveform[i]) * WAVE_AMP
      if amp > 0.5 then
        screen.move(x, WAVE_CENTRE - amp)
        screen.line(x, WAVE_CENTRE + amp)
      end
    end
    screen.stroke()
  end

  -- playhead
  local loop_len = math.max(0.01, loop_end - loop_start)
  local px       = math.floor(((playhead_pos - loop_start) / loop_len) * SCREEN_W)
  px             = util.clamp(px, 0, SCREEN_W - 1)
  screen.level(15)
  screen.move(px, WAVE_CENTRE - WAVE_AMP - 2)
  screen.line(px, WAVE_CENTRE + WAVE_AMP + 2)
  screen.stroke()

  -- ---- status strip ------------------------------------------

  -- state label
  local state_str, state_level
  if frozen then
    state_str, state_level = "freeze", 8
  elseif not decaying then
    state_str, state_level = "hold", 4
  elseif pre <= params:get("decay_floor") + 0.005 then
    state_str, state_level = "ghost", 5
  else
    state_str, state_level = "decay", 15
  end

  screen.level(state_level)
  screen.move(2, 8)
  screen.text(state_str)

  -- pre_level bar (50px wide)
  local floor    = params:get("decay_floor")
  local pre_norm = util.clamp((pre - floor) / math.max(0.001, 1.0 - floor), 0.0, 1.0)
  local bar_w    = 50

  screen.level(2)                                         -- track
  screen.rect(2, 11, bar_w, 2)
  screen.fill()

  screen.level(10)                                        -- fill
  screen.rect(2, 11, math.floor(pre_norm * bar_w), 2)
  screen.fill()

  -- half-life (top right)
  screen.level(4)
  screen.move(SCREEN_W - 2, 8)
  screen.text_right(string.format("t½ %.0fm", params:get("decay_rate")))

  -- filter fc (below half-life)
  screen.level(3)
  screen.move(SCREEN_W - 2, 17)
  screen.text_right(string.format("%dHz", math.floor(filter_fc)))

  -- loop length (bottom left of status area)
  screen.level(3)
  screen.move(2, 24)
  screen.text(string.format("%.1fs", loop_len))

  -- varispeed (bottom right, only shown when not 1.0)
  local base_r = params:get("base_rate")
  if math.abs(base_r - 1.0) > 0.01 then
    screen.level(3)
    screen.move(SCREEN_W - 2, 24)
    screen.text_right(string.format("x%.2f", base_r))
  end

  screen.update()
end

-- ============================================================
-- KEYS
-- ============================================================

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    return
  end

  if z == 0 then return end  -- ignore releases for K2/K3

  if n == 2 then
    if k1_held then
      if loaded then reset_decay() end          -- K1+K2: reset to pristine
    elseif not loaded then
      open_file_picker()                         -- K2 (no file): load
    else
      decaying = not decaying                    -- K2 (file loaded): toggle decay
      if decaying then frozen = false end
      redraw()
    end

  elseif n == 3 then
    if k1_held then
      open_file_picker()                         -- K1+K3: reload file
    elseif loaded then
      frozen = not frozen                        -- K3: toggle freeze
      if frozen then decaying = false end
      redraw()
    end
  end
end

-- ============================================================
-- ENCODERS
-- ============================================================

function enc(n, d)
  if n == 1 then
    params:delta("decay_rate", d)      -- E1: half-life
  elseif n == 2 then
    params:delta("filter_floor", d)    -- E2: filter floor (spectral destination)
  elseif n == 3 then
    params:delta("base_rate", d)       -- E3: varispeed
  end
  redraw()
end

-- ============================================================
-- INIT
-- ============================================================

function init()
  setup_params()

  -- restore saved params before touching softcut
  -- (params with set_action will re-apply on bang())
  params:read()

  -- initialise softcut voice
  softcut.buffer_clear()
  setup_softcut()

  -- start flutter LFO
  setup_flutter()

  -- fire all param actions to synchronise softcut with loaded params
  params:bang()

  redraw()
end

-- ============================================================
-- CLEANUP
-- ============================================================

function cleanup()
  if flutter_metro then flutter_metro:stop() end
  softcut.poll_stop_phase()
  params:write()
end

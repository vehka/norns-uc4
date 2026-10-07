-- faderfox uc4
-- lib of the uc4 mod
-- v0.1 @vehka
--
-- maps script params to a UC4 running the "Norn" setup and keeps the
-- UC4's display values and button LEDs in sync with the params.
-- lib/mod.lua does this for every script. a script can also include
-- this file and call the functions itself.
--
-- NORN SETUP LAYOUT
-- every control sends an absolute 7 bit CC, one midi channel per control
-- kind. cc number = (group - 1) * 8 + (control - 1)
--
--   kind    controls           channel  cc
--   enc     encoder 1-8        13       0-63
--   push    encoder push 1-8   14       0-63
--   fader   fader 1-8          15       0-63
--   fader   fader 9            15       64 (same in all groups)
--   button  green button 1-8   16       0-63
--
-- buttons send 127 on press and 0 on release. their LEDs are set by
-- the values norns sends back.
--
-- PARAM VIEW
-- with uc4.watch() on, touching a control shows what the controls of
-- its group are mapped to on the norns screen. pushing an encoder shows
-- it without changing a value. green button 8 (in every button group)
-- turns the view on and off. its LED is lit when the view is on.
--
-- LAYOUT FILES
-- a layout says which params go to which controls. it is a lua file
-- returning a table of param ids, one list per group:
--
--   return {
--     enc = {
--       {"cutoff", "resonance"},      -- encoder group 1
--       {"attack", false, "release"}, -- group 2, encoder 2 skipped
--     },
--     fader = {{"level"}},
--     fader9 = "main_level",
--     button = {{"mute"}},
--     push = {},
--     automap = true, -- map the other params to the free controls
--   }

local uc4 = {}

uc4.DEVICE_NAME = "UC4"
uc4.GROUPS = 8
uc4.CONTROLS = 8
uc4.CHANNEL = {enc = 13, push = 14, fader = 15, button = 16}
uc4.FADER9_CC = 64

-- the UC4 has 18 setups. the Norn setup goes to this one by default
uc4.SETUPS = 18
uc4.SETUP_SLOT = 16

-- sysex is sent in small chunks, at about half the speed of a midi
-- cable, so the UC4 has time to store each block
uc4.CHUNK_SIZE = 16
uc4.CHUNK_TIME = 0.01

-- this green button of every group turns the param view on and off.
-- automap leaves it free
uc4.VIEW_BUTTON = 8

-- automap fills these kinds, in this order
local CONTINUOUS_KINDS = {"enc", "fader"}
local SWITCH_KINDS = {"button", "push"}
-- params of these norns system groups are left out of automap
local SYSTEM_GROUPS = {
  LEVELS = true, REVERB = true, COMPRESSOR = true, SOFTCUT = true,
  CLOCK = true,
}


--
-- DEVICE
--

--- find the vport a UC4 is connected to.
-- a UC4 that is plugged in but not on any port (SYSTEM > DEVICES > MIDI)
-- is put on the first free port.
-- @treturn integer|nil vport number
function uc4.find()
  for i = 1, #midi.vports do
    if string.find(midi.vports[i].name, uc4.DEVICE_NAME, 1, true) then
      return i
    end
  end
  for _, device in pairs(midi.devices) do
    if device.port == nil
      and string.find(device.name, uc4.DEVICE_NAME, 1, true) then
      for i = 1, #midi.vports do
        if midi.vports[i].name == "none" then
          midi.vports[i].name = device.name
          midi.update_devices()
          print("uc4: "..device.name.." put on midi port "..i)
          return i
        end
      end
    end
  end
  return nil
end

--- connect to the UC4.
-- @treturn table|nil midi device, nil when no UC4 is connected
-- @treturn integer|nil vport number
function uc4.connect()
  local port = uc4.find()
  if port == nil then
    print("uc4: device not found")
    return nil
  end
  return midi.connect(port), port
end

local function port_of(midi_dev)
  for i = 1, #midi.vports do
    if midi.vports[i] == midi_dev then return i end
  end
  return nil
end


--
-- LAYOUT
--

--- cc number and channel of a control in the Norn setup.
-- @tparam string kind "enc", "push", "fader" or "button"
-- @tparam integer group 1-8
-- @tparam integer n control number 1-8 (9 for the ninth fader)
-- @treturn integer cc
-- @treturn integer channel
function uc4.control(kind, group, n)
  local ch = uc4.CHANNEL[kind]
  assert(ch, "uc4: unknown control kind "..tostring(kind))
  if kind == "fader" and n == 9 then return uc4.FADER9_CC, ch end
  assert(group >= 1 and group <= uc4.GROUPS, "uc4: group out of range")
  assert(n >= 1 and n <= uc4.CONTROLS, "uc4: control out of range")
  return (group - 1) * uc4.CONTROLS + (n - 1), ch
end


--
-- PARAM MAPPING
--

-- [param id] = name of the params section it is in, set by automap
local section_names = {}

-- params with steps (numbers, options) mapped by uc4.map(), the cc
-- value each mapped control is known to be at and when it was last
-- moved. see STEPPED PARAMS
local stepped = {} -- [param id] = true when on an encoder, else false
local known = {}
local touched = {}
local attach

-- cc positions an encoder moves for one step of a stepped param, when
-- the param has few enough values for that
uc4.STEP_WIDTH = 8

local function is_continuous(t)
  return t == params.tCONTROL or t == params.tTAPER
    or t == params.tNUMBER or t == params.tOPTION
end

local function is_mappable(id)
  local t = params:t(id)
  if not (is_continuous(t) or t == params.tBINARY) then return false end
  return params:get_allow_pmap(id) ~= false
end

--- map a param to a UC4 control.
-- replaces any earlier mapping of the param or the control. the mapping
-- is not written to the script's pmap file unless the user edits the
-- mappings in the norns menu.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam string id param id
-- @tparam string kind "enc", "push", "fader" or "button"
-- @tparam integer group 1-8
-- @tparam integer n control number 1-8 (9 for the ninth fader)
function uc4.map(midi_dev, id, kind, group, n)
  local port = port_of(midi_dev)
  if port == nil then return end
  local cc, ch = uc4.control(kind, group, n)
  local t = params:t(id)
  local pm = norns.pmap.data[id]
  if pm == nil then
    norns.pmap.new(id)
    pm = norns.pmap.data[id]
    -- a new mapping starts on dev 1, ch 1, cc 100, and assign() frees
    -- that control. start on the target so another param mapped there
    -- keeps its mapping
    pm.dev, pm.ch, pm.cc = port, ch, cc
  end
  if t == params.tNUMBER or t == params.tOPTION or t == params.tBINARY then
    local r = params:get_range(id)
    pm.out_lo = r[1]
    pm.out_hi = r[2]
  end
  pm.in_lo = 0
  pm.in_hi = 127
  pm.accum = false
  -- norns sends the value back when the param changes. not for stepped
  -- params, see STEPPED PARAMS
  stepped[id] = nil
  if t == params.tNUMBER or t == params.tOPTION then
    stepped[id] = kind == "enc"
    local steps = pm.out_hi - pm.out_lo
    if kind == "enc" and steps >= 1 then
      -- use only the middle of the encoder's range, STEP_WIDTH
      -- positions for each step
      local width = math.min(uc4.STEP_WIDTH, math.max(1, 127 // steps))
      local span = math.min(127, width * steps)
      pm.in_lo = (127 - span) // 2
      pm.in_hi = pm.in_lo + span
    end
  end
  pm.echo = stepped[id] == nil
  known[id] = nil
  norns.pmap.assign(id, port, ch, cc)
  attach(midi_dev)
end

-- remember which section (separator or group) each param is in
local function index_sections()
  section_names = {}
  local section = nil
  for i = 1, params.count do
    local p = params:lookup_param(i)
    if p.t == params.tSEPARATOR or p.t == params.tGROUP then
      section = p.name
    elseif p.id then
      section_names[p.id] = section
    end
  end
end

--- map params to the UC4 as a layout says.
-- these mappings replace earlier ones of the same params and controls.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam table layout see LAYOUT FILES at the top of this file
-- @treturn integer number of mapped params
function uc4.apply_layout(midi_dev, layout)
  local count = 0
  local function map(id, kind, group, n)
    if type(id) ~= "string" or id == "" then return end
    if params.lookup[id] == nil then
      print("uc4: layout has an unknown param: "..id)
    elseif group > uc4.GROUPS or n > 9 or (n == 9 and kind ~= "fader") then
      print("uc4: layout has no control for "..id)
    else
      uc4.map(midi_dev, id, kind, group, n)
      count = count + 1
    end
  end
  index_sections()
  for kind, _ in pairs(uc4.CHANNEL) do
    for group, ids in ipairs(type(layout[kind]) == "table" and layout[kind] or {}) do
      for n = 1, type(ids) == "table" and #ids or 0 do
        map(ids[n], kind, group, n)
      end
    end
  end
  map(layout.fader9, "fader", 1, 9)
  print("uc4: "..count.." params mapped from the layout")
  return count
end

--- read a layout file.
-- @tparam string filename lua file with path
-- @treturn table|nil layout, nil when there is no usable file
function uc4.read_layout(filename)
  if not util.file_exists(filename) then return nil end
  local ok, layout = pcall(dofile, filename)
  if not ok or type(layout) ~= "table" then
    print("uc4: can't use layout "..filename..": "..tostring(layout))
    return nil
  end
  print("uc4: layout "..filename)
  return layout
end

--- map the script's params to the UC4 in the order they were added.
-- controls, tapers, numbers and options go to the encoders and then to
-- the faders. each section of the params (a separator or a group)
-- starts a new encoder group, so a section's params sit side by side.
-- binary params go to the green buttons and then to the encoder push
-- buttons. params that don't fit are left unmapped.
-- params the user has mapped already (in the norns menu) and the UC4
-- controls they use are left alone. the params of norns itself (levels,
-- reverb, compressor, softcut, clock) are left out. hidden params are
-- mapped, so that the layout doesn't depend on what a script happens to
-- hide.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam[opt] table opts filter: function(id) returning false for
-- params to leave out. sections: false to fill the encoder groups
-- without gaps. first: index of the script's first param. the params
-- before it, those of other mods, go to the last encoder groups
-- @treturn integer number of mapped params
function uc4.automap(midi_dev, opts)
  local port = port_of(midi_dev)
  if port == nil then return 0 end
  opts = opts or {}
  index_sections()
  local per_kind = uc4.GROUPS * uc4.CONTROLS
  local slot = {0, 0} -- next free slot of the continuous / switch kinds
  local count = 0

  -- returns kind, group, n of the next control no param is mapped to
  local function next_control(class, kinds)
    while true do
      local s = slot[class]
      local kind = kinds[s // per_kind + 1]
      if kind == nil then return nil end
      slot[class] = s + 1
      local group = (s % per_kind) // uc4.CONTROLS + 1
      local n = s % uc4.CONTROLS + 1
      local cc, ch = uc4.control(kind, group, n)
      if norns.pmap.rev[port][ch][cc] == nil
        and not (kind == "button" and n == uc4.VIEW_BUTTON) then
        return kind, group, n
      end
    end
  end

  local first = opts.first or 1
  local mod_sections = {} -- lists of param indexes, one per section
  local skip_until = 0
  for i = 1, params.count do
    local p = params:lookup_param(i)
    local id = p.id
    -- norns adds its own params to every script, in groups
    if p.t == params.tGROUP and SYSTEM_GROUPS[id] then
      skip_until = math.max(skip_until, i + p.n)
    elseif i > skip_until
      and (p.t == params.tSEPARATOR or p.t == params.tGROUP) then
      if i < first then
        mod_sections[#mod_sections + 1] = {}
      elseif opts.sections ~= false and slot[1] < per_kind then
        -- move on to the start of the next encoder group
        slot[1] = math.ceil(slot[1] / uc4.CONTROLS) * uc4.CONTROLS
      end
    end
    if id and i > skip_until and is_mappable(id)
      and (opts.filter == nil or opts.filter(id) ~= false) then
      if i < first then
        -- a param of another mod: mapped below, after the script's
        if #mod_sections == 0 then mod_sections[1] = {} end
        table.insert(mod_sections[#mod_sections], i)
      elseif norns.pmap.data[id] == nil then
        local kind, group, n
        if is_continuous(p.t) then
          kind, group, n = next_control(1, CONTINUOUS_KINDS)
        else
          kind, group, n = next_control(2, SWITCH_KINDS)
        end
        if kind then
          uc4.map(midi_dev, id, kind, group, n)
          count = count + 1
        end
      end
    end
  end

  -- the params of other mods: one section per encoder group, from the
  -- last group backwards, on the controls that are still free
  local group = uc4.GROUPS
  for k = #mod_sections, 1, -1 do
    local n = 0
    for _, i in ipairs(mod_sections[k]) do
      local p = params:lookup_param(i)
      if norns.pmap.data[p.id] == nil then
        if not is_continuous(p.t) then
          local kind, g, c = next_control(2, SWITCH_KINDS)
          if kind then
            uc4.map(midi_dev, p.id, kind, g, c)
            count = count + 1
          end
        elseif group >= 1 and n < uc4.CONTROLS then
          n = n + 1
          local cc, ch = uc4.control("enc", group, n)
          if norns.pmap.rev[port][ch][cc] == nil then
            uc4.map(midi_dev, p.id, "enc", group, n)
            count = count + 1
          end
        end
      end
    end
    if n > 0 then group = group - 1 end
  end

  print("uc4: "..count.." params mapped")
  return count
end

--
-- SEND PARAM VALUES TO UC4
--

local function cc_value(id, pm)
  local t = params:t(id)
  local value
  if t == params.tCONTROL or t == params.tTAPER then
    value = params:get_raw(id)
  elseif t == params.tNUMBER or t == params.tOPTION or t == params.tBINARY then
    value = params:get(id)
  else
    return nil
  end
  return util.round(util.linlin(pm.out_lo, pm.out_hi, pm.in_lo, pm.in_hi, value))
end

--- send the value of one mapped param to the UC4.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam string id param id
function uc4.redraw(midi_dev, id)
  local pm = norns.pmap.data[id]
  -- relative (accum) mappings have no value to show on the device
  if pm == nil or pm.accum or params.lookup[id] == nil then return end
  local port = port_of(midi_dev)
  if port ~= nil and pm.dev ~= port then return end
  local value = cc_value(id, pm)
  if value ~= nil then
    midi_dev:cc(pm.cc, value, pm.ch)
    known[id] = value
  end
end

--- send the values of all mapped params to the UC4.
-- call this after the mappings or a pset have been loaded.
-- @tparam table midi_dev midi device from uc4.connect()
function uc4.refresh_values(midi_dev)
  for id, _ in pairs(norns.pmap.data) do
    uc4.redraw(midi_dev, id)
  end
end


--
-- STEPPED PARAMS
--
-- a number or option param has fewer values than a control has
-- positions. if norns echoed its value, every small turn of an encoder
-- would be answered with the position of the value the param is still
-- at, and the encoder would never get anywhere. so echo is off for
-- these params. instead the lib keeps track of where each control is
-- and sends a value when the param is at another value than the one
-- the control's position stands for (it was changed on norns).
--
-- on an encoder a short turn should be enough to go from one value to
-- the next, also for a param with two values. so each value gets only
-- STEP_WIDTH positions, in the middle of the encoder's range (see
-- uc4.map()), and when the encoder has been left alone for a moment it
-- is set to the exact position of the param's value. the next turn
-- then starts half a step away from the neighbouring values.

local SETTLE_TIME = 0.4
local SYNC_FPS = 10
local sync = {dev = nil, clock = nil}

local function sync_stepped()
  for id, _ in pairs(stepped) do -- the values are booleans
    local pm = norns.pmap.data[id]
    if pm == nil or params.lookup[id] == nil then
      stepped[id] = nil
    else
      local target = cc_value(id, pm)
      local at = known[id]
      local stands_for = at and util.round(
        util.linlin(pm.in_lo, pm.in_hi, pm.out_lo, pm.out_hi, at))
      local settled = stepped[id]
        and util.time() - (touched[id] or 0) > SETTLE_TIME
      if at ~= target and (settled or stands_for ~= params:get(id)) then
        uc4.redraw(sync.dev, id)
      end
    end
  end
end

local function sync_loop()
  while true do
    clock.sleep(1 / SYNC_FPS)
    sync_stepped()
  end
end


--
-- PARAM VIEW
--
-- while the view is up it owns the screen: screen.update is swapped for
-- a function that does nothing, so the script's drawing isn't shown.

uc4.VIEW_TIME = 1.5 -- seconds the view stays up after the last touch
local VIEW_FPS = 15
local KIND_OF_CHANNEL = {}
for kind, ch in pairs(uc4.CHANNEL) do KIND_OF_CHANNEL[ch] = kind end

local view = {
  visible = false,
  kind = "enc", group = 1, n = 1, -- the control touched last
  held = false,                   -- an encoder is held down
  dirty = false,
  deadline = 0,
  port = nil,
  dev = nil,
  watching = false,               -- set by uc4.watch()
  update = nil,                   -- screen.update, while the view is up
}

--- whether the param view is shown when a control is touched.
-- green button 8 changes this. set it with uc4.set_view().
uc4.view_on = true
--- called with true or false when the view is turned on or off.
uc4.view_changed = nil

local function param_at(kind, group, n)
  local cc, ch = uc4.control(kind, group, n)
  local id = norns.pmap.rev[view.port][ch][cc]
  if id ~= nil and params.lookup[id] ~= nil then return id end
  return nil
end

local function draw_view()
  local first, last = 1, uc4.CONTROLS
  if view.n > uc4.CONTROLS then first, last = view.n, view.n end
  local active = param_at(view.kind, view.group, view.n)

  screen.clear()
  screen.aa(0)
  screen.line_width(1)
  screen.font_face(1)
  screen.font_size(8)
  screen.level(15)
  screen.move(0, 7)
  if view.n > uc4.CONTROLS then
    screen.text(view.kind.." "..view.n)
  else
    screen.text(view.kind.." group "..view.group)
  end
  if active and section_names[active] then
    screen.level(4)
    screen.move(127, 7)
    screen.text_right(util.trim_string_to_width(section_names[active], 64))
  end
  for n = first, last do
    local y = 7 + (n - first + 1) * 7
    local id = param_at(view.kind, view.group, n)
    screen.level(n == view.n and 15 or 4)
    screen.move(0, y)
    screen.text(n)
    screen.move(8, y)
    if id then
      local p = params:lookup_param(id)
      screen.text(util.trim_string_to_width(p.name or id, 64))
      screen.move(127, y)
      screen.text_right(
        util.trim_string_to_width(tostring(params:string(id) or ""), 50))
    elseif view.kind == "button" and n == uc4.VIEW_BUTTON then
      screen.text("param view")
      screen.move(127, y)
      screen.text_right("on")
    else
      screen.text("-")
    end
  end
  view.update()
end

local function hide_view()
  if not view.visible then return end
  view.visible = false
  view.held = false
  screen.update = view.update
  view.update = nil
  -- let the script draw its screen again (redraw does nothing in the menu)
  if redraw then pcall(redraw) end
end

local function view_loop()
  while view.visible do
    if _menu.mode or (not view.held and util.time() > view.deadline) then
      hide_view()
      return
    end
    if view.dirty then
      view.dirty = false
      draw_view()
    end
    clock.sleep(1 / VIEW_FPS)
  end
end

-- light the view buttons that no param is mapped to
local function show_view_leds()
  if view.dev == nil then return end
  for group = 1, uc4.GROUPS do
    local cc, ch = uc4.control("button", group, uc4.VIEW_BUTTON)
    if norns.pmap.rev[view.port][ch][cc] == nil then
      view.dev:cc(cc, uc4.view_on and 127 or 0, ch)
    end
  end
end

--- turn the param view on or off.
-- @tparam boolean on
function uc4.set_view(on)
  uc4.view_on = on and true or false
  if not uc4.view_on then hide_view() end
  if view.watching then show_view_leds() end
  if uc4.view_changed then uc4.view_changed(uc4.view_on) end
end

local function show_view()
  if view.visible or _menu.mode then return end
  view.visible = true
  view.update = screen.update
  screen.update = function() end
  clock.run(view_loop)
end

local function midi_event(data)
  if data[1] == nil or (data[1] & 0xF0) ~= 0xB0 then return end
  local kind = KIND_OF_CHANNEL[(data[1] & 0x0F) + 1]
  local cc, value = data[2], data[3]
  if kind == nil then return end
  local id = norns.pmap.rev[view.port][(data[1] & 0x0F) + 1][cc]
  if id then
    known[id] = value
    touched[id] = util.time()
  end
  if not view.watching then return end
  local group, n = view.group, 9
  if not (kind == "fader" and cc == uc4.FADER9_CC) then
    if cc >= uc4.GROUPS * uc4.CONTROLS then return end
    group, n = cc // uc4.CONTROLS + 1, cc % uc4.CONTROLS + 1
  end
  if kind == "button" and n == uc4.VIEW_BUTTON and id == nil then
    if value > 0 then uc4.set_view(not uc4.view_on) end
    if value == 0 or not uc4.view_on then return end
  end
  if not uc4.view_on then return end
  if kind == "push" then
    view.held = value > 0
    -- a push button without a param shows the encoder it is on
    if param_at("push", group, n) == nil then kind = "enc" end
  end
  view.kind, view.group, view.n = kind, group, n
  view.deadline = util.time() + uc4.VIEW_TIME
  view.dirty = true
  show_view()
end

-- listen to the UC4 and keep the stepped params in sync.
-- uses the midi device's own event callback, so a script is free to
-- set the event callback of the UC4's port.
attach = function(midi_dev)
  local port = port_of(midi_dev)
  if port == nil or midi_dev.device == nil then return end
  view.port = port
  midi_dev.device.event = midi_event
  sync.dev = midi_dev
  -- the clocks of a script are cancelled when it ends
  if sync.clock == nil or clock.threads[sync.clock] == nil then
    sync.clock = clock.run(sync_loop)
  end
end

--- show what the UC4's controls are mapped to when they are touched.
-- @tparam table midi_dev midi device from uc4.connect()
function uc4.watch(midi_dev)
  attach(midi_dev)
  view.dev = midi_dev
  view.watching = true
  show_view_leds()
end

--- stop showing the param view and give the screen back.
-- @tparam[opt] table midi_dev midi device from uc4.connect()
function uc4.unwatch(midi_dev)
  view.watching = false
  if view.visible then
    view.visible = false
    view.held = false
    screen.update = view.update
    view.update = nil
  end
end


--
-- NORN SETUP
--
-- a setup dump is one sysex message: a header, blocks of the UC4's
-- setup memory and an end tag. every byte is sent as a tag followed by
-- its two nibbles (0x20 + high, 0x10 + low):
--
-- 0x41   tag: device (0x06 = UC4)
-- 0x42   tag: dump type (0x02 = one setup, 0x03 = all setups)
-- 0x43   tag: firmware version, major
-- 0x44   tag: firmware version, minor
-- 0x49   tag: block address, high byte
-- 0x4A   tag: block address, low byte
-- 0x4D   tag: data byte
-- 0x4B   tag: block checksum (sum of the data bytes), high byte
-- 0x4C   tag: block checksum, low byte
-- 0x4F   tag: end of dump (0x06)
--
-- setup memory, per setup:
-- group names    8 groups x 4 characters
-- fader 9        8 groups x 5 bytes: type/channel, number, lower value,
--                upper value, mode/display
-- 20 rows of 64 bytes (8 groups x 8 controls), five rows for each of
-- encoders, push buttons, green buttons and faders:
--                type/channel, number, lower value, upper value,
--                mode/display

local ADDR_NAMES = 0x1480
local ADDR_FADER9 = 0x1700
local ADDR_ROWS = 0x1C00
local SETUP_SIZE = 0x500
local BLOCK_SIZE = 0x40
local BLOCK_GAP = 30 -- zero bytes after each block
local FIRMWARE = {2, 3}

-- display characters used in the group names
local CHAR = {n = 0x16, o = 0x17, r = 0x1A}

-- type/channel byte: type in the high nibble, channel - 1 in the low
local TYPE = {enc = 2, push = 2, button = 2, fader = 0} -- all absolute CC
-- mode/display byte: mode in the high nibble, display in the low
local MODE = {
  enc = 0x31,    -- max acceleration, standard display
  push = 0x00,   -- momentary
  button = 0x02, -- momentary, LED set by incoming values only
  fader = 0x11,  -- snap, standard display
}
local ROW_ORDER = {"enc", "push", "button", "fader"}

local function push_byte(out, tag, value)
  out[#out + 1] = tag
  out[#out + 1] = 0x20 + (value >> 4)
  out[#out + 1] = 0x10 + (value & 0x0F)
end

local function push_block(out, addr, data)
  local sum = 0
  push_byte(out, 0x49, addr >> 8)
  push_byte(out, 0x4A, addr & 0xFF)
  for _, v in ipairs(data) do
    push_byte(out, 0x4D, v)
    sum = sum + v
  end
  push_byte(out, 0x4B, sum >> 8)
  push_byte(out, 0x4C, sum & 0xFF)
  for _ = 1, BLOCK_GAP do out[#out + 1] = 0 end
end

--- build the sysex dump of the Norn setup.
-- a dump is made for one setup slot and overwrites that setup.
-- @tparam integer slot setup number 1-18
-- @treturn table sysex bytes
function uc4.norn_setup(slot)
  local out = {0xF0, 0, 0, 0}
  push_byte(out, 0x41, 0x06)
  push_byte(out, 0x42, 0x02)
  push_byte(out, 0x43, FIRMWARE[1])
  push_byte(out, 0x44, FIRMWARE[2])

  -- group names: nor1 - nor8
  local names = {}
  for g = 1, uc4.GROUPS do
    names[#names + 1] = CHAR.n
    names[#names + 1] = CHAR.o
    names[#names + 1] = CHAR.r
    names[#names + 1] = g
  end
  push_block(out, ADDR_NAMES + (slot - 1) * 4 * uc4.GROUPS, names)

  -- fader 9, the same in every group
  local fader9 = {}
  for _ = 1, uc4.GROUPS do
    fader9[#fader9 + 1] = (TYPE.fader << 4) + uc4.CHANNEL.fader - 1
    fader9[#fader9 + 1] = uc4.FADER9_CC
    fader9[#fader9 + 1] = 0
    fader9[#fader9 + 1] = 127
    fader9[#fader9 + 1] = MODE.fader
  end
  while #fader9 < BLOCK_SIZE do fader9[#fader9 + 1] = 0xFF end
  push_block(out, ADDR_FADER9 + (slot - 1) * BLOCK_SIZE, fader9)

  local addr = ADDR_ROWS + (slot - 1) * SETUP_SIZE
  for _, kind in ipairs(ROW_ORDER) do
    local rows = {{}, {}, {}, {}, {}}
    for i = 1, BLOCK_SIZE do
      rows[1][i] = (TYPE[kind] << 4) + uc4.CHANNEL[kind] - 1
      rows[2][i] = i - 1 -- cc number, see uc4.control()
      rows[3][i] = 0
      rows[4][i] = 127
      rows[5][i] = MODE[kind]
    end
    for _, row in ipairs(rows) do
      push_block(out, addr, row)
      addr = addr + BLOCK_SIZE
    end
  end

  push_byte(out, 0x4F, 0x06)
  out[#out + 1] = 0xF7
  return out
end


--
-- SETUP (SYSEX) LOADER
--
-- the UC4 only takes setup data in its receive mode: hold shift and
-- press edit twice, then keep encoder 7 down until the bar lines on the
-- display have run out. the UC4 shows the setup number ("SE16") when
-- the data is stored.
-- sending runs in a clock, so the functions return before the data is
-- sent.

local function send_sysex(midi_dev, bytes, on_done)
  clock.run(function()
    for i = 1, #bytes, uc4.CHUNK_SIZE do
      local chunk = {}
      for k = i, math.min(i + uc4.CHUNK_SIZE - 1, #bytes) do
        chunk[#chunk + 1] = bytes[k]
      end
      midi_dev:send(chunk)
      clock.sleep(uc4.CHUNK_TIME)
    end
    if on_done then on_done(true) end
  end)
end

--- send the Norn setup to the UC4.
-- overwrites the setup in the given slot.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam[opt] integer slot setup number 1-18, default uc4.SETUP_SLOT
-- @tparam[opt] function on_done called with true when the setup was sent
function uc4.send_norn_setup(midi_dev, slot, on_done)
  slot = slot or uc4.SETUP_SLOT
  assert(slot >= 1 and slot <= uc4.SETUPS, "uc4: setup slot out of range")
  send_sysex(midi_dev, uc4.norn_setup(slot), function(ok)
    print("uc4: norn setup sent to setup "..slot)
    if on_done then on_done(ok) end
  end)
end

--- send a sysex setup file (a dump made by the UC4) to the UC4.
-- @tparam table midi_dev midi device from uc4.connect()
-- @tparam string filename .syx file with path
-- @tparam[opt] function on_done called with true when the file was sent
-- @treturn boolean false when the file can't be used
function uc4.load_conf(midi_dev, filename, on_done)
  local f = io.open(filename, "rb")
  if f == nil then
    print("uc4: can't open "..filename)
    return false
  end
  local data = f:read("a")
  f:close()
  if #data < 2 or data:byte(1) ~= 0xF0 or data:byte(-1) ~= 0xF7 then
    print("uc4: "..filename.." is not a sysex file")
    return false
  end
  local bytes = {}
  for i = 1, #data do bytes[i] = data:byte(i) end
  send_sysex(midi_dev, bytes, function(ok)
    print("uc4: "..filename.." sent")
    if on_done then on_done(ok) end
  end)
  return true
end

return uc4

-- uc4 mod
-- maps the params of every script to a faderfox uc4 running the Norn
-- setup, and shows what the controls are mapped to when they are touched
-- (green button 8 turns that on and off).
-- the mod menu sends the Norn setup or a setup (.syx) file to the uc4.
--
-- the params are mapped by the first of these that exists:
--   dust/data/uc4/<script>.lua             a layout made by the user
--   dust/code/<script>/lib/uc4_layout.lua  a layout that comes with the script
--   automap                                params in the order they were added
-- the layout format is described in lib/uc4.lua

-- libraries
local mod = require "core/mods"
local uc4 = require(mod.this_name.."/lib/uc4")

-- variables
local PATH = _path.data.."uc4/"
local midi_device = nil
local NORN_SETUP = "norn setup"
local conf_files = {} -- NORN_SETUP followed by the .syx files in PATH
local file_index = 1
local dump = nil       -- the selected .syx file, when it is usable
local status = ""
local help = false     -- K1 is held: the instructions are shown

--
-- PARAM VIEW ON / OFF
-- green button 8 of the uc4 changes it. kept over restarts
--
local VIEW_FILE = PATH.."view_off"
uc4.view_on = not util.file_exists(VIEW_FILE)
uc4.view_changed = function(on)
  if on then
    os.remove(VIEW_FILE)
  else
    if not util.file_exists(PATH) then util.make_dir(PATH) end
    local f = io.open(VIEW_FILE, "w")
    if f then f:close() end
  end
end

--
-- SCRIPT HOOKS
--
-- params added before the script's init are those of norns and of other
-- mods. automap puts the mods' params on the last encoder groups. the
-- name makes this hook run after the other mods' hooks, which run in
-- alphabetical order.
local first_param = 1
mod.hook.register("script_pre_init", "zz uc4 first param", function()
  first_param = params.count + 1
end)

mod.hook.register("script_post_init", "uc4 map params", function()
  midi_device = uc4.connect()
  if midi_device == nil then return end
  local layout = uc4.read_layout(PATH..norns.state.shortname..".lua")
    or uc4.read_layout(norns.state.path.."lib/uc4_layout.lua")
  if layout then uc4.apply_layout(midi_device, layout) end
  if layout == nil or layout.automap ~= false then
    uc4.automap(midi_device, {first = first_param})
  end
  uc4.refresh_values(midi_device)
  uc4.watch(midi_device)
end)

mod.hook.register("script_post_cleanup", "uc4 release screen", function()
  uc4.unwatch(midi_device)
end)

--
-- MOD MENU
--
-- check the selected file. the UC4 stores a dump of one setup in the
-- setup that is selected on it, so there is no setup to choose here
local function select_file()
  local name = conf_files[file_index]
  dump = nil
  status = ""
  if name ~= NORN_SETUP then
    local err
    dump, err = uc4.read_dump(PATH..name)
    if dump == nil then
      status = err
    elseif dump.all then
      status = "all setups: not tested"
    end
  end
end

local function scan_files()
  conf_files = {NORN_SETUP}
  for _, name in ipairs(util.scandir(PATH)) do
    if string.match(string.lower(name), "%.syx$") then
      table.insert(conf_files, name)
    end
  end
  file_index = util.clamp(file_index, 1, #conf_files)
  select_file()
end

local m = {}

m.key = function(n, z)
  if n == 1 then
    help = z == 1
  elseif n == 2 and z == 1 then
    mod.menu.exit()
    return
  elseif n == 3 and z == 1 then
    local function sent()
      status = "sent"
      mod.menu.redraw()
    end
    if midi_device == nil then
      status = "uc4 not found"
    elseif conf_files[file_index] == NORN_SETUP then
      uc4.send_norn_setup(midi_device, nil, sent)
      status = "sending..."
    else
      local ok, err = uc4.load_conf(
        midi_device, PATH..conf_files[file_index], sent)
      status = ok and "sending..." or err
    end
  end
  mod.menu.redraw()
end

m.enc = function(n, d)
  if n == 2 then
    local index = util.clamp(file_index + d, 1, #conf_files)
    if index ~= file_index then
      file_index = index
      select_file()
    end
  end
  mod.menu.redraw()
end

-- how to put the UC4 in receive mode and send. shown while K1 is held
local function draw_help()
  local lines = {
    "ON THE UC4",
    "1 hold shift, press edit twice",
    "2 enc 1: setup to overwrite",
    "3 hold enc 7 until rC00",
    "ON NORNS",
    "4 e2: what to send",
    "5 k3: send. uc4 shows SE..",
    "  no change? again from 3",
  }
  screen.clear()
  for i, line in ipairs(lines) do
    screen.level(line == string.upper(line) and 15 or 4)
    screen.move(0, i * 8 - 1)
    screen.text(line)
  end
  screen.update()
end

m.redraw = function()
  if help then
    draw_help()
    return
  end
  screen.clear()
  screen.level(4)
  screen.move(0, 8)
  screen.text("send a setup to the uc4")
  screen.move(0, 16)
  screen.text("hold k1: how to")
  screen.level(15)
  screen.move(0, 30)
  screen.text(util.trim_string_to_width(conf_files[file_index], 127))
  screen.level(4)
  screen.move(0, 44)
  if midi_device == nil then
    screen.text("uc4 not found")
  else
    screen.text("e2 file  k3 send")
  end
  screen.level(15)
  screen.move(0, 58)
  screen.text(status)
  screen.update()
end

m.init = function()
  midi_device = uc4.connect()
  -- create data directory if it does not exist
  if not util.file_exists(PATH) then util.make_dir(PATH) end
  scan_files()
  help = false
end

m.deinit = function() end

mod.menu.register(mod.this_name, m)

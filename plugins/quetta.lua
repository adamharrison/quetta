-- mod-version:4 priority:0

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"
local keymap = require "core.keymap"
local NagView = require "core.nagview"

local libquetta = require "plugins.quetta.libquetta"

config.plugins.quetta = common.merge({
  -- allow for tracking of mouseclicks
  mouse_tracking = true,
  -- swaps to the xterm alternate buffer on startup
  use_alternate_buffer = true,
  -- removes the cursor from being shown
  disable_cursor = true,
  -- the amount of time that must pass betwene clicks to separate a single click from a double-click
  click_interval = 0.3,
  -- restores the specific terminal configuration you had before this intiialized vs. best guess
  restore = false
}, config.plugins.quetta)


if config.plugins.quetta.disable_cursor then io.stdout:write("\x1B[?25l") end -- Disable curosr.
if config.plugins.quetta.use_alternate_buffer then io.stdout:write("\x1B[?47h") end -- Use alternate screen buffer.
if config.plugins.quetta.mouse_tracking then io.stdout:write("\x1B[?1002h") end -- Enable mouse tracking.
io.stdout:flush()
libquetta.init(config.plugins.quetta.restore, function()
    io.stdout:write("\x1B[2J");
    if config.plugins.quetta.disable_cursor then io.stdout:write("\x1B[?25h") end
    if config.plugins.quetta.use_alternate_buffer then io.stdout:write("\x1B[?47l") end
    if config.plugins.quetta.mouse_tracking then io.stdout:write("\x1B[?1002l") end
    io.stdout:write("\x1B[39m");
    io.stdout:write("\x1B[49m");
    io.stdout:write("\r");
    io.stdout:flush()
end)

local size_x, size_y = libquetta.size("stdout")
style.padding = { x = 0, y = 0 }

local clip = { x = 1, y = 1, x = size_x, y = size_y }

function system.window_has_focus(window) return true end
function renwindow:get_size() return libquetta.size("stdout") end
function NagView:get_buttons_height() return 1 end

local function translate_color(color)
  return (math.floor(color[1] * 5 / 256 + 0.5) * 36) + (math.floor((color[2] / 256 * 5 + 0.5)) * 6) + math.floor((color[3] / 256 * 5 + 0.5)) + 16
end

renderer.font.get_width = function(font, text) if type(text) ~= 'string' then return #tostring(text) end return text:ulen() end
renderer.font.get_height = function() return 1 end

local size_x, size_y
local old_size_x, old_size_y
renderer.begin_frame = function(...)
  size_x, size_y = libquetta.size("stdout")
  if old_size_x ~= size_x or old_size_y ~= size_y then
    io.stdout:write("\x1B[2J")
    old_size_x, old_size_y = size_x, size_y
  end
end
renderer.end_frame = libquetta.end_frame

local old_step = core.step
local accumulator = ""

local old_poll = system.poll_event

local translations = {
  ["\x1B%[1?;?(%d?)A"] = "up",
  ["\x1B%[1?;?(%d?)B"] = "down",
  ["\x1B%[1?;?(%d?)C"] = "right",
  ["\x1B%[1?;?(%d?)D"] = "left",
  ["\x1B%[2;?(%d?)~"] = "insert",
  ["\x1B%[3;?(%d?)~"] = "delete",
  ["\x1B%[5;?(%d?)~"] = "pageup",
  ["\x1B%[6;?(%d?)~"] = "pagedown",
  ["\x1B%[1?;?(%d?)H"] = "home",
  ["\x1B%[1?;?(%d?)F"] = "end",
}

local queued_presses = {}
local queued_releases = {}
local queued_events = {}
local pressed_button = nil
local last_cursor = nil
local button_names = { [0] = "left", [1] = "right", [2] = "middle" }
local total_clicks = 0
local last_click = nil
function system.poll_event()
  if #queued_presses > 0 then table.insert(queued_releases, queued_presses[1]) return "keypressed", table.remove(queued_presses, 1) end
  if #queued_events > 0 then return table.unpack(table.remove(queued_events, 1)) end
  if #queued_releases > 0 then return "keyreleased", table.remove(queued_releases, 1) end
  if #accumulator == 0 then return old_poll() end  
  local n = accumulator

  -- mouse tracking events.
  if config.plugins.quetta.mouse_tracking then
    local s,e, modifier, x, y = n:find("^\x1B%[M(.)(.)(.)") 
    if s then
      modifier = modifier:byte() - 32
      accumulator = accumulator:sub(e + 1)
      x,y = x:byte() - 33, y:byte() - 33
      if (modifier & 0x20) > 0 then
        return "mousemoved", x, y, x - last_cursor[1], y - last_cursor[2]
      else 
        last_cursor = { x, y }
        local button_id = modifier & 0x2
        if button_id == 3 then
          local name = button_names[pressed_button]
          pressed_button = nil
          return "mousereleased", name, x, y
        else 
          if (modifier & 0x4) > 0 then table.insert(queued_presses, "left shift") end
          if (modifier & 0x8) > 0 then table.insert(queued_presses, "left windows") end
          if (modifier & 0x10) > 0 then table.insert(queued_presses, "left ctrl") end
          if not last_click or (system.get_time() - last_click > config.plugins.quetta.click_interval) then
            total_clicks = 0
            last_click = system.get_time()
          end
          total_clicks = total_clicks + 1
          pressed_button = button_id
          table.insert(queued_events, { "mousepressed", button_names[button_id], x, y, total_clicks })
          return system.poll_event()
        end
      end
    end
  end
  
  if n:find("^[%w %.!@#$%%%^&%*%(%)'\",:]") then
    accumulator = ""
    return "textinput", n
  end
  if #accumulator == 2 and accumulator == "\x1B\x7F" then accumulator = "" table.insert(queued_presses, "left alt") table.insert(queued_presses, "backspace") return system.poll_event() end
  if #accumulator == 1 and accumulator == "\x08" then accumulator = "" table.insert(queued_presses, "left ctrl") table.insert(queued_presses, "backspace") return system.poll_event() end
  if #accumulator == 1 and accumulator == "\x7F" then accumulator = "" return "keypressed", "backspace" end
  if #accumulator == 1 and accumulator == "\x1B" then accumulator = "" return "keypressed", "escape" end
  if #accumulator == 1 and accumulator == "\n" then accumulator = "" return "keypressed", "return" end
  if #accumulator == 1 and accumulator == "\t" then accumulator = "" return "keypressed", "tab" end
  if accumulator:find("^\x1B[\x01-\x20]") then
    table.insert(queued_presses, "left ctrl")
    table.insert(queued_presses, "left alt")
    table.insert(queued_presses, string.char(96 + accumulator:byte(2)))
    accumulator = accumulator:sub(3)
    return system.poll_event()
  end
  if accumulator:find("^[\x01-\x20]") and not accumulator:sub(2,2):find("%[") then
    table.insert(queued_presses, "left ctrl")
    table.insert(queued_presses, string.char(96 + accumulator:byte(1)))
    accumulator = accumulator:sub(2)
    return system.poll_event()
  end
  local s,e,c = accumulator:find("^\x1B%[")
  if s then
    for k,v in pairs(translations) do
      local fs, fe, modifier = accumulator:find("^" .. k)
      if fs then
        if modifier == "2" then table.insert(queued_presses, "left shift") end
        if modifier == "3" then table.insert(queued_presses, "left alt") end
        if modifier == "4" then table.insert(queued_presses, "left shift") table.insert(queued_presses, "left alt") end
        if modifier == "5" then table.insert(queued_presses, "left ctrl") end
        if modifier == "6" then table.insert(queued_presses, "left ctrl") table.insert(queued_presses, "left shift") end
        if modifier == "8" then table.insert(queued_presses, "left ctrl") table.insert(queued_presses, "left alt") table.insert(queued_presses, "left shift") end
        table.insert(queued_presses, v)
        accumulator = accumulator:sub(fe+1)
        return system.poll_event()
      end
    end
  end
  accumulator = accumulator:sub(2)
  return "keypressed", n:sub(1,1)
end

core.step = function()
  local did_redraw = old_step()
  local read = libquetta.read(config.blink_period / 2)
  if read then
    io.open("/tmp/test", "ab"):write(read):close()
    accumulator = accumulator .. read
    core.redraw = true
  end
  return true
end

renderer.set_clip_rect = function(x, y, w, h) clip = { x = x, y = y, w = w, h = h } end

renderer.draw_rect = function(x, y, w, h, color)
  local sx = math.floor(math.max(x, clip.x))
  local sy = math.floor(math.max(y, clip.y))
  local sw = math.floor(math.min(x + w, clip.x + clip.w)) - sx
  local sh = math.floor(math.min(y + h, clip.y + clip.h)) - sy
  if sw > 0 and sh > 0 and (not color or not color[4] or color[4] > 0) then
    libquetta.draw_rect(sx, sy, sw, sh, translate_color(color))
  end
end

renderer.draw_text = function(font, string, x, y, color)
  if x and y and (not color or not color[4] or color[4] > 0) and (y and y >= clip.y and y < clip.y + clip.h) then
  if type(string) == 'number' then string = tostring(string) end
    local s = math.max(clip.x - x, 0) + 1
    local e = math.min(clip.x + clip.w, x + string:ulen()) - x
    local str = string:usub(s, e)
    if #str > 0 then
      libquetta.draw_text(font, str, math.floor(x), math.floor(y), translate_color(color))
    end
  end
  return x + string:ulen()
end

style.caret_width = 1
style.tab_width = 4
core.window_mode = "maximized"
config.transitions = false
config.plugins.treeview = false

-- rebind anything that's not already bound from shift to alt, because terminal emulators tend to dominate the shift-space.
for k,v in pairs(keymap.map) do
  if k:find("ctrl%+shift") then
    local list = { table.unpack(v) }
    for i,cmd in ipairs(list) do
      keymap.unbind(k, cmd)
      keymap.add({ [k:gsub("shift", "alt")] = cmd })
    end
  end
end
keymap.add {
  ["ctrl+q"] = "core:quit"
}

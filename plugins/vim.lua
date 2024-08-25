-- mod-version:4 priority:0

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"

local libvim = require "plugins.vim.libvim"

local size_x, size_y = libvim.size("stdout")
style.padding = { x = 0, y = 0 }

local clip = { x = 1, y = 1, x = size_x, y = size_y }

function system.window_has_focus(window) return true end
function renwindow:get_size() return libvim.size("stdout") end

local function translate_color(color)
  return (math.floor(color[1] * 5 / 256 + 0.5) * 36) + (math.floor((color[2] / 256 * 5 + 0.5)) * 6) + math.floor((color[3] / 256 * 5 + 0.5)) + 16
end


renderer.font.get_width = function(font, text)
  if not text then return 0 end
  if type(text) == 'number' then return #tostring(text) end
  return text:ulen()
end
renderer.font.get_height = function()
  return 1
end

local frame = {
  backgrounds = {},
  colors = {},
  text = {}
}
local size_x, size_y
local old_size_x, old_size_y

renderer.begin_frame = function(...)
  os.remove("/tmp/wat")
  size_x, size_y = libvim.size("stdout")
  if old_size_x ~= size_x or old_size_y ~= size_y then
    io.stdout:write("\x1B[2J")
  end
  libvim.begin_frame()
end

renderer.end_frame = function(...)
  libvim.end_frame()
  old_size_x, old_size_y = size_x, size_y
  io.stdout:flush()
end

local old_step = core.step
local accumulator = ""

local old_poll = system.poll_event

local translations = {
  ["A"] = "up",
  ["B"] = "down",
  ["C"] = "right",
  ["D"] = "left"
}

function system.poll_event()
  if #accumulator == 0 then return old_poll() end
  local n = accumulator
  if n:find("^[%w%s%.!@#$%%%^&%*%(%)'\"]") then
    accumulator = ""
    return "textinput", n
  end
  local s,e,c = accumulator:find("^\x1B%[(%w)")
  if s and translations[c] then
    accumulator = accumulator:sub(e+1)
    return "keypressed", translations[c]
  end
  accumulator = accumulator:sub(2)
  local translation = n:sub(1,1)
  if translation == "\x7F" then translation = "backspace" end
  return "keypressed", translation
end

core.step = function()
  local did_redraw = old_step()
  local read = libvim.read(config.blink_period / 2)
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
  if sw > 0 and sh > 0 then
    libvim.draw_rect(sx, sy, sw, sh, translate_color(color))
  end
end

renderer.draw_text = function(font, string, x, y, color)
  if type(string) == 'number' then string = tostring(string) end
  if x and y and (not color or not color[4] or color[4] > 0) or (y and y >= clip.y and y < clip.y + clip.h) then
    local s = math.max(clip.x - x, 0) + 1
    local e = math.min(clip.x + clip.w, x + string:ulen()) - x
    local str = string:usub(s, e)
    if #str > 0 then
      io.open("/tmp/wat", "ab"):write(string.format("STR: %d %d %s\n", math.floor(x), math.floor(y), str)):close()
      libvim.draw_text(font, str, math.floor(x), math.floor(y), translate_color(color))
    end
  end
  return x + string:ulen()
end

style.caret_width = 1
style.tab_width = 4
config.plugins.treeview.visible = false
core.window_mode = "maximized"
config.transitions = false

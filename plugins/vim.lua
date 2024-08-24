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

local function jump_to(x, y)
  return "\x1B[" .. math.floor(y + 1) .. ";" .. math.floor(x + 1) .. "H"
end

local function translate_color(color)
  return (math.floor(color[1] * 5 / 256 + 0.5) * 36) + (math.floor((color[2] / 256 * 5 + 0.5)) * 6) + math.floor((color[3] / 256 * 5 + 0.5)) + 16
end

local function emit_color_foreground(color)
  if color == "reset" then return "\x1B[39m" end
  return "\x1B[38;5;" .. translate_color(color) .. "m"
end
local function emit_color_background(color)
  if color == "reset" then return "\x1B[49m" end
  return "\x1B[48;5;" .. translate_color(color) .. "m"
end


renderer.font.get_width = function(font, text)
  if not text then return 0 end
  if type(text) == 'number' then return #tostring(text) end
  return text:ulen()
end
renderer.font.get_height = function()
  return 1
end

local backgrounds = {}
local size_x, size_y

renderer.begin_frame = function(...)
  size_x, size_y = libvim.size("stdout")
  backgrounds = {}
  io.stdout:write(emit_color_foreground("reset"))
  io.stdout:write(emit_color_background("reset"))
  io.stdout:write("\x1B[2J")
  jump_to(1, 1)
end

renderer.end_frame = function(...)
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
  local sx = math.max(x, clip.x)
  local sy = math.max(y, clip.y)
  local sxe = math.min(x + w, clip.x + clip.w)
  local sye = math.min(y + h, clip.y + clip.h)
  for ny = sy, sye - 1 do
    io.stdout:write(jump_to(sx, ny))
    for nx = sx, sxe - 1 do
      io.stdout:write(emit_color_background(color))
      io.stdout:write(" ")
      backgrounds[ny*size_y + nx] = color
    end
  end
  io.stdout:flush()
end

local function get_background(x, y)
  for i,v in ipairs(backgrounds) do
    if x >= v.x and x < v.x + v.w and y >= v.y and y < v.y + v.h then return v end
  end
  return nil
end

renderer.draw_text = function(font, string, x, y, color)
  if type(string) == 'number' then string = tostring(string) end
  if x and y then
    if not color or not color[4] or color[4] > 0 then
      if y and y >= clip.y and y <= clip.y + clip.h then
        io.stdout:write(jump_to(x, y))
        io.stdout:write(emit_color_background(backgrounds[y*size_y + x] or "reset"))
        io.stdout:write(emit_color_foreground(color))
        local s = math.max(clip.x - x, 0) + 1
        local e = math.min(clip.x + clip.w, x + string:ulen()) - x
        local str = string:usub(s, e)
        if #str > 0 then
          io.stdout:write(str)
        end
      end
    end
  end
  return x + string:ulen()
end

style.caret_width = 1
style.tab_width = 4
config.plugins.treeview.visible = false
core.window_mode = "maximized"

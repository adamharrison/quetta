-- mod-version:4 priority:0

local core = require "core"
local config = require "core.config"
local style = require "core.style"

local dimensions = { x = 80, y = 24 }

style.padding.x = 0
style.padding.y = 0

local clip = { x = 1, y = 1, x = 80, y = 24 }

core.root_view.size.x = dimensions.x
core.root_view.size.y = dimensions.y

function renwindow:get_size()
  return dimensions.x, dimensions.y
end

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

renderer.begin_frame = function(...)
  backgrounds = {}
  io.stdout:write(emit_color_foreground("reset"))
  io.stdout:write(emit_color_background("reset"))
  io.stdout:write("\x1B[2J")
  io.stdout:flush()
  jump_to(1, 1)
end

renderer.end_frame = function(...)
  io.stdin:read("*line")
end

renderer.set_clip_rect = function(x, y, w, h) clip = { x = x, y = y, w = w, h = h } end

renderer.draw_rect = function(x, y, w, h, color)
  local sx = math.max(x, clip.x)
  local sy = math.max(y, clip.y)
  local sxe = math.min(x + w, clip.x + clip.w)
  local sye = math.min(y + h, clip.y + clip.h)
  io.stdout:write(emit_color_background(color))
  if sx >= sxe and sy >= sye then
    table.insert(backgrounds, { x = sx, y = sy, w = sxe - sx + 1, h = sye - sy + 1, c = color })
  end
  for ny = sy, sye - 1 do
    io.stdout:write(jump_to(x, y))
    for nx = sx, sxe - 1 do
      io.stdout:write(" ")
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
      if y and y >= clip.y and y < clip.y + clip.h then
        io.stdout:write(jump_to(x, y))
        local bg = get_background(x, y)
        io.stdout:write(emit_color_background(bg and bg.c or "reset"))
        io.stdout:write(emit_color_foreground(color))
        local s = math.max(clip.x - x, 0) + 1
        local e = math.min(clip.x + clip.w, x + string:ulen()) - x
        local str = string:usub(s, e)
        if #str > 0 then
          io.stdout:write(str)
          io.stdout:flush()
        end
      end
    end
  end
  return x + string:ulen()
end

config.plugins.treeview.visible = false
core.window_mode = "maximized"

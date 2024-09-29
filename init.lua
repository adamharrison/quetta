-- mod-version:4 priority:0

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"
local keymap = require "core.keymap"
local NagView = require "core.nagview"
local DocView = require "core.docview"


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
  restore = true,
  -- how many lines we should scroll by on mousewheel
  scroll_speed = 5,
  color_model = os.getenv("COLORTERM") == "truecolor" and "24bit" or "8bit",
  -- checks the exectuable name for this, and only engages if the executing program is this. traditionally "quetta".
  invoke_only_on_executable_name = nil
}, config.plugins.quetta)

if (not config.plugins.quetta.invoke_only_on_executable_name or common.basename(ARGS[1]):find("^" .. config.plugins.quetta.invoke_only_on_executable_name .. "$")) and os.getenv("TERM") then
  local libquetta = require "plugins.quetta.libquetta"
  local status, success_or_err = libquetta.init(config.plugins.quetta.restore, config.plugins.quetta.color_model, function()
      io.stdout:write("\x1B[2J");
      if config.plugins.quetta.mouse_tracking then io.stdout:write("\x1B[?1003l") end
      if config.plugins.quetta.disable_cursor then io.stdout:write("\x1B[?25h") end
      if config.plugins.quetta.use_alternate_buffer then io.stdout:write("\x1B[?47l") end
      io.stdout:write("\x1B[39m");
      io.stdout:write("\x1B[49m");
      io.stdout:write("\x1B8")
      io.stdout:flush()
      libquetta.read(0)
  end) 
  if not status then error(success_or_err) end
  if success_or_err then
    io.stdout:write("\x1B7")
    if config.plugins.quetta.disable_cursor then io.stdout:write("\x1B[?25l") end -- Disable cursor.
    if config.plugins.quetta.use_alternate_buffer then io.stdout:write("\x1B[?47h") end -- Use alternate screen buffer.
    if config.plugins.quetta.mouse_tracking then io.stdout:write("\x1B[?1003h") end -- Enable mouse tracking.
    io.stdout:flush()

    function system.window_has_focus(window) return true end
    function system.get_window_size(window) 
      local w, h = libquetta.size()
      return w, h, 0, 0 
    end
    -- function system.set_window_size(window)   end
    if rawget(_G, "renwindow") then
      function renwindow:get_size() return libquetta.size() end
      function renwindow.create() return setmetatable({}, renwindow) end
      function renwindow.__restore() return setmetatable({}, renwindow) end
      function system.set_window_title(window, title) return io.stdout:write("\x1B]0;" .. title .. "\x07") end
      function system.set_window_mode(window) return 0 end
      function system.get_window_mode(window) return 0 end
      function system.set_window_size(window) end
    else
      function renderer:get_size() return libquetta.size() end
    end
    function NagView:get_buttons_height() return 1 end

    local function translate_color(color)
      if not color then return 0 end
      if config.plugins.quetta.color_model == "24bit" then
        return (tonumber(color[1]) << 24) | (tonumber(color[2]) << 16) | (tonumber(color[3]) << 8) | math.floor(tonumber(color[4]))
      end
      return (math.floor(color[1] * 5 / 256 + 0.5) * 36) + (math.floor((color[2] / 256 * 5 + 0.5)) * 6) + math.floor((color[3] / 256 * 5 + 0.5)) + 16
    end

    renderer.font.load = function(path) return setmetatable({}, renderer.font) end
    renderer.font.get_height = function() return 1 end

    local size_x, size_y = libquetta.size()
    local old_size_x, old_size_y
    renderer.begin_frame = function(...)
      size_x, size_y = libquetta.size()
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
      ["\x1B%[1;?(%d?)P"] = "f1",
      ["\x1B%[1;?(%d?)Q"] = "f2",
      ["\x1B%[1;?(%d?)R"] = "f3",
      ["\x1B%[1;?(%d?)S"] = "f4",
      ["\x1B%[15;?(%d?)~"] = "f5",
      ["\x1B%[16;?(%d?)~"] = "f6",
      ["\x1B%[17;?(%d?)~"] = "f7",
      ["\x1B%[18;?(%d?)~"] = "f8",
      ["\x1B%[19;?(%d?)~"] = "f9",
      ["\x1B%[20;?(%d?)~"] = "f10",
      ["\x1B%[21;?(%d?)~"] = "f11",
      ["\x1B%[22;?(%d?)~"] = "f12"
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
          local button_id = modifier & 0x3
          if (modifier & 0x40) > 0 then
            return "mousewheel", (button_id == 0 and 1 or -1) * (1 / size_y) * config.plugins.quetta.scroll_speed, 0
          elseif (modifier & 0x20) > 0 then
            if not last_cursor then last_cursor = { x, y } end
            return "mousemoved", x, y, x - last_cursor[1], y - last_cursor[2]
          else 
            last_cursor = { x, y }
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
      if accumulator:find("^\x1BO.") then accumulator = "" return "keypressed", "f" .. n:byte(3) - string.byte("O") end
      if #accumulator == 2 and accumulator == "\x1B\x7F" then accumulator = "" table.insert(queued_presses, "left alt") table.insert(queued_presses, "backspace") return system.poll_event() end
      if #accumulator == 1 and accumulator == "\x08" then accumulator = "" table.insert(queued_presses, "left ctrl") table.insert(queued_presses, "backspace") return system.poll_event() end
      if #accumulator == 3 and accumulator == "\x1B[Z" then accumulator = "" table.insert(queued_presses, "left shift") table.insert(queued_presses, "tab") return system.poll_event() end
      if #accumulator == 1 and accumulator == "\x7F" then accumulator = "" return "keypressed", "backspace" end
      if #accumulator == 1 and accumulator == "\x1B" then accumulator = "" return "keypressed", "escape" end
      if #accumulator == 1 and (accumulator == "\n" or accumulator == "\r") then accumulator = "" return "keypressed", "return" end
      if #accumulator == 1 and accumulator == "\t" then accumulator = "" return "keypressed", "tab" end
      if accumulator:find("^\x1B[\x01-\x1F]") then
        table.insert(queued_presses, "left ctrl")
        table.insert(queued_presses, "left alt")
        table.insert(queued_presses, string.char(96 + accumulator:byte(2)))
        accumulator = accumulator:sub(3)
        return system.poll_event()
      end
      if accumulator:find("^[\x01-\x1F]") and not accumulator:sub(2,2):find("%[") then
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
      accumulator = ""
      return "textinput", n:gsub("%c+", "")
    end

    core.step = function()
      local did_redraw = old_step()
      local read = libquetta.read(config.blink_period / 2)
      if read then
        accumulator = accumulator .. read
        core.redraw = true
      end
      return true
    end

    local clip = { x = 1, y = 1, w = size_x, h = size_y }
    renderer.set_clip_rect = function(x, y, w, h) clip = { x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) } end

    renderer.draw_rect = function(x, y, w, h, color)
      local sx = math.floor(math.max(x, clip.x))
      local sy = math.floor(math.max(y, clip.y))
      local sw = math.floor(math.min(x + w, clip.x + clip.w)) - sx
      local sh = math.floor(math.min(y + h, clip.y + clip.h)) - sy
      if sw > 0 and sh > 0 and (not color or not color[4] or color[4] > 0) then
        libquetta.draw_rect(sx, sy, sw, sh, translate_color(color))
      end
    end

    local old_draw = DocView.draw
    local indent = 4
    function DocView:draw()
      local _, indent_size = self.doc:get_indent_info()
      indent = indent_size
      old_draw(self)
      indent = 4
    end
    
    renderer.font.get_width = function(font, text) if type(text) ~= 'string' then return #tostring(text) end return text:gsub("\t", string.rep(" ", indent)):ulen() end
    renderer.draw_text = function(font, str, x, y, color)
      str = tostring(str):gsub("\t", string.rep(" ", indent))
      if x and y and (not color or not color[4] or color[4] > 0) and (y and y >= clip.y and y < clip.y + clip.h) then
        local s = math.floor(math.max(clip.x - x, 0) + 1)
        local e = math.floor(math.min(clip.x + clip.w, x + str:ulen()) - x)
        local trunc = str:usub(s, e)
        if #str > 0 then
          libquetta.draw_text(font, trunc, math.floor(x), math.floor(y), translate_color(color))
        end
      end
      return x + str:ulen()
    end

    style.padding = { x = 0, y = 0 }
    style.caret_width = 1
    style.scrollbar_size = 1
    style.expanded_scrollbar_size = 1
    style.tab_width = 20
    if style.margin then
      style.margin.tab.top = 0
    end
    style.divider_size = 0
    core.window_mode = "maximized"
    config.transitions = false
    config.tab_close_button = false
    
    -- Specific plugin configs for quetta that allow them to actually work with quetta.
    config.plugins.treeview.visible = false
    --config.plugins.treeview = false
    config.plugins.minimap = false
    config.plugins.build.drawer_size = 20
    config.plugins.debugger.drawer_size = 20
    config.plugins.tetris.cell_padding = 0 
    config.plugins.tetris.cell_size = 1

    -- rebind anything that's not already bound from shift to alt, because terminal emulators tend to dominate the shift-space.
    -- do this in two steps because if you remove things from the table while iterating it's unstable.
    local keys = {}
    for k,v in pairs(keymap.map) do
      if k:find("ctrl%+shift") then
        table.insert(keys, k)
      end
    end
    for _, k in pairs(keys) do
      for i,cmd in ipairs({ table.unpack(keymap.map[k]) }) do
        keymap.unbind(k, cmd)
        keymap.add({ [k:gsub("shift", "alt")] = cmd })
      end
    end
    keymap.add {
      ["ctrl+q"] = "core:quit",
      ["alt+pageup"] = "doc:select-to-previous-page",
      ["alt+pagedown"] = "doc:select-to-next-page"
    }
  end
else
  core.log_quiet("not starting quetta, either not named correctly or no $TERM variable")
end

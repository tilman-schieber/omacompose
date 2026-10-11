-- Omacompose: tells the Omarchy shell which keys follow the compose key, so
-- the io.github.tilman-schieber.omacompose overlay can show what comes next.
--
-- Pressing Multi_key (Caps Lock with compose:caps) enters a submap where every
-- key of the current layout has a bind that reports its keysym. All binds are
-- non-consuming: keys still reach the focused app, so compose itself works
-- exactly as before. The shell leaves the submap (omacompose.reset) once
-- the sequence is complete, dead, or idle.
--
-- Load from ~/.config/hypr/hyprland.lua:
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.tilman-schieber.omacompose/hypr/omacompose.lua")

local SUBMAP = "omacompose"
local IPC = "omarchy-shell -q omacompose update "

local state = { id = 0, seq = {} }
omacompose = state

local function send()
  hl.exec_cmd(IPC .. state.id .. " " .. (#state.seq > 0 and table.concat(state.seq, ",") or "-"))
end

local function start()
  state.id = state.id + 1
  state.seq = {}
  if hl.get_current_submap() ~= SUBMAP then hl.dispatch(hl.dsp.submap(SUBMAP)) end
  send()
end

local function leave()
  state.seq = {}
  if hl.get_current_submap() == SUBMAP then hl.dispatch(hl.dsp.submap("reset")) end
end

-- Called by the shell: `hyprctl eval 'omacompose.reset(<id>)'`. The id keeps
-- a late reset for one sequence from ending the next one.
function state.reset(id)
  if id == nil or tonumber(id) == state.id then leave() end
end

local function key(sym)
  state.seq[#state.seq + 1] = sym
  send()
end

-- Keys that end any compose sequence. Leaving the submap right here, rather
-- than waiting for the shell, keeps e.g. SUPER shortcuts working immediately.
local function cancel()
  leave()
  hl.exec_cmd(IPC .. state.id .. " !")
end

local function shell_quote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- { {level1, level2}, ... } for every key of the active layout(s).
local function layout_keys()
  local cmd = "xkbcli compile-keymap"
    .. " --layout " .. shell_quote(hl.get_config("input.kb_layout"))
    .. " --variant " .. shell_quote(hl.get_config("input.kb_variant"))
    .. " --options " .. shell_quote(hl.get_config("input.kb_options"))
    .. " 2>/dev/null"
  local pipe = io.popen(cmd)
  local keymap = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end

  local out = {}
  local symbols = keymap:match("xkb_symbols.*") or ""
  for body in symbols:gmatch("key%s+<[^>]+>%s*(%b{})") do
    for group in body:gmatch("%[([^%]]*)%]") do
      local levels = {}
      for sym in group:gmatch("[^,%s]+") do levels[#levels + 1] = sym end
      if levels[1] then out[#out + 1] = levels end
    end
  end
  return out
end

local IGNORE = {
  Shift_L = true, Shift_R = true, Caps_Lock = true, Num_Lock = true,
  ISO_Level3_Shift = true, ISO_Level5_Shift = true, NoSymbol = true, VoidSymbol = true,
}
local CANCEL = {
  Escape = true, BackSpace = true, Return = true, Tab = true, ISO_Left_Tab = true,
  Control_L = true, Control_R = true, Alt_L = true, Alt_R = true,
  Super_L = true, Super_R = true, Meta_L = true, Meta_R = true, Hyper_L = true, Hyper_R = true,
}

local function is_cancel(sym)
  return CANCEL[sym] or sym:match("^XF86") or sym:match("^F%d+$")
end

hl.bind("Multi_key", start, { non_consuming = true })
hl.bind("SHIFT + Multi_key", start, { non_consuming = true })

hl.define_submap(SUBMAP, function()
  local bound = {}
  local function bind(keys, fn, opts)
    if bound[keys] then return end
    bound[keys] = true
    opts = opts or {}
    opts.non_consuming = true
    hl.bind(keys, fn, opts)
  end

  for _, levels in ipairs(layout_keys()) do
    local base, shifted = levels[1], levels[2]
    if base == "Multi_key" then
      -- Compose pressed again mid-sequence: start over.
      bind(base, start, { ignore_mods = true })
    elseif IGNORE[base] then
      -- Modifiers that are part of typing a sequence.
    elseif is_cancel(base) then
      bind(base, cancel, { ignore_mods = true })
    elseif not shifted or shifted == "NoSymbol" or shifted == base then
      bind(base, function() key(base) end, { ignore_mods = true })
    else
      bind(base, function() key(base) end)
      bind("SHIFT + " .. base, function() key(shifted) end)
    end
  end
end)

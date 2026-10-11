-- Omacompose: tells the Omarchy shell which keys follow the compose key, so
-- the io.github.tilman-schieber.omacompose overlay can show what comes next.
--
-- Pressing Multi_key (Caps Lock with compose:caps) enters a submap where every
-- key of the current layout has a bind that reports its keysym. All binds are
-- non-consuming: keys still reach the focused app, so compose itself works
-- exactly as before. The shell leaves the submap (omacompose.reset) once
-- the sequence is complete, dead, or idle; a watchdog here leaves it too if
-- the shell never answers.
--
-- Load from ~/.config/hypr/hyprland.lua:
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.tilman-schieber.omacompose/hypr/omacompose.lua")

local SUBMAP = "omacompose"
local IPC = "omarchy-shell -q omacompose update "
-- Leave the submap after this long without a key, even if the shell is gone.
local WATCHDOG_MS = 10000

-- This file runs again on every config reload. Ids must keep growing across
-- reloads (the shell drops anything older than what it has seen), so they
-- start from the clock rather than from 0.
local previous = omacompose
local state = { id = math.max(previous and previous.id or 0, os.time() * 1000), msg = 0, seq = {} }
omacompose = state
if previous and previous.watchdog then pcall(previous.watchdog.set_enabled, previous.watchdog, false) end

local leave

local ok, timer = pcall(hl.timer, function()
  state.watchdog:set_enabled(false)
  leave()
end, { timeout = WATCHDOG_MS, type = "repeat" })
if ok and timer then
  state.watchdog = timer
  timer:set_enabled(false)
end

local function arm_watchdog()
  if not state.watchdog then return end
  state.watchdog:set_timeout(WATCHDOG_MS)
  state.watchdog:set_enabled(true)
end

-- Every message is a separate process, so they can arrive out of order:
-- `msg` lets the shell drop one that is older than what it has already seen.
local function send(seq)
  state.msg = state.msg + 1
  hl.exec_cmd(IPC .. state.id .. " " .. state.msg .. " " .. seq)
end

local function start()
  state.id = state.id + 1
  state.msg = 0
  state.seq = {}
  if hl.get_current_submap() ~= SUBMAP then hl.dispatch(hl.dsp.submap(SUBMAP)) end
  arm_watchdog()
  send("-")
end

function leave()
  state.seq = {}
  if state.watchdog then state.watchdog:set_enabled(false) end
  if hl.get_current_submap() == SUBMAP then hl.dispatch(hl.dsp.submap("reset")) end
end

-- Called by the shell: `hyprctl eval 'omacompose.reset(<id>)'`. The id keeps
-- a late reset for one sequence from ending the next one.
function state.reset(id)
  if id == nil or tonumber(id) == state.id then leave() end
end

local function key(sym)
  state.seq[#state.seq + 1] = sym
  arm_watchdog()
  send(table.concat(state.seq, ","))
end

-- Keys that end any compose sequence. Leaving the submap right here, rather
-- than waiting for the shell, keeps e.g. SUPER shortcuts working immediately.
local function cancel()
  leave()
  send("!")
end

local function shell_quote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- { {level1, level2, level3, level4}, ... } for every key of the configured
-- layout(s), first layout first. Per-device layouts aren't followed.
local function layout_keys()
  local cmd = "xkbcli compile-keymap"
  for _, opt in ipairs({ "layout", "variant", "options", "rules", "model" }) do
    local value = hl.get_config("input.kb_" .. opt)
    if value ~= nil and value ~= "" then cmd = cmd .. " --" .. opt .. " " .. shell_quote(value) end
  end
  cmd = cmd .. " 2>/dev/null"
  local pipe = io.popen(cmd)
  local keymap = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end

  local out = {}
  local symbols = keymap:match("xkb_symbols.*") or ""
  for raw in symbols:gmatch("key%s+<[^>]+>%s*(%b{})") do
    -- With several layouts, groups are written `symbols[1]= [ … ]`: drop the
    -- `symbols[1]` (and `actions[1]`, `type[1]`) labels, or `1` reads as a key.
    local body = raw:gsub("[%a_]+%[[^%]]*%]", "")
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

local function typed(sym)
  return sym and sym ~= "NoSymbol" and sym ~= "VoidSymbol"
end

local keys = layout_keys()

-- Without the keymap the submap would have no binds, not even the cancel
-- keys, so don't enter it at all.
if #keys > 0 then
  hl.bind("Multi_key", start, { non_consuming = true })
  hl.bind("SHIFT + Multi_key", start, { non_consuming = true })

  hl.define_submap(SUBMAP, function()
    local bound = {}
    local function bind(combo, fn, opts)
      if bound[combo] then return end
      bound[combo] = true
      opts = opts or {}
      opts.non_consuming = true
      hl.bind(combo, fn, opts)
    end

    for _, levels in ipairs(keys) do
      local base = levels[1]
      -- Hyprland matches binds against the unmodified keysym, so Shift and
      -- AltGr (MOD5) levels are resolved here from the keymap.
      local shifted = typed(levels[2]) and levels[2] ~= base and levels[2] or nil
      local level3 = typed(levels[3]) and levels[3] or nil
      local level4 = typed(levels[4]) and levels[4] or level3
      if base == "Multi_key" then
        -- Compose pressed again mid-sequence: start over.
        bind(base, start, { ignore_mods = true })
      elseif IGNORE[base] then
        -- Modifiers that are part of typing a sequence.
      elseif is_cancel(base) then
        bind(base, cancel, { ignore_mods = true })
      elseif not shifted and not level3 then
        bind(base, function() key(base) end, { ignore_mods = true })
      else
        bind(base, function() key(base) end)
        bind("SHIFT + " .. base, function() key(shifted or base) end)
        if level3 then
          bind("MOD5 + " .. base, function() key(level3) end)
          bind("MOD5 + SHIFT + " .. base, function() key(level4) end)
        end
      end
    end
  end)
end

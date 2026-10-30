local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local uv = vim.uv or vim.loop
local watched = {}
local M = {}

local function stop(state)
  local watcher = watched[state]
  if watcher then
    watcher.handle:stop()
    watcher.handle:close()
    watched[state] = nil
  end
end

M.watch = function(state, directory)
  if watched[state] and watched[state].directory == directory then
    return
  end
  stop(state)
  local handle, err = uv.new_fs_event()
  if not handle then
    log.warn("Cannot watch Git status: ", err)
    return
  end
  -- Own this handle independently of filesystem-source watcher reference counts.
  local ok
  ok, err = handle:start(directory, {}, function(watch_err, name)
    if watch_err or name and vim.endswith(name, ".lock") then
      return
    end
    vim.schedule(function()
      if watched[state] and watched[state].handle == handle and renderer.tree_is_visible(state) then
        -- GIT_EVENT already debounces bursts of index/HEAD changes.
        events.fire_event(events.GIT_EVENT)
      end
    end)
  end)
  if not ok then
    handle:close()
    log.warn("Cannot watch Git status: ", err)
    return
  end
  watched[state] = { directory = directory, handle = handle }
end

M.stop_hidden = function()
  for state in pairs(watched) do
    if state.disposed or not renderer.tree_is_visible(state) then
      stop(state)
    end
  end
end

M.stop_all = function()
  for state in pairs(watched) do
    stop(state)
  end
end

return M

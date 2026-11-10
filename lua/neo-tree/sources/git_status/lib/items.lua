local renderer = require("neo-tree.ui.renderer")
local file_items = require("neo-tree.sources.common.file-items")

local parser = require("neo-tree.git.parser")
local watch = require("neo-tree.sources.git_status.lib.watch")

local M = {}

-- Porcelain -z keeps whitespace/newlines literal and reports rename destinations first.
M.parse = function(output, root)
  local records = vim.split(output, "\0", { plain = true })
  local entries, i = {}, 1
  while i <= #records do
    local record = records[i]
    if #record >= 4 then
      local status = record:sub(1, 2)
      local entry = { path = root .. "/" .. record:sub(4), status = status }
      if status:find("R") or status:find("C") then
        i = i + 1
        entry.original_path = root .. "/" .. records[i]
      end
      entries[#entries + 1] = entry
    end
    i = i + 1
  end
  return entries
end

local changed = function(code)
  return code ~= " " and code ~= "." and code ~= "?" and code ~= "!"
end

-- Resolve against the old tree before replacing it: row numbers change when
-- entries move between sections or their now-empty parent directories disappear.
local preserve_selection = function(state, roots)
  if not state.tree or not renderer.tree_is_visible(state) then
    return
  end
  local node, line, last_line = state.tree:get_node(vim.api.nvim_win_get_cursor(state.winid)[1])
  if not node then
    return
  end
  local present = {}
  local function collect(items)
    for _, item in ipairs(items) do
      present[item.id] = true
      collect(item.children or {})
    end
  end
  collect(roots)
  local function select(candidate)
    if candidate and present[candidate:get_id()] then
      renderer.position.set(state, candidate:get_id())
      return true
    end
  end
  if select(node) then
    return
  end
  local after = false
  for _, sibling in ipairs(state.tree:get_nodes(node:get_parent_id())) do
    if after and select(sibling) then
      return
    end
    after = sibling:get_id() == node:get_id() or after
  end
  if not line then
    return
  end
  -- Includes the next section when the last entry in this one disappears.
  for row = (last_line or line) + 1, vim.api.nvim_buf_line_count(state.bufnr) do
    if select(state.tree:get_node(row)) then
      return
    end
  end
  -- At the end of the tree, prefer the nearest surviving item above it.
  for row = line - 1, 1, -1 do
    if select(state.tree:get_node(row)) then
      return
    end
  end
end

M.render = function(state, entries)
  local roots = {}
  state.default_expanded_nodes = {}
  for _, group in ipairs({ "unstaged", "staged" }) do
    local context = file_items.create_context()
    context.state = state
    local root = file_items.create_item(context, state.path, "directory")
    root.name = group == "staged" and "Staged" or "Unstaged"
    root.loaded = true
    context.folders[root.path] = root
    for _, entry in ipairs(entries) do
      local x, y = entry.status:sub(1, 1), entry.status:sub(2, 2)
      local conflict = parser.status_code_is_conflict(x, y)
      local include = group == "staged" and changed(x) and not conflict
        or group == "unstaged" and (changed(y) or entry.status == "??" or conflict)
      if include then
        local item = file_items.create_item(context, entry.path)
        if item.type == "unknown" then
          item.type = "file"
        end
        item.extra = {
          git_status = entry.status == "??" and "?"
            or conflict and entry.status
            or group == "staged" and (x .. ".")
            or ("." .. y),
          git_group = group,
          original_path = entry.original_path,
        }
      end
    end
    local function identify(item)
      -- IDs are unique across sections; path always remains the real filesystem path.
      item.id = "git_status:" .. group .. ":" .. item.path
      item.extra = item.extra or {}
      item.extra.git_group = group
      if item.children then
        item.loaded = true
        state.default_expanded_nodes[#state.default_expanded_nodes + 1] = item.id
        for _, child in ipairs(item.children) do
          identify(child)
        end
      end
    end
    identify(root)
    file_items.advanced_sort(root.children, state)
    roots[#roots + 1] = root
  end
  if state.git_status_reveal then
    for _, entry in ipairs(entries) do
      if entry.path == state.git_status_reveal then
        local group = changed(entry.status:sub(2, 2)) or entry.status == "??"
        renderer.position.set(
          state,
          "git_status:" .. (group and "unstaged" or "staged") .. ":" .. entry.path
        )
        break
      end
    end
    state.git_status_reveal = nil
  else
    preserve_selection(state, roots)
  end
  renderer.show_nodes(roots, state)
end

M.get_git_status = function(state, callback)
  renderer.acquire_window(state)
  state.git_status_scan = (state.git_status_scan or 0) + 1
  local scan = state.git_status_scan
  local function current()
    return scan == state.git_status_scan and renderer.tree_is_visible(state)
  end
  local function status(root)
    if not current() then
      return
    end
    state.path = root
    vim.system({
      "git",
      "--no-optional-locks",
      "-C",
      root,
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      "--ignore-submodules=none",
    }, {}, function(result)
      vim.schedule(function()
        if not current() then
          return
        end
        if result.code ~= 0 then
          vim.notify(result.stderr or "Git status failed", vim.log.levels.ERROR)
          return
        end
        M.render(state, M.parse(result.stdout, root))
        if type(callback) == "function" then
          vim.schedule(callback)
        end
      end)
    end)
  end
  vim.system({
    "git",
    "-C",
    state.path or vim.fn.getcwd(),
    "rev-parse",
    "--show-toplevel",
    "--absolute-git-dir",
  }, { text = true }, function(result)
    vim.schedule(function()
      if not current() then
        return
      end
      if result.code == 0 then
        local paths = vim.split(vim.trim(result.stdout), "\n", { plain = true })
        watch.watch(state, paths[2])
        status(paths[1])
      else
        renderer.show_nodes(
          { { id = "git_status:empty", name = "Not a Git repository", type = "message" } },
          state
        )
      end
    end)
  end)
end

return M

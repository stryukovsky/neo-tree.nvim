local file_items = require("neo-tree.sources.common.file-items")
local utils = require("neo-tree.utils")
local uv = vim.uv or vim.loop

local M = {}

---Find a changed leaf in display order, keeping the cursor anchor separate from targets.
---@param state neotree.sources.filesystem.State
---@param current_path string
---@param status neotree.git.Status
---@param reverse boolean?
---@return string?
M.target = function(state, current_path, status, reverse)
  local context = file_items.create_context(state)
  local root = file_items.create_item(context, state.path, "directory")
  local eligible = {}
  local include_untracked = require("neo-tree").peek_config().consider_untracked_as_git_change
  for path, code in pairs(status) do
    if
      code ~= "!"
      and (code ~= "?" or include_untracked)
      and utils.is_subpath(state.path, path)
    then
      local stat = uv.fs_stat(path)
      -- Parent-directory status bubbles are tables. A tracked directory reported
      -- directly by Git is a gitlink change and is navigable as a leaf target.
      local gitlink = type(code) == "string" and code ~= "?" and code ~= "!"
      if stat and (stat.type ~= "directory" or gitlink) then
        file_items.create_item(context, path)
        eligible[path] = true
      end
    end
  end
  if not next(eligible) then
    return nil
  end
  if current_path ~= state.path then
    if not utils.is_subpath(state.path, current_path) then
      return nil
    end
    file_items.create_item(context, current_path)
  end
  file_items.advanced_sort(root.children, state)

  local ordered, anchor = {}, nil
  local function visit(item)
    ordered[#ordered + 1] = item.path
    if item.path == current_path then
      anchor = #ordered
    end
    for _, child in ipairs(item.children or {}) do
      visit(child)
    end
  end
  visit(root)
  if not anchor then
    return nil
  end
  local step = reverse and -1 or 1
  for offset = 1, #ordered do
    local path = ordered[(anchor - 1 + step * offset) % #ordered + 1]
    if eligible[path] then
      return path
    end
  end
end

return M

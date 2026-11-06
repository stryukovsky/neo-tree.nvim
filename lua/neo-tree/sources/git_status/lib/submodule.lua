local map = require("mappings.map")

local M = {}
local ns = vim.api.nvim_create_namespace("neo-tree-submodule-status")

local function git(root, args)
  local cmd = { "git", "--no-optional-locks", "-C", root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, {}):wait(3000)
  return result.code == 0 and result.stdout or nil, result.stderr
end

local function records(output)
  return vim.split(output or "", "\0", { plain = true, trimempty = true })
end

-- Match exact gitlink paths, not ordinary folders containing submodules.
local function pins(root, relative)
  local pathspec = ":(literal)" .. relative
  local index, index_error = git(root, { "ls-files", "--stage", "-z", "--", pathspec })
  local head = git(root, { "ls-tree", "-z", "HEAD", "--", pathspec })
  local result = { stages = {}, error = not index and index_error or nil }
  for _, record in ipairs(records(index)) do
    local mode, hash, stage, path = record:match("^(%d+) (%x+) (%d)\t(.*)$")
    if mode == "160000" and path == relative then
      result.is_submodule = true
      result.stages[tonumber(stage)] = hash
    end
  end
  for _, record in ipairs(records(head)) do
    local hash, path = record:match("^160000 commit (%x+)\t(.*)$")
    if path == relative then
      result.is_submodule = true
      result.head = hash
    end
  end
  return result
end

M.collect = function(root, path)
  local relative = path:sub(#root + 2)
  local pin = pins(root, relative)
  if not pin.is_submodule then
    return nil
  end
  local data = { path = relative, head = pin.head, index = pin.stages[0], stages = pin.stages }
  data.error = pin.error
  local output, err = git(root, {
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
    "--ignore-submodules=none",
    "--",
    ":(literal)" .. relative,
  })
  if not output then
    data.error = err or "Unable to read parent status"
  end
  for _, record in ipairs(records(output)) do
    if record:sub(4) == relative then
      local x, y = record:sub(1, 1), record:sub(2, 2)
      data.staged = x ~= " " and x ~= "?"
      data.unstaged = y ~= " "
      data.conflict = require("neo-tree.git.parser").status_code_is_conflict(x, y)
      break
    end
  end
  -- An uninitialized submodule must not resolve HEAD from the parent repository.
  local prefix = git(path, { "rev-parse", "--show-prefix" })
  if prefix and vim.trim(prefix) == "" then
    local checkout = git(path, { "rev-parse", "--verify", "HEAD" })
    data.checkout = checkout and vim.trim(checkout) or nil
    local child, child_error =
      git(path, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
    if child then
      data.dirty = child ~= ""
    else
      data.child_error = child_error or "Unable to read checkout status"
    end
  end
  return data
end

M.show = function(data)
  local pending = data.checkout and data.head and data.checkout ~= data.head
    or data.checkout and not data.head
  local function short(hash)
    return hash and hash:sub(1, 8) or "unavailable"
  end
  local dirty = data.dirty == nil and "UNKNOWN" or data.dirty and "YES" or "NO"
  local change = pending and data.dirty and "commit + uncommitted changes"
    or pending and "commit change"
    or data.dirty and "uncommitted changes"
    or data.dirty == nil and "unavailable"
    or "no changes"
  local lines = {
    "uncommitted changes inside: " .. dirty,
    "HEAD in child: " .. short(data.checkout),
    "pinned in parent: " .. short(data.head),
  }
  if data.error or data.child_error then
    lines[#lines + 1] = "Read error: " .. vim.fn.strtrans(vim.trim(data.error or data.child_error))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "neo-tree-submodule-status"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " " .. change .. " ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[win].wrap = false
  vim.api.nvim_buf_set_extmark(buf, ns, 1, #"HEAD in child: ", {
    end_col = #lines[2],
    hl_group = pending and "DiagnosticError" or "DiagnosticInfo",
  })
  local group = vim.api.nvim_create_augroup("NeoTreeSubmoduleStatus" .. buf, { clear = true })
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  map("n", "q", close, { buffer = buf, desc = "Close submodule status" })
  map("n", "<Esc>", close, { buffer = buf, desc = "Close submodule status" })
  local function leave()
    vim.schedule(close)
  end
  vim.api.nvim_create_autocmd(
    { "WinLeave", "BufLeave" },
    { group = group, buffer = buf, callback = leave }
  )
  vim.api.nvim_create_autocmd(
    "WinClosed",
    { group = group, pattern = tostring(win), callback = leave }
  )
  vim.api.nvim_create_autocmd("FocusLost", { group = group, callback = leave })
  return win, buf
end

M.open = function(state)
  local node = state.tree:get_node()
  if not node or not node.path or not (node.extra and node.extra.git_status) then
    return false
  end
  local data = M.collect(state.path, node.path)
  if not data then
    return false
  end
  M.show(data)
  return true
end

return M

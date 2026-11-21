-- From plugin checkout: nvim --headless -u NONE -i NONE -l tests/git_status_staging_check.lua
local plugin = vim.fn.getcwd()
vim.opt.rtp:append(plugin)
for _, name in ipairs({ "nui.nvim", "plenary.nvim" }) do
  vim.opt.rtp:append(vim.fn.fnamemodify(plugin, ":h") .. "/" .. name)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
for _, name in ipairs({ "one.txt", "two with spaces.txt", "untouched.txt" }) do
  vim.fn.writefile({ name }, root .. "/" .. name)
end
local function git(args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
git({ "init", "-q" })
vim.cmd("cd " .. vim.fn.fnameescape(root))
require("neo-tree").setup({
  enable_diagnostics = false,
  enable_modified_markers = false,
  git_status = { window = { mappings = { s = "git_add_file", u = "git_unstage_file" } } },
})
require("neo-tree.command").execute({ source = "git_status", dir = root })
local state = require("neo-tree.sources.manager").get_state("git_status")
local renderer = require("neo-tree.ui.renderer")
local commands = require("neo-tree.sources.git_status.commands")
local function id(group, path)
  return "git_status:" .. group .. ":" .. root .. (path and "/" .. path or "")
end
local function wait_for(predicate)
  assert(vim.wait(5000, predicate, 10), "Timed out waiting for Git status")
end
local function node(group, path)
  return state.tree and state.tree:get_node(id(group, path))
end
wait_for(function()
  return node("unstaged", "untouched.txt")
end)
require("neo-tree.sources.git_status.lib.watch").stop_all()
assert(type(commands.git_add_file_visual) == "function", "Missing visual staging handler")
assert(type(commands.git_unstage_file_visual) == "function", "Missing visual unstaging handler")

-- Exercise the actual visual mapping, not just the command callback.
local function visual_action(group, key)
  renderer.focus_node(state, id(group, "one.txt"))
  vim.api.nvim_feedkeys("Vj" .. key, "xt", false)
end
visual_action("unstaged", "s")
wait_for(function()
  return node("staged", "one.txt") and node("staged", "two with spaces.txt")
end)
assert(git({ "diff", "--cached", "--name-only" }) == "one.txt\ntwo with spaces.txt")
assert(node("unstaged", "untouched.txt"), "Staged a file outside the selection")

-- Unstage the same range in an unborn repository, preserving working files.
visual_action("staged", "u")
wait_for(function()
  return not node("staged", "one.txt") and not node("staged", "two with spaces.txt")
end)
assert(git({ "diff", "--cached", "--name-only" }) == "")
assert(vim.fn.filereadable(root .. "/one.txt") == 1)

-- Check the HEAD/reset path as well.
git({ "add", "--", "one.txt", "two with spaces.txt", "untouched.txt" })
git({ "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial" })
for _, name in ipairs({ "one.txt", "two with spaces.txt", "untouched.txt" }) do
  vim.fn.writefile({ "changed" }, root .. "/" .. name)
end
commands.refresh(state)
wait_for(function()
  local n = node("unstaged", "one.txt")
  return n and n.extra.git_status ~= "??"
end)
visual_action("unstaged", "s")
wait_for(function()
  return node("staged", "one.txt") and node("staged", "two with spaces.txt")
end)
visual_action("staged", "u")
wait_for(function()
  return not node("staged", "one.txt") and not node("staged", "two with spaces.txt")
end)
assert(git({ "diff", "--cached", "--name-only" }) == "")
assert(git({ "diff", "--name-only" }) == "one.txt\ntwo with spaces.txt\nuntouched.txt")
print("Git status multiline staging checks passed")
require("neo-tree.sources.git_status.lib.watch").stop_all()
require("neo-tree.command").execute({ action = "close", source = "git_status" })
vim.cmd("cd " .. vim.fn.fnameescape(plugin))
vim.fn.delete(root, "rf")

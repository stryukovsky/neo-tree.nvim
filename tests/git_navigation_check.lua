-- From plugin checkout: nvim --headless -u NONE -i NONE -l tests/git_navigation_check.lua
local plugin = vim.fn.getcwd()
vim.opt.rtp:append(plugin)
for _, name in ipairs({ "nui.nvim", "plenary.nvim" }) do
  vim.opt.rtp:append(vim.fn.fnamemodify(plugin, ":h") .. "/" .. name)
end
local root = vim.fn.tempname()
local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(root .. "/" .. path, ":h"), "p")
  vim.fn.writefile({ content or path }, root .. "/" .. path)
end
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local out = vim.fn.system(args)
  assert(vim.v.shell_error == 0, out)
  return out
end
local count = 0
local function eq(want, got)
  count = count + 1
  assert(vim.deep_equal(want, got), vim.inspect({ expected = want, actual = got }))
end
local calls = {}
require("neo-tree").setup({
  consider_untracked_as_git_change = true,
  filesystem = { use_libuv_file_watcher = false },
  event_handlers = {
    {
      event = "before_git_status",
      handler = function(args)
        for _, arg in ipairs(args.status_args) do
          if arg:match("^%-%-untracked%-files=") then
            calls[#calls + 1] = arg
          end
        end
      end,
    },
  },
})
local config = require("neo-tree").ensure_config()
local target = require("neo-tree.sources.filesystem.lib.git_navigation").target
local state = { path = root }
for _, p in ipairs({ "a/deep/one.txt", "a/two.txt", "z.txt", "clean.txt", "Z.txt", "aa.txt" }) do
  write(p)
end
vim.fn.mkdir(root .. "/0-empty", "p")
git("init", "-q")
write("b/file.txt")
git("add", ".")
git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "fixture")
write(".gitignore", "*.log")
write("new/deep/two.txt")
write("new/one.txt")
write("new/ignored.log")
write("root-new.txt")
write("a/deep/one.txt", "modified")
local status = {}
for _, p in ipairs({ "a/deep/one.txt", "a/two.txt", "z.txt" }) do
  status[root .. "/" .. p] = ".M"
end
local function go(from, rev, s)
  local result = target(state, root .. "/" .. from, s or status, rev)
  return result and result:sub(#root + 2)
end
for _, case in ipairs({
  { "0-empty", "a/deep/one.txt" },
  { "a/deep/one.txt", "a/two.txt" },
  { "a/two.txt", "z.txt" },
  { "z.txt", "a/deep/one.txt" },
  { "clean.txt", "z.txt" },
}) do
  eq(case[2], go(case[1]))
end
for _, case in ipairs({
  { "a/deep/one.txt", "z.txt" },
  { "a/two.txt", "a/deep/one.txt" },
  { "z.txt", "a/two.txt" },
  { "clean.txt", "a/two.txt" },
}) do
  eq(case[2], go(case[1], true))
end
eq(
  "b/file.txt",
  go("0-empty", false, { [root .. "/b/file.txt"] = ".M", [root .. "/z.txt"] = ".M" })
)
eq("z.txt", go("clean.txt", true, { [root .. "/z.txt"] = ".M" }))
eq(nil, go("clean.txt", false, {}))
eq(nil, go("clean.txt", false, { [root .. "/missing"] = ".M", [root .. "/z.txt"] = "!" }))
config.sort_case_insensitive = true
eq("aa.txt", go("Z.txt", false, { [root .. "/Z.txt"] = ".M", [root .. "/aa.txt"] = ".M" }))
config.sort_case_insensitive = false
config.sort_function = function(a, b)
  return a.path > b.path
end
eq("a/two.txt", go("z.txt"))
config.sort_function = nil
state.sort_field_provider = function(item)
  return item.path
end
state.sort = { direction = -1 }
eq("a/deep/one.txt", go("z.txt"))
state.sort_field_provider = nil
state.sort = nil
state.sort_function_override = function(a, b)
  return a.path > b.path
end
eq("a/two.txt", go("z.txt"))
state.sort_function_override = nil

config.consider_untracked_as_git_change = false
eq(nil, go("clean.txt", false, { [root .. "/root-new.txt"] = "?" }))
config.consider_untracked_as_git_change = true
eq("root-new.txt", go("clean.txt", false, { [root .. "/root-new.txt"] = "?" }))
state.path = root .. "/a"
eq("a/deep/one.txt", go("a/two.txt"))
state.path = root
local gs = require("neo-tree.git")
local done = false
gs.status_async(root, nil, {}, function()
  done = true
end)
assert(
  vim.wait(10000, function()
    return done
  end, 10),
  "initial async timeout"
)
eq("--untracked-files=no", calls[1])
eq("--untracked-files=all", calls[2])
local function check_status(s)
  eq("?", s[root .. "/new/deep/two.txt"])
  eq("?", s[root .. "/root-new.txt"])
  assert(s[root .. "/new/ignored.log"] ~= "?")
end
check_status(gs.worktrees[root].status)
write("new/deep/added.txt")
vim.fn.delete(root .. "/new/one.txt")
gs.status_async(root, nil, {})
assert(vim.wait(10000, function()
  return gs.worktrees[root].status[root .. "/new/deep/added.txt"] == "?"
end, 10))
eq("--untracked-files=all", calls[#calls])
eq(nil, gs.worktrees[root].status[root .. "/new/one.txt"])
check_status(gs.status(root))
eq("--untracked-files=all", calls[#calls])
config.consider_untracked_as_git_change = false
gs.status(root)
eq("--untracked-files=normal", calls[#calls])
config.consider_untracked_as_git_change = true
gs.status(root)
require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = root })
local live = require("neo-tree.sources.manager").get_state("filesystem")
local renderer = require("neo-tree.ui.renderer")
assert(vim.wait(5000, function()
  return live.tree and live.tree:get_node(root .. "/0-empty")
end, 10))
renderer.focus_node(live, root .. "/0-empty")
local function press(keys, expected)
  vim.api.nvim_feedkeys(keys, "xt", false)
  assert(
    vim.wait(5000, function()
      local node = live.tree:get_node()
      return node and node:get_id() == root .. "/" .. expected
    end, 10),
    "mapping failed: " .. keys .. " -> " .. expected
  )
  count = count + 1
end
press("]g", "a/deep/one.txt")
press("]g", "new/deep/added.txt")
press("]g", "new/deep/two.txt")
press("[g", "new/deep/added.txt")
require("neo-tree.sources.filesystem.commands").close_all_nodes(live)
renderer.focus_node(live, root .. "/0-empty")
press("]g", "a/deep/one.txt")
-- Optionally exercise this config's layout-aware repeat-navigation wrapper too.
if vim.env.NEOTREE_CONFIG_ROOT then
  vim.opt.rtp:append(vim.env.NEOTREE_CONFIG_ROOT)
  vim.opt.rtp:append(vim.fn.fnamemodify(plugin, ":h") .. "/langmapper.nvim")
  require("mappings.neotree_git_navigation").attach(live)
  renderer.focus_node(live, root .. "/0-empty")
  press("]g", "a/deep/one.txt")
  press("]g", "new/deep/added.txt")
  press("[g", "a/deep/one.txt")
  eq("Neo-tree git change", require("utils.navigation_repeat").name())
end
local wt = gs.worktrees[root]
local saved = wt.status
wt.status = nil
require("neo-tree.sources.filesystem.commands").next_git_modified(live)
eq(root .. "/a/deep/one.txt", live.tree:get_node():get_id())
wt.status = saved
-- Real gitlink: changed checkout, staged pin, clean checkout, and dirty content.
local source = vim.fn.tempname()
vim.fn.mkdir(source, "p")
git("-C", source, "init", "-q")
vim.fn.writefile({ "initial" }, source .. "/file.txt")
git("-C", source, "add", ".")
git(
  "-C",
  source,
  "-c",
  "user.name=Test",
  "-c",
  "user.email=test@example.com",
  "commit",
  "-qm",
  "initial"
)
git("-c", "protocol.file.allow=always", "submodule", "add", "-q", source, "module")
git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "add submodule")
write("module/file.txt", "new commit")
git("-C", root .. "/module", "add", ".")
git(
  "-C",
  root .. "/module",
  "-c",
  "user.name=Test",
  "-c",
  "user.email=test@example.com",
  "commit",
  "-qm",
  "new pin"
)
local sub_status = gs.status(root)
eq(".M", sub_status[root .. "/module"])
eq("module", go("a/deep/one.txt", false, sub_status))
eq("module", go("new/deep/added.txt", true, sub_status))
eq("new/deep/added.txt", go("module", false, sub_status))
-- Ordinary directory bubbles and untracked directory summaries stay excluded.
eq(nil, go("0-empty", false, { [root .. "/a"] = { "M" }, [root .. "/new"] = "?" }))
renderer.focus_node(live, root .. "/a/deep/one.txt")
press("]g", "module")
press("]g", "new/deep/added.txt")
press("[g", "module")
git("add", "module")
sub_status = gs.status(root)
eq("M.", sub_status[root .. "/module"])
eq("module", go("a/deep/one.txt", false, sub_status))
git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "pin submodule")
eq(nil, gs.status(root)[root .. "/module"])
write("module/file.txt", "dirty")
sub_status = gs.status(root)
eq("module", go("a/deep/one.txt", false, sub_status))
vim.fn.delete(source, "rf")
vim.fn.delete(root, "rf")
print("PASS: " .. count .. " navigation/status checks")
vim.cmd("qa!")

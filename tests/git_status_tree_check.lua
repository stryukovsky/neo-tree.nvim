-- From plugin checkout: nvim --headless -u NONE -i NONE -l tests/git_status_tree_check.lua
local plugin = vim.fn.getcwd()
vim.opt.rtp:append(plugin)
for _, name in ipairs({ "nui.nvim", "plenary.nvim" }) do
  vim.opt.rtp:append(vim.fn.fnamemodify(plugin, ":h") .. "/" .. name)
end

local root = vim.fn.tempname()
local paths = { "a/one.txt", "a/two.txt", "b/three.txt", "c/four.txt", "z.txt" }
for _, path in ipairs(paths) do
  vim.fn.mkdir(vim.fn.fnamemodify(root .. "/" .. path, ":h"), "p")
  vim.fn.writefile({ path }, root .. "/" .. path)
end
assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)
vim.cmd("cd " .. vim.fn.fnameescape(root))
require("neo-tree").setup({ enable_diagnostics = false, enable_modified_markers = false })
require("neo-tree.command").execute({ source = "git_status", dir = root })

local state = require("neo-tree.sources.manager").get_state("git_status")
local renderer = require("neo-tree.ui.renderer")
local items = require("neo-tree.sources.git_status.lib.items")
local commands = require("neo-tree.sources.git_status.commands")
local function id(group, path)
  return "git_status:" .. group .. ":" .. root .. (path and "/" .. path or "")
end
local function wait_for(predicate)
  assert(vim.wait(5000, predicate, 10), "Timed out waiting for Git status")
end
local function node(group, path)
  return assert(state.tree:get_node(id(group, path)), id(group, path))
end
local function expanded(group, path, expected)
  assert(node(group, path):is_expanded() == expected, id(group, path) .. " expansion")
end
local function selected(group, path)
  assert(
    state.tree:get_node():get_id() == id(group, path),
    "Unexpected selection: " .. state.tree:get_node():get_id()
  )
end
local function render(staged, partial)
  local entries = {}
  for _, path in ipairs(paths) do
    entries[#entries + 1] = {
      path = root .. "/" .. path,
      status = partial == path and "MM" or staged[path] and "A " or "??",
    }
  end
  items.render(state, entries)
end
wait_for(function()
  return state.tree and state.tree:get_node(id("unstaged", "z.txt"))
end)
require("neo-tree.sources.git_status.lib.watch").stop_all()
expanded("unstaged", "a", true)
expanded("unstaged", "b", true)
node("unstaged", "b"):collapse()
render({})
expanded("unstaged", "a", true)
expanded("unstaged", "b", false)
node("unstaged"):collapse()
render({})
expanded("unstaged", nil, false)
expanded("staged", nil, true)
node("unstaged"):expand()
node("staged"):collapse()
render({})
expanded("staged", nil, false)
node("staged"):expand()

renderer.focus_node(state, id("unstaged", "a/one.txt"))
render({ ["a/one.txt"] = true })
selected("unstaged", "a/two.txt")
expanded("unstaged", "b", false)
expanded("staged", "a", false)
node("staged", "a"):expand()
node("unstaged", "a"):collapse()
renderer.focus_node(state, id("unstaged", "a"))
render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
selected("unstaged", "b")
expanded("staged", "a", true)
expanded("unstaged", "b", false)

renderer.focus_node(state, id("staged", "a/one.txt"))
render({ ["a/two.txt"] = true })
selected("staged", "a/two.txt")
expanded("staged", "a", true)
render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
renderer.focus_node(state, id("staged", "a/two.txt"))
render({})
selected("staged")

render({})
renderer.focus_node(state, id("unstaged", "c/four.txt"))
render({}, "c/four.txt")
selected("unstaged", "c/four.txt")
expanded("unstaged", "b", false)

-- Exercise real queued Git writes and asynchronous source refreshes.
render({})
renderer.focus_node(state, id("unstaged", "a/one.txt"))
commands.git_add_file(state)
renderer.focus_node(state, id("unstaged", "a/two.txt"))
commands.git_add_file(state)
wait_for(function()
  return state.tree:get_node(id("staged", "a/one.txt"))
    and state.tree:get_node(id("staged", "a/two.txt"))
end)
selected("unstaged", "b")
expanded("unstaged", "b", false)
expanded("staged", "a", false) -- A new folder is not forced open on refresh.
node("staged", "a"):expand()
renderer.focus_node(state, id("staged", "a/one.txt"))
commands.git_unstage_file(state)
wait_for(function()
  return not state.tree:get_node(id("staged", "a/one.txt"))
end)
selected("staged", "a/two.txt")
expanded("staged", "a", true)
renderer.focus_node(state, id("unstaged", "c"))
commands.git_add_file(state)
wait_for(function()
  return state.tree:get_node(id("staged", "c/four.txt")) ~= nil
end)
selected("unstaged", "z.txt")
expanded("unstaged", "b", false)
expanded("staged", "a", true)
expanded("staged", "c", false)
node("staged", "c"):expand()
renderer.focus_node(state, id("staged", "c"))
commands.git_unstage_file(state)
wait_for(function()
  return state.tree:get_node(id("staged", "c/four.txt")) == nil
end)
expanded("staged", "a", true)
expanded("unstaged", "b", false)
local refreshed = false
items.get_git_status(state, function()
  refreshed = true
end)
wait_for(function()
  return refreshed
end)
assert(not state.tree:get_node(id("staged", "a/one.txt")))
assert(state.tree:get_node(id("unstaged", "a/one.txt")))
expanded("unstaged", "b", false)
expanded("staged", "a", true)
print("Git status tree checks passed")
require("neo-tree.sources.git_status.lib.watch").stop_all()
vim.fn.delete(root, "rf")

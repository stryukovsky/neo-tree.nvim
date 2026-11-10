describe("Git status selection after refresh", function()
  local cwd
  before_each(function()
    cwd = vim.fn.getcwd()
    require("neo-tree").setup({
      enable_diagnostics = false,
      enable_git_status = false,
      enable_modified_markers = false,
    })
  end)
  after_each(function()
    vim.cmd("Neotree close")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  end)
  it(
    "restores selection by identity and follows surviving siblings before visible items",
    function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/a", "p")
      vim.fn.mkdir(root .. "/b", "p")
      local paths = { "a/one.txt", "a/two.txt", "b/three.txt", "z.txt" }
      for _, path in ipairs(paths) do
        vim.fn.writefile({ path }, root .. "/" .. path)
      end
      assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)
      vim.cmd("cd " .. vim.fn.fnameescape(root))
      require("neo-tree.command").execute({ source = "git_status", dir = root })
      local state = require("neo-tree.sources.manager").get_state("git_status")
      local renderer = require("neo-tree.ui.renderer")
      local items = require("neo-tree.sources.git_status.lib.items")
      local function id(group, path)
        return "git_status:" .. group .. ":" .. root .. (path and "/" .. path or "")
      end
      assert(vim.wait(5000, function()
        return state.tree and state.tree:get_node(id("unstaged", "z.txt")) ~= nil
      end, 10))
      require("neo-tree.sources.git_status.lib.watch").stop_all()
      -- Drive the render boundary directly to check old/new context without watcher timing.
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
      local function selected(group, path)
        assert.are.equal(id(group, path), state.tree:get_node():get_id())
      end
      render({})
      renderer.focus_node(state, id("unstaged", "a/one.txt"))
      render({ ["a/one.txt"] = true })
      selected("unstaged", "a/two.txt")
      -- Last child: its directory disappears, so follow the old next visible node.
      render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
      selected("unstaged", "b")
      -- An unrelated removal above the selection must not change the selected node.
      render({})
      renderer.focus_node(state, id("unstaged", "b/three.txt"))
      render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
      selected("unstaged", "b/three.txt")
      -- Skip multiple removed nodes; preserve displayed sibling order (including custom sort).
      render({})
      renderer.focus_node(state, id("unstaged", "a/one.txt"))
      render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
      selected("unstaged", "b")
      state.sort_function_override = function(a, b)
        return a.path > b.path
      end
      render({})
      renderer.focus_node(state, id("unstaged", "a/two.txt"))
      render({ ["a/two.txt"] = true })
      selected("unstaged", "a/one.txt")
      state.sort_function_override = nil
      -- A partially staged file still exists in the original section.
      render({})
      renderer.focus_node(state, id("unstaged", "a/one.txt"))
      render({}, "a/one.txt")
      selected("unstaged", "a/one.txt")
      -- Unstage follows the same identity rule even as the preceding section grows.
      render({ ["a/one.txt"] = true, ["a/two.txt"] = true })
      renderer.focus_node(state, id("staged", "a/one.txt"))
      render({ ["a/two.txt"] = true })
      selected("staged", "a/two.txt")
      -- End of tree: use the nearest surviving preceding item, not a stale row.
      render({})
      selected("staged")
      -- Last unstaged file follows the next section, whose row has moved upwards.
      render({ ["a/one.txt"] = true, ["a/two.txt"] = true, ["b/three.txt"] = true })
      renderer.focus_node(state, id("unstaged", "z.txt"))
      render({
        ["a/one.txt"] = true,
        ["a/two.txt"] = true,
        ["b/three.txt"] = true,
        ["z.txt"] = true,
      })
      selected("staged")
      -- Explicit reveals must continue to take priority over refresh selection.
      state.git_status_reveal = root .. "/z.txt"
      render({})
      selected("unstaged", "z.txt")
      vim.fn.delete(root, "rf")
    end
  )
end)

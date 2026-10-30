describe("Git status sections and queued index writes", function()
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
    "moves files between sections, preserves partial staging and serializes captured actions",
    function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/dir", "p")
      local function git(...)
        local result =
          vim.system(vim.list_extend({ "git", "-C", root }, { ... }), { text = true }):wait()
        assert(result.code == 0, result.stderr)
        return result.stdout
      end
      local function write(path, lines)
        vim.fn.writefile(lines, root .. "/" .. path)
      end
      git("init", "-q")
      git("config", "user.email", "test@example.com")
      git("config", "user.name", "Test")
      write("dir/both.txt", { "base" })
      write("deleted.txt", { "base" })
      git("add", ".")
      git("commit", "-qm", "initial")
      write("dir/both.txt", { "staged" })
      git("add", ".")
      write("dir/both.txt", { "working" })
      write("new file.txt", { "new" })
      vim.fn.delete(root .. "/deleted.txt")
      vim.cmd("cd " .. vim.fn.fnameescape(root))
      vim.cmd("Neotree git_status")
      local manager = require("neo-tree.sources.manager")
      local state = manager.get_state("git_status")
      local function id(group, path)
        return "git_status:" .. group .. ":" .. root .. (path and "/" .. path or "")
      end
      assert(
        vim.wait(5000, function()
          return state.tree and state.tree:get_node(id("unstaged", "new file.txt")) ~= nil
        end, 10),
        "initial tree timeout"
      )
      assert(
        state.tree:get_node(id("staged", "dir/both.txt")),
        "partial stage missing staged entry"
      )
      assert(
        state.tree:get_node(id("unstaged", "dir/both.txt")),
        "partial stage missing working entry"
      )
      assert(state.tree:get_node(id("unstaged", "deleted.txt")), "deleted file absent")
      local actions = require("neo-tree.sources.git_status.lib.actions")
      local selected = state.tree:get_node(id("unstaged", "new file.txt"))
      local fake = {
        path = root,
        tree = {
          get_node = function()
            return selected
          end,
        },
      }
      actions.enqueue(fake, "stage")
      -- Change the selection immediately: queued work must retain the original target.
      selected = state.tree:get_node(id("unstaged", "dir/both.txt"))
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("staged", "new file.txt")) ~= nil
        end, 10),
        "stage did not move file"
      )
      assert(
        not state.tree:get_node(id("unstaged", "new file.txt")),
        "staged file remains unstaged"
      )
      selected = state.tree:get_node(id("staged", "new file.txt"))
      actions.enqueue(fake, "unstage")
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("unstaged", "new file.txt")) ~= nil
        end, 10),
        "unstage did not move file"
      )
      -- Ordered stage/unstage burst must finish unstaged without index lock races.
      actions.enqueue(fake, "stage")
      actions.enqueue(fake, "unstage")
      assert(vim.wait(5000, function()
        return git("status", "--porcelain", "-z"):find("?? new file.txt", 1, true) ~= nil
      end, 10))
      vim.wait(250)
      assert(
        git("status", "--porcelain", "-z"):find("?? new file.txt", 1, true),
        "queue order lost"
      )
      -- Unborn repositories must support unstaging as well.
      local unborn = vim.fn.tempname()
      vim.fn.mkdir(unborn, "p")
      vim.system({ "git", "-C", unborn, "init", "-q" }):wait()
      vim.fn.writefile({ "hello" }, unborn .. "/new.txt")
      local unborn_state = {
        path = unborn,
        tree = {
          get_node = function()
            return { path = unborn .. "/new.txt", type = "file" }
          end,
        },
      }
      actions.enqueue(unborn_state, "stage")
      actions.enqueue(unborn_state, "unstage")
      vim.wait(1000)
      local out = vim
        .system({ "git", "-C", unborn, "status", "--porcelain" }, { text = true })
        :wait()
      assert(out.stdout == "?? new.txt\n", out.stdout)
      assert(vim.fn.filereadable(unborn .. "/new.txt") == 1)
      local items = require("neo-tree.sources.git_status.lib.items")
      local entries = items.parse("R  dest\0source\0?? a\nb\0", root)
      assert(
        #entries == 2
          and entries[1].original_path == root .. "/source"
          and entries[2].path == root .. "/a\nb"
      )
      local rename_lines = {}
      for i = 1, 30 do
        rename_lines[i] = "rename baseline line " .. i
      end
      write("dir/both.txt", rename_lines)
      git("add", "-A")
      git("commit", "-qm", "rename baseline")
      git("mv", "dir/both.txt", "dir/renamed.txt")
      rename_lines[#rename_lines + 1] = "edited after rename"
      write("dir/renamed.txt", rename_lines)
      require("neo-tree.sources.git_status.lib.items").get_git_status(state)
      assert(vim.wait(5000, function()
        return state.tree:get_node(id("unstaged", "dir/renamed.txt")) ~= nil
      end, 10))
      selected = state.tree:get_node(id("unstaged", "dir/renamed.txt"))
      actions.enqueue(fake, "stage")
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("staged", "dir/renamed.txt")) ~= nil
            and state.tree:get_node(id("unstaged", "dir/renamed.txt")) == nil
        end, 10),
        "edited staged rename could not be staged"
      )
      selected = state.tree:get_node(id("staged", "dir/renamed.txt"))
      actions.enqueue(fake, "unstage")
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("unstaged", "dir/both.txt")) ~= nil
        end, 10),
        "rename original path was not unstaged"
      )
      assert(git("diff", "--cached", "--name-only") == "", "rename left staged paths behind")
      -- Changes from a separate Git process must refresh without explicit events.
      git("add", "-A")
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("staged", "dir/renamed.txt")) ~= nil
        end, 10),
        "external staging did not refresh the tree"
      )
      git("commit", "-qm", "external commit")
      assert(
        vim.wait(5000, function()
          return state.tree:get_node(id("staged", "dir/renamed.txt")) == nil
            and state.tree:get_node(id("unstaged", "dir/renamed.txt")) == nil
        end, 10),
        "external commit left stale status nodes"
      )
      items.get_git_status(state)
      vim.cmd("Neotree close")
      vim.wait(150)
      assert(
        not require("neo-tree.ui.renderer").tree_is_visible(state),
        "completed scan reopened the closed panel"
      )
      vim.fn.delete(root, "rf")
      vim.fn.delete(unborn, "rf")
    end
  )
end)

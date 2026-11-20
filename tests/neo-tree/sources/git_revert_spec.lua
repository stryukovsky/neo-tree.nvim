describe("Git revert", function()
  local root, cwd, inputs, events, popups
  local confirm, fire_event, alert
  local confirmed, errors

  local function git(...)
    local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
  end

  local function write(path, text)
    vim.fn.writefile({ text }, root .. "/" .. path)
  end

  local function revert(path, node_type)
    require("neo-tree.sources.common.commands").git_revert_file({
      path = root,
      tree = {
        get_node = function()
          return { path = root .. path, name = path, type = node_type or "file" }
        end,
      },
    })
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/dir", "p")
    git("init", "-q")
    write("dir/tracked.txt", "original")
    write(".gitignore", "ignored.txt")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial")
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    inputs = require("neo-tree.ui.inputs")
    events = require("neo-tree.events")
    popups = require("neo-tree.ui.popups")
    confirm, fire_event, alert = inputs.confirm, events.fire_event, popups.alert
    confirmed, errors = true, {}
    inputs.confirm = function(_, callback)
      callback(confirmed)
    end
    events.fire_event = function() end
    popups.alert = function(title, result)
      errors[#errors + 1] = { title, result }
    end
  end)

  after_each(function()
    inputs.confirm, events.fire_event, popups.alert = confirm, fire_event, alert
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    vim.fn.delete(root, "rf")
  end)

  for _, path in ipairs({ "/dir", "" }) do
    it(
      "reverts tracked and untracked content under "
        .. (path == "" and "a section root" or "a folder"),
      function()
        write("dir/tracked.txt", "changed")
        write("dir/new file.txt", "new")
        write("dir/ignored.txt", "keep")
        revert(path, "directory")
        assert.are.same({ "original" }, vim.fn.readfile(root .. "/dir/tracked.txt"))
        assert.are.equal(0, vim.fn.filereadable(root .. "/dir/new file.txt"))
        assert.are.equal(1, vim.fn.filereadable(root .. "/dir/ignored.txt"))
        assert.are.equal("", git("status", "--porcelain"))
        assert.are.same({}, errors)
      end
    )
  end

  it("keeps changes outside the selected folder", function()
    write("dir/tracked.txt", "changed")
    write("dir/new.txt", "new")
    write("outside.txt", "keep")
    revert("/dir", "directory")
    assert.are.equal("?? outside.txt\n", git("status", "--porcelain"))
    assert.are.same({}, errors)
  end)

  it("removes an individual untracked file without reverting its sibling", function()
    write("dir/tracked.txt", "changed")
    write("dir/new [file].txt", "new")
    revert("/dir/new [file].txt")
    assert.are.equal(0, vim.fn.filereadable(root .. "/dir/new [file].txt"))
    assert.are.same({ "changed" }, vim.fn.readfile(root .. "/dir/tracked.txt"))
    assert.are.same({}, errors)
  end)

  it("does nothing when confirmation is declined", function()
    confirmed = false
    write("dir/tracked.txt", "changed")
    write("dir/new.txt", "new")
    local before = git("status", "--porcelain")
    revert("/dir", "directory")
    assert.are.equal(before, git("status", "--porcelain"))
    assert.are.same({}, errors)
  end)

  it("does not clean untracked files when checkout fails", function()
    vim.fn.mkdir(root .. "/added", "p")
    write("added/staged.txt", "new")
    git("add", "added/staged.txt")
    write("added/untracked.txt", "keep")
    revert("/added", "directory")
    assert.are.equal(1, #errors)
    assert.are.equal(1, vim.fn.filereadable(root .. "/added/untracked.txt"))
  end)
end)

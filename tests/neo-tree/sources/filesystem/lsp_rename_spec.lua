describe("Filesystem LSP rename", function()
  local rename = require("neo-tree.sources.filesystem.lib.lsp_rename")
  local root, source, destination, client, calls, warnings, notify, apply
  local function filter(glob, kind, scheme, ignore_case)
    return {
      filters = {
        {
          scheme = scheme,
          pattern = { glob = glob, matches = kind, options = { ignoreCase = ignore_case } },
        },
      },
    }
  end
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    source, destination = root .. "/old.lua", root .. "/new.lua"
    vim.fn.writefile({ "old" }, source)
    calls, warnings = {}, {}
    notify, apply = vim.notify, vim.lsp.util.apply_workspace_edit
    vim.notify = function(message)
      warnings[#warnings + 1] = message
    end
    client = {
      name = "test-lsp",
      initialized = true,
      offset_encoding = "utf-16",
      is_stopped = function()
        return false
      end,
      server_capabilities = {
        workspace = {
          fileOperations = {
            willRename = filter("**/*.lua", "file"),
            didRename = filter("**/*.lua", "file"),
          },
        },
      },
      request_sync = function(_, method, params, timeout)
        calls[#calls + 1] = method
        assert.equals(10000, timeout)
        assert.is_not_nil(vim.uv.fs_stat(source))
        assert.equals(vim.uri_from_fname(destination), params.files[1].newUri)
        return { result = { changes = {} } }
      end,
      notify = function(_, method, params)
        calls[#calls + 1] = method
        assert.equals(vim.uri_from_fname(source), params.files[1].oldUri)
        assert.is_not_nil(vim.uv.fs_stat(destination))
        return true
      end,
    }
    vim.lsp.util.apply_workspace_edit = function(_, encoding)
      calls[#calls + 1] = "apply"
      assert.equals("utf-16", encoding)
    end
  end)
  after_each(function()
    vim.notify, vim.lsp.util.apply_workspace_edit = notify, apply
    vim.fn.delete(root, "rf")
  end)
  it("matches only advertised file operations, not symbol rename", function()
    assert.is_true(rename.methods(client, source).willRename)
    client.server_capabilities = { renameProvider = true }
    assert.is_false(rename.methods(client, source).willRename)
    assert.is_false(rename.methods(client, source).didRename)
  end)
  it("respects glob, scheme, case, and file/folder filters", function()
    local operations = client.server_capabilities.workspace.fileOperations
    for _, option in ipairs({
      filter("**/*.rs"),
      filter("**/*", "folder"),
      filter("**/*", nil, "untitled"),
      filter("**/*.LUA"),
      { filters = {} },
    }) do
      operations.willRename = option
      assert.is_false(rename.methods(client, source).willRename)
    end
    local ignorecase = vim.o.ignorecase
    vim.o.ignorecase = true
    operations.willRename = filter("**/*.LUA")
    local case_sensitive = rename.methods(client, source).willRename
    vim.o.ignorecase = ignorecase
    assert.is_false(case_sensitive)
    operations.willRename = filter("**/*.LUA", "file", "file", true)
    assert.is_true(rename.methods(client, source).willRename)
  end)
  it("orders request, workspace edits, disk rename and notification", function()
    local hooks = rename.hooks({ client })
    hooks.before_rename(source, destination)
    assert.same({ "workspace/willRenameFiles", "apply" }, calls)
    assert(vim.uv.fs_rename(source, destination))
    hooks.after_rename(source, destination)
    assert.same({ "workspace/willRenameFiles", "apply", "workspace/didRenameFiles" }, calls)
    assert.equals(0, #warnings)
  end)
  it("retains folder-only notification matches after the source disappears", function()
    source, destination = root .. "/folder", root .. "/renamed"
    vim.fn.mkdir(source)
    client.server_capabilities.workspace.fileOperations = { didRename = filter("**/", "folder") }
    local hooks = rename.hooks({ client })
    hooks.before_rename(source, destination)
    assert(vim.uv.fs_rename(source, destination))
    hooks.after_rename(source, destination)
    assert.same({ "workspace/didRenameFiles" }, calls)
  end)
  it("does not use unselected, stopped, or uninitialized clients", function()
    rename.hooks({}).before_rename(source, destination)
    client.initialized = false
    rename.hooks({ client }).before_rename(source, destination)
    client.initialized = true
    client.is_stopped = function()
      return true
    end
    rename.hooks({ client }).before_rename(source, destination)
    assert.same({}, calls)
  end)
  it("does not request methods excluded by their own filters", function()
    client.server_capabilities.workspace.fileOperations.willRename = filter("**/*.rs")
    rename.hooks({ client }).before_rename(source, destination)
    assert.same({}, calls)
  end)
  it("warns on request timeout, protocol error, and exceptions", function()
    for _, request in ipairs({
      function()
        return nil, "timeout"
      end,
      function()
        return { err = { message = "server failed" } }
      end,
      function()
        error("transport failed")
      end,
    }) do
      client.request_sync = request
      rename.hooks({ client }).before_rename(source, destination)
    end
    assert.equals(3, #warnings)
    assert.same({}, calls)
  end)
  it("accepts null or empty edits without warning", function()
    for _, result in ipairs({ vim.NIL, {} }) do
      client.request_sync = function()
        return { result = result }
      end
      rename.hooks({ client }).before_rename(source, destination)
    end
    assert.equals(0, #warnings)
  end)
  it("warns on workspace edit failure", function()
    vim.lsp.util.apply_workspace_edit = function()
      error("bad edit")
    end
    rename.hooks({ client }).before_rename(source, destination)
    assert.equals(1, #warnings)
    assert.is_truthy(warnings[1]:find("cannot apply reference edits", 1, true))
  end)
  it("warns when a notification cannot be sent", function()
    local hooks = rename.hooks({ client })
    hooks.before_rename(source, destination)
    client.notify = function()
      return false
    end
    hooks.after_rename(source, destination)
    assert.equals(1, #warnings)
  end)
  it("leaves reference edits modified without saving them", function()
    vim.lsp.util.apply_workspace_edit = apply
    local uri = vim.uri_from_fname(source)
    client.request_sync = function()
      return {
        result = {
          changes = {
            [uri] = {
              {
                range = {
                  start = { line = 0, character = 0 },
                  ["end"] = { line = 0, character = 3 },
                },
                newText = "new",
              },
            },
          },
        },
      }
    end
    rename.hooks({ client }).before_rename(source, destination)
    local buffer = vim.fn.bufnr(source)
    assert.is_true(vim.bo[buffer].modified)
    assert.same({ "new" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.same({ "old" }, vim.fn.readfile(source))
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
end)

describe("document_symbols debounced follow", function()
  local saved, state, handlers, pending, focused, source
  local modules = {
    "neo-tree.sources.document_symbols",
    "neo-tree.sources.manager",
    "neo-tree.sources.document_symbols.lib.symbols_utils",
    "neo-tree.ui.renderer",
    "neo-tree.utils",
  }
  before_each(function()
    saved, handlers, focused = {}, {}, {}
    for _, name in ipairs(modules) do
      saved[name] = package.loaded[name]
    end
    state = {
      tree = {},
      lsp_bufnr = vim.api.nvim_get_current_buf(),
      lsp_winid = vim.api.nvim_get_current_win(),
    }
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        return state
      end,
      subscribe = function(_, subscription)
        handlers[subscription.event] = subscription.handler
      end,
    }
    package.loaded["neo-tree.sources.document_symbols.lib.symbols_utils"] = {
      setup = function() end,
      get_symbol_by_loc = function(tree, loc)
        assert.are.equal(state.tree, tree)
        assert.are.same({ 0, 0 }, loc)
        return "symbol"
      end,
    }
    package.loaded["neo-tree.ui.renderer"] = {
      focus_node = function(_, id)
        focused[#focused + 1] = id
      end,
    }
    local utils = vim.tbl_extend("force", require("neo-tree.utils"), {
      is_real_file = function()
        return true
      end,
      debounce = function(_, callback)
        pending = callback
      end,
    })
    package.loaded["neo-tree.utils"] = utils
    package.loaded["neo-tree.sources.document_symbols"] = nil
    source = require("neo-tree.sources.document_symbols")
    source.setup({ follow_cursor = true }, {})
  end)
  after_each(function()
    for _, name in ipairs(modules) do
      package.loaded[name] = saved[name]
    end
  end)
  local function enqueue()
    handlers[require("neo-tree.events").VIM_CURSOR_MOVED]({ afile = "file.lua" })
    assert.is_function(pending)
  end
  it("follows the symbol when the tracked window still displays the buffer", function()
    vim.api.nvim_win_set_cursor(state.lsp_winid, { 1, 0 })
    enqueue()
    pending()
    assert.are.same({ "symbol" }, focused)
  end)
  it("ignores a window closed after scheduling while its buffer remains current", function()
    vim.cmd("vsplit")
    state.lsp_winid = vim.api.nvim_get_current_win()
    enqueue()
    vim.api.nvim_win_close(state.lsp_winid, true)
    assert.are.equal(state.lsp_bufnr, vim.api.nvim_get_current_buf())
    pending()
    assert.are.same({}, focused)
  end)
  it("ignores a tracked window that switched to another buffer", function()
    local current = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local tracked = vim.api.nvim_get_current_win()
    state.lsp_winid = tracked
    enqueue()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(tracked, other)
    vim.api.nvim_set_current_win(current)
    pending()
    assert.are.same({}, focused)
    vim.api.nvim_win_close(tracked, true)
    vim.api.nvim_buf_delete(other, { force = true })
  end)
  it("ignores follow before a symbol tree exists", function()
    enqueue()
    state.tree = nil
    pending()
    assert.are.same({}, focused)
  end)
  it("ignores follow before an editor window is assigned", function()
    enqueue()
    state.lsp_winid = nil
    pending()
    assert.are.same({}, focused)
  end)
end)

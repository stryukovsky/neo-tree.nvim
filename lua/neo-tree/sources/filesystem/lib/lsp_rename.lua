local M = {}

local function warn(client, message)
  vim.notify(("Neo-tree: %s file rename: %s"):format(client.name, message), vim.log.levels.WARN)
end

local function matches(filters, path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local kind = stat and stat.type == "directory" and "folder" or "file"
  path = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"):gsub("/+$", "")
  for _, filter in ipairs(filters or {}) do
    local pattern = filter.pattern
    if
      (not filter.scheme or filter.scheme == "file")
      and pattern
      and (not pattern.matches or pattern.matches == kind)
    then
      local regex = ((pattern.options or {}).ignoreCase and [[\c]] or [[\C]])
        .. vim.fn.glob2regpat(pattern.glob)
      if
        vim.fn.match(path, regex) ~= -1
        or (kind == "folder" and vim.fn.match(path .. "/", regex) ~= -1)
      then
        return true
      end
    end
  end
  return false
end

---Static file-operation support, optionally restricted to a source path.
---Symbol rename is unrelated. An absent/empty filter list does not match a path.
---@param client vim.lsp.Client
---@param path? string
---@return table<string, boolean>
function M.methods(client, path)
  local operations = ((client.server_capabilities or {}).workspace or {}).fileOperations or {}
  local methods = {}
  for _, method in ipairs({ "willRename", "didRename" }) do
    local capability = operations[method]
    methods[method] = type(capability) == "table"
      and (not path or matches(capability.filters, path))
  end
  return methods
end

---@param client vim.lsp.Client
---@return boolean
local function active(client)
  return client.initialized and not client:is_stopped()
end

---Only explicitly supplied clients participate. Neo-tree retains disk/buffer ownership.
---Request errors are best-effort warnings; workspace edits are never auto-saved.
---@param clients vim.lsp.Client[]
---@return neotree.sources.filesystem.RenameHooks
function M.hooks(clients)
  local notifications = {}
  return {
    before_rename = function(source, destination)
      notifications = {}
      local params = {
        files = {
          { oldUri = vim.uri_from_fname(source), newUri = vim.uri_from_fname(destination) },
        },
      }
      for _, client in ipairs(clients) do
        if active(client) then
          -- Capture folder matches while the source still exists on disk.
          local methods = M.methods(client, source)
          if methods.didRename then
            notifications[#notifications + 1] = client
          end
          if methods.willRename then
            local ok, response, err = pcall(function()
              return client:request_sync("workspace/willRenameFiles", params, 10000)
            end)
            if not ok or not response or response.err then
              warn(
                client,
                vim.inspect(
                  not ok and response or (response and response.err) or err or "request timed out"
                )
              )
            elseif response.result and response.result ~= vim.NIL then
              local applied, failure =
                pcall(vim.lsp.util.apply_workspace_edit, response.result, client.offset_encoding)
              if not applied then
                warn(client, "cannot apply reference edits: " .. tostring(failure))
              end
            end
          end
        end
      end
    end,
    after_rename = function(source, destination)
      local params = {
        files = {
          { oldUri = vim.uri_from_fname(source), newUri = vim.uri_from_fname(destination) },
        },
      }
      for _, client in ipairs(notifications) do
        if active(client) then
          local ok, sent = pcall(function()
            return client:notify("workspace/didRenameFiles", params)
          end)
          if not ok or not sent then
            warn(client, "could not send didRenameFiles: " .. tostring(sent))
          end
        end
      end
    end,
  }
end

return M

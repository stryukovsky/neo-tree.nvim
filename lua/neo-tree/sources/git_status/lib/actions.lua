local M = {}
local queues = {}

-- Serialize index writes per worktree. Keymaps capture paths now, never the cursor later.
M.enqueue = function(state, action, all)
  local node = state.tree and state.tree:get_node()
  if not all and (not node or node.type == "message") then
    return
  end
  local root = state.path
  local queue = queues[root]
  if not queue then
    queue = { pending = {} }
    queues[root] = queue
  end
  local paths = {}
  if not all then
    paths[1] = node.path
    local extra = node.extra or {}
    local worktree_rename = extra.git_status == ".R" or extra.git_status == ".C"
    if extra.original_path and (action == "unstage" or worktree_rename) then
      paths[#paths + 1] = extra.original_path
    end
  end
  queue.pending[#queue.pending + 1] = { action = action, paths = paths, all = all }

  if queue.running or queue.scheduled then
    return
  end
  queue.scheduled = true
  vim.defer_fn(function()
    queue.scheduled = false
    local function next_action()
      local entry = table.remove(queue.pending, 1)
      if not entry then
        queue.running = false
        queues[root] = nil
        -- One refresh after the burst; errors are reconciled against actual Git state too.
        require("neo-tree.events").fire_event(require("neo-tree.events").GIT_EVENT)
        return
      end
      queue.running = true
      local cmd = { "git", "-C", root }
      if entry.action == "stage" then
        vim.list_extend(cmd, { "add", "-A" })
      else
        -- Remove only index entries when there is no HEAD yet; keep working files.
        vim.list_extend(cmd, { "rm", "--cached", "-r", "-f", "--ignore-unmatch" })
      end
      local function run(args, callback)
        vim.system(args, { text = true }, function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              vim.notify(result.stderr or "Git action failed", vim.log.levels.ERROR)
            end
            callback()
          end)
        end)
      end
      local function execute()
        cmd[#cmd + 1] = "--"
        vim.list_extend(cmd, entry.all and { root } or entry.paths)
        run(cmd, next_action)
      end
      if entry.action == "unstage" then
        vim.system({ "git", "-C", root, "rev-parse", "--verify", "HEAD" }, {}, function(result)
          vim.schedule(function()
            if result.code == 0 then
              cmd = { "git", "-C", root, "reset", "-q", "HEAD" }
            end
            execute()
          end)
        end)
      else
        execute()
      end
    end
    next_action()
  end, 25)
end

return M

--- Socket transport for pi-nvim: discovery and messaging.
---
--- Handles Unix socket discovery (config > cwd-based > latest symlink)
--- and sending raw JSON messages to the pi editor.

local M = {}

--- Resolve the socket path to use.
--- Priority: config override > cwd-based > latest symlink
--- @return string|nil
function M.get_socket_path()
  local pi = require("pi-nvim")
  if pi.config.socket_path then
    return pi.config.socket_path
  end

  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()

  -- Scan the sockets directory for .info files
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if ok and files then
    -- First pass: exact cwd match, prefer newest socket
    local best_sock = nil
    local best_mtime = 0
    for _, info_path in ipairs(files) do
      local content_ok, content = pcall(vim.fn.readfile, info_path)
      if content_ok and content and content[1] then
        local parsed_ok, info = pcall(vim.json.decode, content[1])
        if parsed_ok and info then
          local sock = info_path:sub(1, -6) -- strip ".info"
          local stat = vim.uv.fs_stat(sock)
          if info.cwd == cwd and stat then
            if stat.mtime.sec > best_mtime then
              best_mtime = stat.mtime.sec
              best_sock = sock
            end
          end
        end
      end
    end
    if best_sock then return best_sock end

    -- Second pass: any live session (newest)
    for _, info_path in ipairs(files) do
      local sock = info_path:sub(1, -6)
      local stat = vim.uv.fs_stat(sock)
      if stat then
        if stat.mtime.sec > best_mtime then
          best_mtime = stat.mtime.sec
          best_sock = sock
        end
      end
    end
    if best_sock then return best_sock end
  end

  -- Fall back to latest symlink
  local latest = "/tmp/pi-nvim-latest.sock"
  if vim.uv.fs_stat(latest) then
    return latest
  end

  return nil
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found. Is pi running with pi-nvim extension?"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

--- Ping the pi session to check connectivity.
--- @param cb fun(err: string|nil, is_alive: boolean)|nil
function M.ping(cb)
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      if cb then cb(err, false) end
      return
    end
    if resp and resp.type == "pong" then
      if cb then cb(nil, true) end
    else
      if cb then cb("Unexpected response from pi", false) end
    end
  end)
end

--- List all running pi sessions.
--- @return table[]  Array of session info tables
function M.list_sessions()
  local pi = require("pi-nvim")
  local sockets_dir = "/tmp/pi-nvim-sockets"
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    return {}
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock) ~= nil
        if alive then
          -- Format start time as relative or short time
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              -- Parse ISO 8601: "2026-03-01T14:10:09.123Z"
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            started = started,
            socket = sock,
          })
        end
      end
    end
  end

  return sessions
end

return M
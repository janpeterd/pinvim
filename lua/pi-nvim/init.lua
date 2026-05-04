local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
M.config = {
  socket_path = nil,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Transport layer (socket discovery and messaging)
  local transport = require("pi-nvim.transport")

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if transport.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Prompt buffer module (centralized, markdown, save-to-send)
  local prompt = require("pi-nvim.prompt")

  -- Commands
  vim.api.nvim_create_user_command("PiSend", function()
    prompt.open()
  end, { desc = "Open pi prompt buffer to compose a prompt" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Append current file to pi prompt buffer" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Append visual selection to pi prompt buffer" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Append entire buffer to pi prompt buffer" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    if selection then
      prompt.append_selection(selection.file, selection.text, selection.ft, selection.start_line, selection.end_line)
    end
    prompt.open()
  end, { range = true, desc = "Open pi prompt buffer (append selection if visual)" })

  vim.api.nvim_create_user_command("PiClearPrompt", function()
    prompt.clear()
    vim.notify("Pi prompt buffer cleared", vim.log.levels.INFO)
  end, { desc = "Clear the pi prompt buffer" })

  -- Default keymaps (all chords off <leader>p)
  -- Annotate
  vim.keymap.set("n", "<leader>pp", ":PiAnnotate<CR>", { silent = true, desc = "Annotate line" })
  vim.keymap.set("v", "<leader>pp", ":PiAnnotate<CR>", { silent = true, desc = "Annotate selection" })
  -- Send prompt (append to pi prompt buffer)
  vim.keymap.set("n", "<leader>ps", ":PiSend<CR>", { silent = true, desc = "Open pi prompt buffer" })
  vim.keymap.set("v", "<leader>ps", ":Pi<CR>", { silent = true, desc = "Append selection to pi prompt" })
  -- Send file / buffer (append to pi prompt buffer)
  vim.keymap.set("n", "<leader>pf", ":PiSendFile<CR>", { silent = true, desc = "Append file to pi prompt" })
  vim.keymap.set("n", "<leader>pb", ":PiSendBuffer<CR>", { silent = true, desc = "Append buffer to pi prompt" })
  -- Clear prompt
  vim.keymap.set("n", "<leader>pC", ":PiClearPrompt<CR>", { silent = true, desc = "Clear pi prompt buffer" })
  -- Sessions
  vim.keymap.set("n", "<leader>pP", ":PiSessions<CR>", { silent = true, desc = "Pi session picker" })

  vim.api.nvim_create_user_command("PiPing", function()
    transport.ping(function(err, is_alive)
      if err then
        vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
      elseif is_alive then
        vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
      else
        vim.notify("Unexpected response from pi", vim.log.levels.WARN)
      end
    end)
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    local sessions = transport.list_sessions()
    if #sessions == 0 then
      vim.notify("No pi sessions found", vim.log.levels.INFO)
      return
    end

    local items = {}
    local current = transport.get_socket_path()
    for _, s in ipairs(sessions) do
      local marker = (current == s.socket) and "●" or "○"
      local time_str = s.started ~= "" and string.format(" started %s", s.started) or ""
      table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, time_str))
    end

    vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
      if not choice or not idx then return end
      local session = sessions[idx]
      if session then
        -- Update config to use this session for future commands
        M.config.socket_path = session.socket
        vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
      end
    end)
  end, { desc = "List running pi sessions" })

  -- -- Annotation commands ----------------------------------------------
  local annotations = require("pi-nvim.annotations")

  vim.api.nvim_create_user_command("PiAnnotate", function(args)
    local bufnr = vim.api.nvim_get_current_buf()
    local start_line, end_line
    if args.range == 2 then
      start_line = args.line1
      end_line = args.line2
    else
      start_line = vim.fn.line(".")
      end_line = start_line
    end
    
    -- Capture filename NOW before opening the input popup
    local file = vim.fn.expand("%:.")
    local file_path = vim.fn.expand("%:p")
    
    -- Check for existing annotation at this line
    local existing = annotations.get_at_line(bufnr, start_line)
    local default_text = existing and existing.text or nil
    local update_id = existing and existing.id or nil
    
    annotations.open_input({
      start_line = start_line,
      end_line = end_line,
      default_text = default_text,
      update_id = update_id,
      file = file,
      file_path = file_path,
      on_submit = function(text, update_id)
        local item
        if update_id then
          item = annotations.add(bufnr, start_line, end_line, text, update_id, file, file_path)
          vim.notify(string.format("Annotation [%d] updated at L%d", item.id, start_line), vim.log.levels.INFO)
        else
          item = annotations.add(bufnr, start_line, end_line, text, nil, file, file_path)
          vim.notify(string.format("Annotation [%d] added at L%d", item.id, start_line), vim.log.levels.INFO)
        end
      end,
    })
  end, { range = true, desc = "Annotate current line or visual selection (updates existing)" })

  vim.api.nvim_create_user_command("PiAnnotations", function()
    annotations.show_quickfix()
  end, { desc = "Show all annotations in quickfix list" })

  vim.api.nvim_create_user_command("PiClearAnnotation", function(args)
    local id = tonumber(args.args)
    if not id then
      vim.notify("Usage: PiClearAnnotation <id>", vim.log.levels.ERROR)
      return
    end
    local removed = annotations.remove(vim.api.nvim_get_current_buf(), id)
    if removed then
      vim.notify(string.format("Annotation [%d] removed", id), vim.log.levels.INFO)
    else
      vim.notify(string.format("Annotation [%d] not found in current buffer", id), vim.log.levels.WARN)
    end
  end, { nargs = 1, desc = "Remove annotation by id from current buffer" })

  vim.api.nvim_create_user_command("PiClearAllAnnotations", function()
    local count = annotations.count()
    annotations.clear_all()
    vim.notify(string.format("Cleared %d annotation(s)", count), vim.log.levels.INFO)
  end, { desc = "Remove all annotations from all buffers" })

  vim.api.nvim_create_user_command("PiSendAnnotations", function()
    local count = annotations.count()
    if count == 0 then
      vim.notify("No annotations to append", vim.log.levels.WARN)
      return
    end

    local md = annotations.format_all_as_markdown()
    if md == "" then
      vim.notify("BUG: count=" .. count .. " but format returned empty string", vim.log.levels.ERROR)
      return
    end

    prompt.append_prompt(md)
    annotations.clear_all()  -- moved to prompt buffer, no longer pending
    vim.notify(string.format("Appended %d annotation(s) to prompt buffer", count), vim.log.levels.INFO)
    prompt.open()
  end, { desc = "Append all annotations to pi prompt buffer" })

  -- Keybindings for annotations (moved to annotation-focused keys)
  vim.keymap.set("n", "<leader>pl", ":PiAnnotations<CR>", { silent = true, desc = "List annotations" })
  vim.keymap.set("n", "<leader>pa", ":PiSendAnnotations<CR>", { silent = true, desc = "Append annotations to prompt" })
  vim.keymap.set("n", "<leader>pc", ":PiClearAllAnnotations<CR>", { silent = true, desc = "Clear all annotations" })

  -- Autocommand: append annotations to pi editor when Neovim closes.
  -- Uses vim.uv pipe with vim.wait to ensure the write completes before exit.
  -- Skips the prompt-buffer review step since Neovim is closing.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      local all = annotations.get_all()
      if #all == 0 then return end
      local sock_path = transport.get_socket_path()
      if not sock_path then return end

      local md = annotations.format_all_as_markdown()
      if md == "" then return end

      transport.send_raw({
        type = "append-editor",
        message = md,
      }, function(err, resp)
        -- Ignore response on exit, just ensure we tried
        if err then
          vim.notify("Failed to send annotations on exit: " .. err, vim.log.levels.WARN)
        end
      end)
    end,
    desc = "Append pi-nvim annotations to pi editor on exit",
  })
end



return M

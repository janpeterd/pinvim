local M = {}

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:."),
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

--- Open the Pi send dialog as two floating windows.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local pi = require("pi-nvim")
  local selection = opts.selection
  local file = vim.fn.expand("%:p")
  local rel_file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype
  local send_buffer = false
  local source_buf = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

  -- Build info lines
  local annotations = require("pi-nvim.annotations")
  local annotation_count = annotations.count()
  local file_info = "File: " .. (rel_file ~= "" and rel_file or "(no file)")
  local context_info
  if selection then
    local n = select(2, selection.text:gsub("\n", "")) + 1
    context_info = string.format("Selection: %d lines (%d-%d)", n, selection.start_line, selection.end_line)
  else
    context_info = "Send buffer: [ ] (Tab to toggle)"
  end
  local annotation_info = annotation_count > 0
    and string.format("Annotations: %d pending", annotation_count)
    or "Annotations: none"

  -- Layout
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = 3
  local max_input_height = 6
  local gap = 0 -- no gap between bubbles
  local top_row = math.floor((vim.o.lines - (info_height + 2 + gap + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_fg, bg = normal_hl.bg })

  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, {
    " " .. file_info,
    " " .. context_info,
    " " .. annotation_info,
  })
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[info_win].cursorline = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-prompt"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[input_win].wrap = true

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil((#line == 0 and 1 or #line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(input_win, new_height)
    -- Scroll so the cursor line is always visible (bottom of window)
    local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(input_win, function()
      vim.fn.winrestview({ topline = top_line })
    end)
  end

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Start in normal mode (user can press i for insert, v for visual, etc.)
  -- vim.cmd("noautocmd startinsert!")

  local closed = false

  local function close()
    if closed then return end
    closed = true
    vim.cmd("noautocmd stopinsert")
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  local function update_context()
    if selection then return end
    local marker = send_buffer and "[x]" or "[ ]"
    local line = " Send buffer: " .. marker .. " (Tab to toggle)"
    vim.bo[info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(info_buf, 1, 2, false, { line })
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local prompt_text = vim.fn.trim(table.concat(lines, "\n"))
    close()

    local prompt = require("pi-nvim.prompt")

    if selection then
      prompt.append_selection(selection.file, selection.text, selection.ft, selection.start_line, selection.end_line)
    elseif send_buffer and rel_file ~= "" then
      local content = table.concat(buf_lines, "\n")
      prompt.append_file(rel_file, content, ft)
    elseif file ~= "" then
      prompt.append_file(rel_file or file, "", ft)
    end

    if prompt_text ~= "" then
      prompt.append_prompt(prompt_text)
    end

    prompt.open()
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  -- Key mappings for all modes
  vim.keymap.set("i", "<CR>", send, kopts)
  vim.keymap.set("n", "<CR>", send, kopts)  -- Enter to send in normal mode
  vim.keymap.set({ "i", "n", "v" }, "<Esc>", close, kopts)
  vim.keymap.set({ "i", "n", "v" }, "<C-c>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<Tab>", function()
    if not selection then
      send_buffer = not send_buffer
      update_context()
    end
  end, kopts)

  -- Resize window as text is typed or cursor moves
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "CursorMoved", "WinScrolled" }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M

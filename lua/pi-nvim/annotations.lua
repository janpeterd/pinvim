--- Annotation system for pi-nvim.
--- Stores buffer-local annotations (line ranges + text) without modifying file content.
--- Uses signs in the gutter for visual markers. Annotations are sent to pi on VimLeavePre
--- or manually via :PiSendAnnotations.
---
--- State: { [bufnr] = { next_id = N, items = { {id, start_line, end_line, text, code?}[] } } }

local M = {}

-- Sign group for annotation markers
local SIGN_GROUP = "pi_nvim_annotations"

--- @class pi_nvim.Annotation
--- @field id number
--- @field start_line number  1-indexed
--- @field end_line number    1-indexed (same as start_line for single-line)
--- @field text string        Annotation text
--- @field file string        Relative file path
--- @field file_path string   Absolute file path
--- @field file_type string   Filetype (e.g. "typescript")
--- @field code string|nil    Source code for the annotated range

--- @class pi_nvim.BufferAnnotations
--- @field next_id number
--- @field items pi_nvim.Annotation[]

--- @type table<number, pi_nvim.BufferAnnotations>
local state = {}

--- Define the sign used for annotation markers.
local function define_sign()
  vim.fn.sign_define("PiAnnotation", {
    text = "▶",
    texthl = "PiNvimSign",
    linehl = "PiNvimLine",
  })
end

--- Set up highlight groups.
local function setup_highlights()
  local accent_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  local fg = accent_hl.fg or "#e5c07b"
  vim.api.nvim_set_hl(0, "PiNvimSign", { fg = fg, bg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "PiNvimLine", { bg = "#3a3a1a", default = true })
end

--- Get or create buffer annotation state.
--- @param bufnr number
--- @return pi_nvim.BufferAnnotations
local function get_buf_state(bufnr)
  if not state[bufnr] then
    state[bufnr] = { next_id = 1, items = {} }
  end
  return state[bufnr]
end

--- Place signs for all annotations in a buffer.
--- @param bufnr number
local function refresh_signs(bufnr)
  -- Remove existing signs
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })

  local buf = state[bufnr]
  if not buf then return end

  for _, item in ipairs(buf.items) do
    pcall(vim.fn.sign_place, 0, SIGN_GROUP, "PiAnnotation", bufnr, {
      lnum = item.start_line,
      priority = 10,
    })
  end
end

--- Add an annotation to a buffer.
--- @param bufnr number
--- @param start_line number  1-indexed
--- @param end_line number    1-indexed
--- @param text string
--- @return pi_nvim.Annotation
function M.add(bufnr, start_line, end_line, text)
  local buf = get_buf_state(bufnr)
  local id = buf.next_id
  buf.next_id = id + 1

  local file = vim.fn.expand("%:.")
  local file_path = vim.fn.expand("%:p")
  local file_type = vim.bo[bufnr].filetype

  -- Capture source code for the annotated range
  local code_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local code = table.concat(code_lines, "\n")

  local item = {
    id = id,
    start_line = start_line,
    end_line = end_line,
    text = text,
    file = file,
    file_path = file_path,
    file_type = file_type,
    code = code,
  }
  table.insert(buf.items, item)

  refresh_signs(bufnr)
  return item
end

--- Remove a specific annotation by id.
--- @param bufnr number
--- @param id number
--- @return boolean true if removed
function M.remove(bufnr, id)
  local buf = state[bufnr]
  if not buf then return false end

  for i, item in ipairs(buf.items) do
    if item.id == id then
      table.remove(buf.items, i)
      refresh_signs(bufnr)
      return true
    end
  end
  return false
end

--- Remove all annotations from a buffer.
--- @param bufnr number
function M.clear_buffer(bufnr)
  state[bufnr] = nil
  refresh_signs(bufnr)
end

--- Remove all annotations from all buffers.
function M.clear_all()
  for bufnr, _ in pairs(state) do
    refresh_signs(bufnr)
  end
  state = {}
end

--- Get all annotations for a buffer.
--- @param bufnr number
--- @return pi_nvim.Annotation[]
function M.get_buffer(bufnr)
  local buf = state[bufnr]
  if not buf then return {} end
  return buf.items
end

--- Get all annotations across all buffers.
--- @return pi_nvim.Annotation[]
function M.get_all()
  local all = {}
  for _, buf in pairs(state) do
    for _, item in ipairs(buf.items) do
      table.insert(all, item)
    end
  end
  return all
end

--- Count annotations across all buffers.
--- @return number
function M.count()
  local n = 0
  for _, buf in pairs(state) do
    n = n + #buf.items
  end
  return n
end

--- Count annotations in a specific buffer.
--- @param bufnr number
--- @return number
function M.count_buffer(bufnr)
  local buf = state[bufnr]
  if not buf then return 0 end
  return #buf.items
end

--- Show annotations in a quickfix list.
function M.show_quickfix()
  local items = {}
  for bufnr, buf in pairs(state) do
    for _, item in ipairs(buf.items) do
      table.insert(items, {
        bufnr = bufnr,
        lnum = item.start_line,
        end_lnum = item.end_line,
        text = string.format("[%d] %s", item.id, item.text),
        filename = item.file_path,
      })
    end
  end

  if #items == 0 then
    vim.notify("No annotations", vim.log.levels.INFO)
    return
  end

  vim.fn.setqflist(items, "r")
  vim.cmd("copen")
  vim.notify(string.format("%d annotation(s) in quickfix", #items), vim.log.levels.INFO)
end

--- Serialize all annotations for sending to pi via socket.
--- @return table[]
function M.serialize_all()
  local result = {}
  for _, buf in pairs(state) do
    for _, item in ipairs(buf.items) do
      table.insert(result, {
        file = item.file,
        filePath = item.file_path,
        startLine = item.start_line,
        endLine = item.end_line,
        text = item.text,
        fileType = item.file_type,
        code = item.code,
      })
    end
  end
  return result
end

--- Open floating input for annotation text.
--- Called from init.lua command handlers.
--- @param opts { start_line: number, end_line: number, on_submit: fun(text: string) }
function M.open_input(opts)
  local width = math.min(60, math.floor(vim.o.columns * 0.4))
  local height = 3
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "pi-nvim-annotation"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "" })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " annotate " .. (opts.start_line == opts.end_line
      and string.format("L%d", opts.start_line)
      : string.format("L%d-L%d", opts.start_line, opts.end_line)),
    title_pos = "center",
    zindex = 60,
    noautocmd = true,
  })

  -- Accent color for border
  local accent_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, "PiNvimAnnotationBorder", { fg = accent_hl.fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimAnnotationTitle", { fg = accent_hl.fg, bg = normal_hl.bg })
  vim.wo[win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimAnnotationBorder,FloatTitle:PiNvimAnnotationTitle"

  vim.cmd("noautocmd startinsert!")

  local closed = false

  local function submit()
    if closed then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.fn.trim(table.concat(lines, " "))
    close()
    if text ~= "" then
      opts.on_submit(text)
    end
  end

  local function close()
    if closed then return end
    closed = true
    vim.cmd("noautocmd stopinsert")
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true, silent = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", close, { buffer = buf, noremap = true, silent = true })
  vim.keymap.set({ "i", "n" }, "<C-c>", close, { buffer = buf, noremap = true, silent = true })
end

--- Send annotations to pi (fire-and-forget, for VimLeavePre).
--- Uses a blocking-ish approach via vim.uv pipe without waiting for response.
--- @param cb fun(success: boolean)|nil
function M.send_to_pi(cb)
  local all = M.get_all()
  if #all == 0 then
    if cb then cb(true) end
    return
  end

  local pi = require("pi-nvim")
  local sock_path = pi.get_socket_path()
  if not sock_path then
    if cb then cb(false) end
    return
  end

  local payload = vim.json.encode({
    type = "annotations",
    annotations = M.serialize_all(),
  }) .. "\n"

  local client = vim.uv.new_pipe(false)
  if not client then
    if cb then cb(false) end
    return
  end

  client:connect(sock_path, function(err)
    if err then
      if cb then vim.schedule(function() cb(false) end) end
      return
    end

    client:write(payload, function(write_err)
      if write_err then
        client:close()
        if cb then vim.schedule(function() cb(false) end) end
        return
      end

      -- Wait briefly for the response, then close
      local buf = ""
      client:read_start(function(read_err, data)
        if read_err then
          client:close()
          if cb then vim.schedule(function() cb(false) end) end
          return
        end
        if data then
          buf = buf .. data
          if buf:find("\n") then
            client:read_stop()
            client:close()
            if cb then vim.schedule(function() cb(true) end) end
          end
        else
          -- EOF
          client:close()
          if cb then vim.schedule(function() cb(true) end) end
        end
      end)
    end)
  end)
end

-- Initialize on load
define_sign()
setup_highlights()

return M

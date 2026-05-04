--- Pi prompt buffer: a centralized markdown buffer that aggregates
--- selections, files, and text. :w sends to pi editor; :wq/ZZ send+close.
---
--- Uses acwrite + BufWriteCmd — the same pattern Neogit uses
--- (they switched from BufUnload to this because :wq didn't fire BufUnload).

local M = {}

local prompt_buf = nil
local prompt_win = nil
local PROMPT_BUF_NAME = "pi-prompt.md"

local format = require("pi-nvim.format")
local transport = require("pi-nvim.transport")

-- -- helpers -----------------------------------------------------------

local function append_text(text)
	if not prompt_buf or not vim.api.nvim_buf_is_valid(prompt_buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
	local has_content = false
	for _, l in ipairs(lines) do
		if vim.fn.trim(l) ~= "" then
			has_content = true
			break
		end
	end

	local prefix = has_content and "\n\n" or ""
	local total = vim.api.nvim_buf_line_count(prompt_buf)
	vim.api.nvim_buf_set_lines(prompt_buf, total, total, false, vim.split(prefix .. text, "\n", { plain = true }))

	if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
		local last = vim.api.nvim_buf_line_count(prompt_buf)
		vim.api.nvim_win_set_cursor(prompt_win, { last, 0 })
	end
end

-- -- buffer management -------------------------------------------------

--- Get or create the prompt buffer.
--- @return number bufnr
function M.get_buffer()
	if prompt_buf and vim.api.nvim_buf_is_valid(prompt_buf) then
		return prompt_buf
	end

	prompt_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[prompt_buf].filetype = "markdown"
	vim.bo[prompt_buf].bufhidden = "hide"

	vim.api.nvim_buf_call(prompt_buf, function()
		vim.cmd("silent! file " .. PROMPT_BUF_NAME)
	end)

	-- acwrite: :w fires BufWriteCmd instead of writing to disk.
	vim.bo[prompt_buf].buftype = "acwrite"

	-- BufWriteCmd = the ONLY write handler. This fires on :w, :wq, ZZ, :x.
	-- We send the buffer content to the pi editor here.
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = prompt_buf,
		callback = function()
			M.send()
			vim.bo[prompt_buf].modified = false  -- let :wq / ZZ close the window
		end,
		desc = "Send pi prompt on :w",
	})

	-- Cleanup globals when buffer is eventually wiped.
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = prompt_buf,
		once = true,
		callback = function()
			prompt_buf = nil
			prompt_win = nil
		end,
		desc = "Clean up pi prompt globals on wipeout",
	})

	return prompt_buf
end

-- -- window management -------------------------------------------------

function M.open()
	local buf = M.get_buffer()

	if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
		vim.api.nvim_set_current_win(prompt_win)
		local last = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(prompt_win, { last, 0 })
		vim.cmd("startinsert!")
		return
	end

	vim.cmd("below split")
	prompt_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(prompt_win, buf)
	vim.api.nvim_win_set_height(prompt_win, 10)

	local last = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_win_set_cursor(prompt_win, { last, 0 })
	vim.cmd("startinsert!")
end

function M.close()
	if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
		vim.api.nvim_win_close(prompt_win, true)
		prompt_win = nil
	end
end

function M.clear()
	local buf = M.get_buffer()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
end

-- -- appending content -------------------------------------------------

function M.append_prompt(text)
	M.get_buffer()
	append_text(text)
end

function M.append_file(file, content, ft)
	M.get_buffer()
	if content == "" then
		append_text(format.file_reference(file))
	else
		append_text(format.code_block("File", file, ft, content))
	end
end

function M.append_selection(file, content, ft, start_line, end_line)
	M.get_buffer()
	append_text(format.code_block("Selection", file, ft, content, start_line, end_line))
end

-- -- sending -----------------------------------------------------------

--- Read the buffer and send to the pi editor via socket.
--- Called by BufWriteCmd (:w, :wq, ZZ, :x).
function M.send()
	local buf = M.get_buffer()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local text = table.concat(lines, "\n"):gsub("\n+$", "")

	if text == "" then
		vim.notify("Pi prompt buffer is empty", vim.log.levels.WARN)
		return
	end

	transport.send_raw({ type = "append-editor", message = text }, function(err, resp)
		if err then
			vim.notify("Failed to append to pi editor: " .. err, vim.log.levels.ERROR)
			return
		end
		if resp and resp.ok then
			vim.notify("Sent to pi editor. Review and press Enter to submit.", vim.log.levels.INFO)
		else
			vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
		end
	end)
end

return M


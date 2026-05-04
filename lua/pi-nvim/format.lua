--- Markdown formatting for pi-nvim.
---
--- Provides functions to format code blocks, file references, and annotations as markdown.

local M = {}

--- Format a code block with an optional header.
--- @param label string  Label shown before the file (e.g. "File", "Selection")
--- @param file string   File path (relative or absolute)
--- @param ft string     Filetype (e.g. "lua", "typescript")
--- @param content string The actual text content
--- @param start_line number|nil 1-indexed start line (optional)
--- @param end_line number|nil 1-indexed end line (optional)
--- @return string
function M.code_block(label, file, ft, content, start_line, end_line)
	local header
	if start_line and end_line then
		header = string.format("**%s:** `%s` lines %d-%d", label, file, start_line, end_line)
	else
		local nlines = select(2, content:gsub("\n", "")) + 1
		header = string.format("**%s:** `%s` (%d lines)", label, file, nlines)
	end
	local lang = (ft and ft ~= "") and ft or ""
	return string.format("%s\n```%s\n%s\n```\n", header, lang, content)
end

--- Format a file reference line.
--- @param file string File path
--- @return string
function M.file_reference(file)
	return string.format("**File:** `%s`\n", file)
end

--- Format all annotations as a markdown string (same format as pi extension).
--- @param annotations table[] Array of annotation tables (from annotations.serialize_all or annotations.get_all)
--- @return string
function M.annotations(annotations)
	if #annotations == 0 then return "" end

	-- Group by file
	local by_file = {}
	for _, a in ipairs(annotations) do
		if not by_file[a.file] then
			by_file[a.file] = {}
		end
		table.insert(by_file[a.file], a)
	end

	local lines = { "## Annotations from Neovim", "" }
	for file, anns in pairs(by_file) do
		table.sort(anns, function(a, b) return a.start_line < b.start_line end)
		-- Use absolute path if relative is empty
		local display_file = file
		if display_file == "" and anns[1] and anns[1].file_path then
			display_file = anns[1].file_path
		end
		table.insert(lines, "### " .. (display_file ~= "" and display_file or "(unnamed)"))
		table.insert(lines, "")
		for _, a in ipairs(anns) do
			-- Format: file:line or file:line-endline
			local range = a.start_line == a.end_line
				and string.format("%d", a.start_line)
				or string.format("%d-%d", a.start_line, a.end_line)
			local loc = string.format("**%s:%s**", display_file, range)
			
			-- Check if annotation text has multiple lines
			local is_multiline = a.text:find("\n", 1, true)
			
			if is_multiline then
				-- Multi-line annotation: use blockquote style for clear separation
				table.insert(lines, loc)
				-- Prefix each line with > for blockquote
				for _, line in ipairs(vim.split(a.text, "\n", { plain = true })) do
					table.insert(lines, "> " .. line)
				end
			else
				-- Single line: keep inline format
				table.insert(lines, loc .. ": " .. a.text)
		 end
			
			if a.code and vim.fn.trim(a.code) ~= "" then
				local ft = a.file_type or ""
				table.insert(lines, "")
				table.insert(lines, "```" .. ft)
				for _, cl in ipairs(vim.split(a.code, "\n", { plain = true })) do
					table.insert(lines, cl)
				end
				table.insert(lines, "```")
			end
			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

return M
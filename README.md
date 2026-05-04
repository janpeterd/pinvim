# pinvim

Bridge between [pi](https://pi.dev) coding agent and Neovim. **Pi is the source of truth** — spawn Neovim from pi in a tmux split, annotate code inline, and send it back to pi's prompt for review.

![demo](./demo/demo.gif)

## How it works

The repo contains two components:

1. **Pi extension** (`extension.ts`) — opens a unix socket when pi starts. Provides `/nvim` to spawn Neovim in a tmux split, and `/nvim-annotations` to load annotations into the pi editor.
2. **Neovim plugin** (`lua/pi-nvim/`) — connects to pi's socket via libuv. Adds an annotation system (gutter signs, NOT file comments) and sends annotations back to pi on exit or manually.

Discovery is automatic: the extension writes socket info to `/tmp/pi-nvim-sockets/`, and the Neovim plugin scans that directory, preferring sessions matching your cwd.

## Typical workflow

```
pi does work
  │
  ▼
/nvim          → spawns Neovim in a tmux split (Neogit dashboard by default)
  │
  ▼
review changes, open files, annotate with :PiAnnotate
  │
  ▼
close Neovim   → annotations auto-sent to pi via socket
  │
  ▼
/nvim-annotations → annotations appear in pi's prompt editor
  │
  ▼
review, edit, press Enter
```

## Install

### Pi side

```bash
pi install npm:pinvim
```

Or add to `~/.pi/agent/settings.json`:

```json
{
  "packages": ["https://github.com/janpeterd/pinvim"]
}
```

Then `/reload` in pi.

### Neovim side

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "janpeterd/pinvim" }
```

Then in your config:

```lua
require("pi-nvim").setup()
```

## Usage

Start pi inside tmux. The pi extension automatically opens a socket on session start.

### Pi commands

| Command | Description |
|---|---|
| `/nvim` | Open Neovim in a tmux split (defaults to Neogit dashboard) |
| `/nvim <file>` | Open Neovim with a specific file |
| `/nvim -v <file>` | Open in a vertical split |
| `/nvim-annotations` | Load received annotations into the editor for review |
| `/pi-nvim-info` | Show socket path |

### Neovim commands

**Prompt/context (existing):**

| Command | Description |
|---|---|
| `:Pi` | Open the Send to pi dialog (normal + visual mode) |
| `:PiSend` | Type a prompt and send to pi |
| `:PiSendFile` | Send current file path + prompt |
| `:PiSendSelection` | Send visual selection + prompt |
| `:PiSendBuffer` | Send entire buffer + prompt |
| `:PiPing` | Check if pi is reachable |
| `:PiSessions` | List/switch between running pi sessions |

**Annotation system (new):**

| Command | Description |
|---|---|
| `:PiAnnotate` | Annotate current line or visual selection (opens floating input) |
| `:PiAnnotations` | Show all annotations in a quickfix list |
| `:PiClearAnnotation <id>` | Remove annotation by ID from current buffer |
| `:PiClearAllAnnotations` | Remove all annotations from all buffers |
| `:PiSendAnnotations` | Manually send annotations to pi |

### Keybindings

| Key | Command | Description |
|-----|---------|-------------|
| `<leader>p` | `:Pi` | Open send dialog |
| `<leader>pa` | `:PiAnnotate` | Annotate line (normal) or selection (visual) |
| `<leader>pl` | `:PiAnnotations` | List annotations in quickfix |
| `<leader>ps` | `:PiSendAnnotations` | Send annotations to pi |
| `<leader>pc` | `:PiClearAllAnnotations` | Clear all annotations |

### Annotation system

Annotations use **signs in the gutter** (a ▶ marker) — your code files are never modified. When you annotate:

1. Place cursor on a line (or select a range in visual mode) and press `<leader>pa`
2. A floating input appears — type your annotation text and press Enter
3. A ▶ sign appears in the gutter for each annotated line
4. Annotations persist across buffer switches within the same Neovim session
5. When you close Neovim (`:q`), all annotations are automatically sent to pi
6. In pi, type `/nvim-annotations` to load them into the prompt editor

Annotations include the source code of the annotated range, so pi sees both your note and the code.

### The `:Pi` dialog

Opens a floating window in the center of the screen:

- Shows the current **file name** (always sent)
- Shows **annotation count** if you have pending annotations
- If you had a **visual selection**, it shows the line range and sends the selected text
- If no selection, you can press **Tab** to toggle sending the **entire buffer**
- Type a prompt and press **Enter** to send (or just Enter with no prompt)
- Press **Esc** or **Ctrl-C** to cancel

## Protocol

The socket accepts newline-delimited JSON:

```json
{"type": "prompt", "message": "your prompt here"}
{"type": "ping"}
{"type": "annotations", "annotations": [
  {"file": "src/auth.ts", "filePath": "/abs/path/src/auth.ts",
   "startLine": 42, "endLine": 42, "text": "fix this",
   "fileType": "typescript", "code": "function process() {"}
]}
```

Responses:

```json
{"ok": true}
{"ok": true, "type": "pong"}
{"ok": false, "error": "..."}
```

This means you can also send prompts from any tool:

```bash
echo '{"type":"prompt","message":"hello"}' | socat - UNIX-CONNECT:/tmp/pi-nvim-sockets/<hash>.sock
```

## Additional keybindings (optional)

```lua
vim.keymap.set("n", "<leader>pp", ":PiSend<CR>")
vim.keymap.set("n", "<leader>pf", ":PiSendFile<CR>")
vim.keymap.set("v", "<leader>ps", ":PiSendSelection<CR>")
vim.keymap.set("n", "<leader>pb", ":PiSendBuffer<CR>")
vim.keymap.set("n", "<leader>pi", ":PiPing<CR>")
```

## License

MIT

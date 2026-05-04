import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pinvim: Bridge between pi coding agent and Neovim.
 * https://github.com/janpeterd/pinvim
 *
 * Features:
 *   - Unix socket server so Neovim can send prompts/annotations into pi
 *   - /nvim [file] command — spawns Neovim in a tmux split (defaults to Neogit
 *     dashboard so you can quickly review changes)
 *   - /nvim-annotations — loads annotations received from Neovim into the pi
 *     editor for review/editing before sending
 *
 * Protocol (newline-delimited JSON over unix socket):
 *
 *   → { "type": "append-editor", "message": "..." }
 *   → { "type": "annotations", "annotations": [...] }
 *   → { "type": "ping" }
 *
 *   ← { "ok": true }
 *   ← { "ok": true, "type": "pong" }
 *   ← { "ok": false, "error": "..." }
 */

// -- Types --------------------------------------------------------------------

interface Annotation {
  file: string;
  filePath: string;
  startLine: number;
  endLine: number;
  text: string;
  fileType: string;
  code?: string;
}

// -- Socket helpers -----------------------------------------------------------

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

function getSocketPath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${cwdHash(cwd)}-${process.pid}.sock`);
}

const SOCKETS_DIR = "/tmp/pi-nvim-sockets";
const LATEST_LINK = "/tmp/pi-nvim-latest.sock";

// -- Annotation formatting ----------------------------------------------------

function formatAnnotations(annotations: Annotation[]): string {
  if (annotations.length === 0) return "";

  // Group by file
  const byFile = new Map<string, Annotation[]>();
  for (const a of annotations) {
    const existing = byFile.get(a.file) || [];
    existing.push(a);
    byFile.set(a.file, existing);
  }

  let text = "## Annotations from Neovim\n\n";

  for (const [file, anns] of byFile) {
    text += `### ${file}\n\n`;
    for (const a of anns) {
      const range =
        a.startLine === a.endLine
          ? `L${a.startLine}`
          : `L${a.startLine}-L${a.endLine}`;
      text += `**${range}**: ${a.text}\n`;
      if (a.code && a.code.trim()) {
        const ft = a.fileType || "";
        text += `\n\`\`\`${ft}\n${a.code.trim()}\n\`\`\`\n\n`;
      } else {
        text += "\n";
      }
    }
  }

  return text;
}

// -- Extension ----------------------------------------------------------------

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;

  // Stored annotations received from Neovim (loaded into editor via /nvim-annotations)
  let lastAnnotations: Annotation[] = [];

  // -- Socket server ------------------------------------------------------

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    socketPath = getSocketPath(cwd);

    try {
      fs.unlinkSync(socketPath);
    } catch {}

    server = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn, ctx);
        }
      });
      conn.on("error", () => {});
    });

    server.listen(socketPath, () => {
      // Update latest symlink
      try {
        fs.unlinkSync(LATEST_LINK);
      } catch {}
      try {
        fs.symlinkSync(socketPath!, LATEST_LINK);
      } catch {}

      // Write discovery info
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        fs.writeFileSync(
          socketPath + ".info",
          JSON.stringify({
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      } catch {}
    });

    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });
  });

  function handleMessage(
    raw: string,
    conn: net.Socket,
    ctx: { ui: any; cwd: string },
  ) {
    try {
      const msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" });
        return;
      }

      if (msg.type === "append-editor" && typeof msg.message === "string") {
        appendToEditor(msg.message, ctx);
        respond(conn, { ok: true });
        return;
      }

      if (
        msg.type === "annotations" &&
        Array.isArray(msg.annotations)
      ) {
        const annotations: Annotation[] = msg.annotations.map((a: any) => ({
          file: a.file || "",
          filePath: a.filePath || "",
          startLine: a.startLine || 0,
          endLine: a.endLine || 0,
          text: a.text || "",
          fileType: a.fileType || "",
          code: a.code || "",
        }));

        lastAnnotations = annotations;

        // Format and append to pi editor for review before submitting.
        const formatted = formatAnnotations(annotations);
        if (formatted) {
          appendToEditor(formatted, ctx);
        }

        const count = annotations.length;
        respond(conn, {
          ok: true,
          count,
          message: `Received ${count} annotation(s). Use /nvim-annotations to load them into the editor.`,
        });
        return;
      }

      respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` });
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` });
    }
  }

  /**
   * Append text to the pi editor, preserving any existing content.
   * The user reviews and presses Enter to submit.
   */
  function appendToEditor(text: string, ctx: { ui: any; cwd: string }) {
    if (!text) return;

    try {
      const current = ctx.ui.getEditorText();
      const newText = current
        ? current + "\n\n" + text
        : text;
      ctx.ui.setEditorText(newText);
      ctx.ui.notify(
        "Content appended to editor. Review and press Enter to submit.",
        "info",
      );
    } catch (err: any) {
      try {
        ctx.ui.notify(
          "Content received from Neovim but could not append to editor: " +
            (err?.message || String(err)),
          "error",
        );
      } catch {
        console.error("[pi-nvim] Failed to append to editor:", err);
      }
    }
  }

  function respond(conn: net.Socket, obj: any) {
    try {
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function cleanup() {
    if (server) {
      server.close();
      server = null;
    }
    try {
      fs.unlinkSync(socketPath!);
    } catch {}
    try {
      const target = fs.readlinkSync(LATEST_LINK);
      if (target === socketPath) fs.unlinkSync(LATEST_LINK);
    } catch {}
    try {
      fs.unlinkSync(socketPath + ".info");
    } catch {}
  }

  pi.on("session_shutdown", async () => {
    cleanup();
  });

  process.on("exit", cleanup);

  // -- Commands ------------------------------------------------------------

  pi.registerCommand("pi-nvim-info", {
    description: "Show pi-nvim socket path",
    handler: async (_args, ctx) => {
      if (socketPath) {
        ctx.ui.notify(`Socket: ${socketPath}`, "info");
      } else {
        ctx.ui.notify("pi-nvim not active", "warning");
      }
    },
  });

  pi.registerCommand("nvim-annotations", {
    description: "Load Neovim annotations into the editor for review",
    handler: async (_args, ctx) => {
      if (lastAnnotations.length === 0) {
        ctx.ui.notify(
          "No annotations received from Neovim yet. Annotate code in Neovim and close it to send them here.",
          "warning",
        );
        return;
      }

      const formatted = formatAnnotations(lastAnnotations);
      if (!formatted) {
        ctx.ui.notify("No annotation content to load", "warning");
        return;
      }

      const current = ctx.ui.getEditorText();
      const newText = current ? current + "\n\n" + formatted : formatted;
      ctx.ui.setEditorText(newText);
      ctx.ui.notify(
        `Appended ${lastAnnotations.length} annotation(s) to editor. Edit and press Enter to send.`,
        "info",
      );
    },
  });

  // Shared spawn logic (used by /nvim command and ctrl+v shortcut).
  // Always opens Neovim in a vertical tmux split.
  async function spawnNvim(
    fileArgs: string[],
    ctx: { ui: any; hasUI: boolean },
  ) {
    if (!ctx.hasUI) {
      ctx.ui.notify("/nvim requires interactive mode", "error");
      return;
    }

    if (!process.env.TMUX) {
      ctx.ui.notify(
        "Not inside a tmux session. Start pi inside tmux first.",
        "error",
      );
      return;
    }

    const tmuxArgs = ["split-window", "-v"];

    if (fileArgs.length > 0) {
      tmuxArgs.push("nvim", ...fileArgs);
    } else {
      // Default: open Neogit dashboard for reviewing changes
      // Falls back to plain nvim if Neogit is not installed
      tmuxArgs.push("nvim", "-c", "Neogit");
    }

    try {
      await pi.exec("tmux", tmuxArgs);
      const target =
        fileArgs.length > 0 ? fileArgs.join(" ") : "Neogit dashboard";
      ctx.ui.notify(
        `Neovim opened in vertical split (${target}). Annotate with :PiAnnotate, close to send.`,
        "info",
      );
    } catch (err: any) {
      ctx.ui.notify(`Failed to spawn Neovim: ${err.message}`, "error");
    }
  }

  pi.registerShortcut("alt+v", {
    description: "Open Neovim in a vertical tmux split (Neogit dashboard)",
    handler: async (ctx) => {
      await spawnNvim([], ctx);
    },
  });

  pi.registerCommand("nvim", {
    description:
      "Open Neovim in a vertical tmux split. Defaults to Neogit dashboard to review changes.",
    handler: async (args, ctx) => {
      const fileArgs = args.trim().split(/\s+/).filter(Boolean);
      await spawnNvim(fileArgs, ctx);
    },
  });
}

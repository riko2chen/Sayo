# Sayo Terminal Integration

After installation, press **Ctrl-X Ctrl-R** in an interactive zsh, Bash 4+, or fish prompt. Sayo reads only the command currently visible in the shell's editable buffer. It sends that buffer to the local Sayo app and replaces the buffer with the returned text without executing it. macOS's bundled Bash 3.2 is unsupported; sourcing the script prints a message and leaves bindings unchanged.

The zsh widget also sends an active ZLE selection (`REGION_ACTIVE`/`MARK`) to Sayo. Bash and fish currently send the caret as an empty selection because their widget interfaces do not expose a stable editable selection range across supported versions.

If Sayo is unavailable, cancelled, returns an error, or times out, the widget leaves the original command untouched.

The CLI accepts Unicode scalar offsets with `--cursor` (zsh/fish), or a UTF-8 byte offset with `--cursor-byte` (Bash Readline). Selection offsets always count Unicode scalars. Invalid byte boundaries are rejected. A successful Bash replacement sets `READLINE_POINT` to the UTF-8 byte length of the resulting buffer.

The fish widget preserves embedded and trailing newlines using [`string collect --no-trim-newlines`](https://fishshell.com/docs/current/cmds/string-collect.html). It strips exactly one extra newline emitted by the [`commandline` builtin](https://github.com/fish-shell/fish-shell/blob/master/src/builtins/commandline.rs), using a named regex capture so the buffer never undergoes another command substitution. Output is assigned with `commandline --replace --` and remains editable.

## CLI external editors (agy / Codex CLI / Claude Code)

Use Settings → Terminal → CLI editor integration to install or reset each CLI separately. Installation backs up `.zshrc`, adds an independently marked function for the selected CLI, and generates Sayo-owned executable helpers under `~/.local/bin`. Installing the editor integration alone does not write third-party settings or keybinding files. Reset removes only the selected marked block; shared helpers remain for other integrations and existing sessions.

Open a **new zsh terminal tab** and restart the CLI after installation or reset. Existing shells retain their functions and running CLI processes retain their environment. The functions pass `VISUAL` and `EDITOR` to the CLI process and its descendants without changing the parent shell's editor variables. Existing aliases/functions take precedence. Absolute-path launches and `command codex` (or equivalent) bypass the function.

Sayo routes its global invoke shortcut according to the foreground process in the focused terminal tab. Codex, Claude and agy receive their configured native external-editor shortcut directly; an ordinary shell receives the installed shell-widget chord. This avoids sending shell editing keys into a full-screen CLI.

Install the corresponding editor integration in Settings → Terminal, then restart your terminal for it to take effect. Continue using your existing Sayo global shortcut, or use the CLI's native external-editor shortcut, normally Ctrl+G. A fixed editor in the CLI's own settings may override environment variables; agy should use its default `auto` editor. Other CLI actions that use the external editor also receive Sayo. Claude's helper name contains `code` to select the GUI-editor waiting branch in Claude Code 2.1.150; this compatibility behavior may change in future versions.

`sayo edit FILE` reads a UTF-8 draft (up to 64 KB), opens the existing Sayo rewrite flow, and atomically writes the complete result back only on success. Cancellation, timeout, and invalid input leave the draft untouched; a draft changed during rewriting is not overwritten. Empty files are left unchanged. The complete draft is treated as an explicit selection. Silent mode returns a successful rewrite immediately. The CLI reloads the result without submitting the prompt.

### Internal CLI shortcut handling

The Terminal page provides installation and reset controls. CLI shortcut settings are internal to the integration; existing configured bindings are retained.

Checked with agy 1.1.28, Codex CLI 0.152.1, and Claude Code 2.1.150. Supported input is `ctrl+letter`, `alt+letter`, or `f1`–`f12`; exit, flow-control and terminal aliases for Tab/Return are rejected. Terminal/macOS key interception still applies. Sayo keeps its user-facing global shortcuts separate from the keystrokes relayed inside installed Shell and CLI integrations. The check runs in both directions when a global shortcut or CLI key changes and before an integration is installed. Existing explicit assignments to another action in agy/Claude configuration are rejected; a native default editing action on the chosen key may be replaced.

- **agy:** edits `edit.open_editor` in `~/.gemini/antigravity-cli/keybindings.json`. Restart agy after applying. Clearing writes an empty action binding list.
- **Claude Code:** appends a `Chat` binding for `chat:externalEditor` in `~/.claude/keybindings.json`, retaining other external-editor keys. Clearing writes explicit null bindings for native defaults and existing external-editor keys, preserving unrelated actions. See [Claude's native keybinding documentation](https://code.claude.com/docs/en/keybindings).
- **Codex CLI:** the setting accepts `ctrl+g` or `f6`–`f12`. Native runtime validation rejects Ctrl+E because it shadows `editor.move_line_end`. Custom native assignments can still conflict with a function key. The installed zsh function reads a Sayo-owned shortcut file and passes `-c 'tui.keymap.global.open_external_editor="…"'`, using Codex's [native keymap configuration](https://developers.openai.com/codex/config-schema.json). This replaces that action's binding for the launched process without editing `config.toml`. Changing a Codex binding refreshes the installed function; open a new terminal tab and restart Codex. Custom aliases/functions, absolute paths, `command codex`, or a later explicit `-c` override can bypass it. Clearing stores a disabled override and passes an empty array to Codex; it does not fall back to Ctrl+G.

JSON edits preserve unrelated properties, back up existing files, retain symlinks/permissions, and refuse malformed or unreadable configuration. A journal under `~/Library/Application Support/Sayo/CLI` tracks changes for Restore. If the managed binding was subsequently changed externally, Sayo refuses to overwrite it. These controls target the standard agy/Claude config locations; installations using custom configuration directories require manual keybinding setup. JSON with comments must be converted to strict JSON before editing here.

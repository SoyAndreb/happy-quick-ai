# Happy Quick-AI

A chat droplet for the [Droppy](https://getdroppy.app) Dynamic Island and
shelf, built with [DroppyKit](https://getdroppy.app/docs/droppykit). It talks
to **ChatGPT**, **Google Gemini**, **Anthropic Claude**, **DeepSeek** or
**OpenRouter** through their REST APIs using your own API keys, right from the
shelf.

## Features

- Chat from the shelf widget with one of five providers; add your API key in
  Settings (a **Test** button there shows exactly what the server answers).
- The model list is fetched live from each provider — `openai/gpt-*` and `o*`
  families, `gemini-*` chat models, `claude-*`, `deepseek-*`, and the hosted
  models on OpenRouter — and refreshes itself when you switch provider or edit
  a key.
- Typing is done through a native `NSTextField` with a local key monitor, so
  the input works no matter what language Droppy runs in, and without the host
  swallowing keystrokes.
- System prompt, output language and chat history are configurable.

## Developing

The build needs the Xcode-beta toolchain (see `AGENTS.md`). Prefix every
`droppykit` command with:

```bash
export PATH="/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode-beta.app/Contents/Developer/usr/bin:$PWD/droppykit/Scripts:$PATH"
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
```

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce .build/HappyQuickAI.droplet
droppykit validate   # the checks a submission runs
droppykit submit     # open the submission form, filled in from this checkout
```

## With a coding agent

Open this folder in Claude Code, Codex or Cursor. `AGENTS.md` is the brief
they read first, and `.mcp.json` / `.cursor/mcp.json` connect the DroppyKit
MCP server, which gives them the build, the checks, pictures of every surface
and an install into Droppy Playground as tools. Codex registers the server
once per Mac: `codex mcp add droppykit -- path/to/droppykit/Scripts/droppykit mcp`.
Run `droppykit agent` again after moving this folder or the SDK checkout.

## Before submitting

- Replace `HappyQuickAI.icon` with real artwork, in Icon Composer.
- Replace `Assets/Creator.png` with your own square, unrounded mark.
- Keep `summary` ≤ 60 characters and update `description`, `keywords` in
  `droplet.json` when providers change.
- Push this repository, then `droppykit submit`: it opens
  [getdroppy.app/submit-droplet](https://getdroppy.app/submit-droplet) with the
  repository, the commit and the id filled in.
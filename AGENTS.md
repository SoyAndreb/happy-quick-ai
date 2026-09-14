# Happy Quick-AI, a Droplet for Droppy

> Written by `droppykit agent`-style briefs and hand-tuned for this package. Add
> your own notes below; drop this header only if you know what you are doing.

Happy Quick-AI is a **Droplet**: an extension that runs inside Droppy, the
Dynamic Island and shelf for Mac, written in SwiftUI against **DroppyKit**.
Droppy loads the built `.droplet` bundle into its own process and draws it on
the shelf. The droplet is a chat client: it talks to ChatGPT, Google Gemini,
Anthropic Claude, DeepSeek or OpenRouter through their REST APIs using the
user's own API keys.

- Droplet id: `happy-quick-ai`. It is also `HappyQuickAIDroplet.id` in Swift and
  `id` in `droplet.json`; the three must agree or the loader refuses the bundle.
- Swift product: `HappyQuickAI`, a dynamic library. The harness target is
  `HappyQuickAIHarness`.
- SDK checkout: `./droppykit` in this package (DroppyKit 1.8.0). Docs online:
  https://getdroppy.app/docs/droppykit. Do **not** edit anything under
  `./droppykit`; fixes there go upstream. The MCP wiring in `.mcp.json`,
  `.cursor/mcp.json` and `.cursor/rules/` points at `~/droppykit`, the Home
  default the SDK's scripts recommend; this checkout is used through
  `$PWD/droppykit/Scripts:$PATH` instead.
- Host: Droppy 15.3 or later, or the free Droppy Playground
  (https://getdroppy.app/download/playground), which loads unsigned bundles
  without asking.

## Before you build: the toolchain

A bare build with the system `CommandLineTools` toolchain fails inside DroppyKit
(`Sources/DroppyKit/DesignSystem/SettingsSlider.swift`: "cannot assign to
property: 'self' is immutable") because it lacks the SwiftUI Macros plugin. This
package must be built with the Xcode-beta toolchain. Prefix every `droppykik`
build/validate/run with:

```bash
export PATH="/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode-beta.app/Contents/Developer/usr/bin:$PWD/droppykit/Scripts:$PATH"
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
```

`xcode-select` itself stays on the CommandLineTools; only the environment
above matters. `droppykit version` shows which SDK checkout the scripts come
from and which tag this package pins; `droppykit update` moves both to the
newest release. A build that stops with "no compiled objects" or "DroppyKit.o
not found" is an SDK older than 1.2.1: update it.

## The loop

Every change goes through all of this, in order. A droplet can compile,
validate and then draw nothing, so a green build is not the end.

1. Edit `Sources/HappyQuickAI/`. The manifest is `droplet.json`.
2. `droppykit build` writes `.build/HappyQuickAI.droplet`, universal, linked
   against the framework Droppy ships. Never a bare `swift build` for the
   bundle: it folds a second copy of DroppyKit into the droplet, and that
   bundle loads in the harness and dies inside Droppy at dyld with "Symbol not
   found". The build also warns that `HappyQuickAI.icon` ships as a document
   only (the Studio file is a source asset, `actool` does not rasterise it);
   that warning is cosmetic and pre-existing.
3. `droppykit validate` runs the exact checks the Store's intake runs.
4. `droppykit run -- --shots ./shots --report ./shots/report.json` renders every
   surface to a PNG without opening a window and writes a JSON verdict. Look at
   the pictures. Read `report.json`: `problems` must be empty and every surface
   you declared must be `provided`.
5. Put the bundle into Droppy Playground and confirm it loaded. Copy
   `.build/HappyQuickAI.droplet` to
   `~/Library/Application Support/Droppy Playground/Droplets/happy-quick-ai/HappyQuickAI.droplet`
   (create the directory first; the Playground deletes the bundle whenever it
   quits), relaunch the Playground, and read its Store row: the subtitle is the
   loader's verdict.

With the DroppyKit MCP server connected, the same steps are the tools
`droppykit_build`, `droppykit_validate`, `droppykit_shots` and
`droppykit_install`, and `droppykit_shots` returns the images inline. This
package carries the server in `.mcp.json` (Claude Code) and `.cursor/mcp.json`
(Cursor). Codex: `codex mcp add droppykit -- ./droppykit/Scripts/droppykit mcp`.

`droppykit run` with no arguments opens the harness window for a person:
Droppy's own Settings panel with a page per surface. You cannot see that
window. The shots are your eyes; take them after every visual change.

## Rules

- **Surfaces and conformances agree.** `surfaces` in `droplet.json` lists what
  the droplet provides; the droplet conforms to the matching protocol for each
  of them and to nothing it does not list. This droplet provides
  `shelf-widget` and `settings-pane`.
- **No card, no border around the widget.** Droppy paints nothing behind a
  widget. Put no background, fill, outline or rounded box on the widget's root
  view. `notchSurfaceCardFill` is for a tile or chip inside the widget (a chat
  bubble, the provider badge), never a frame.
- **Lay the widget out like Droppy's.** The root view fills the rectangle
  (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`)
  with ONE padding, `.padding(context.contentInsets)`, and nothing on top of
  it. That is the host's own inset for the slot and it is ZERO under a notch.
- **The host animates your content; you animate only what you swap.** Never put
  an entrance transition on the view a factory returns (it plays twice).
- **Buttons are Liquid Glass, Droppy's own.** `DroppyCircleButtonStyle` for icon
  actions, `DroppyQuietButtonStyle`/`DroppyAccentButtonStyle` (`.small`) for
  labelled ones. Never a flat wash, a bordered chip or a white button.
- **Everything `activate(host:)` starts, `deactivate()` stops.** Timers,
  observers, tasks, connections. The pair `modelRefreshTask`/`modelFetchTask`
  and the cancellables are cleared in `deactivate()`.
- **Host calls are gated by `capabilities`.** A service call without its
  capability in `droplet.json` is refused. This droplet only uses core services
  (`preferences`, `workspace.openSettings()`, `log`) and declares none, so the
  list in `droplet.json` stays `[]`.
- **The principal class does nothing.** `HappyQuickAIPrincipal` is `@objc`, is
  named in the bundle's `NSPrincipalClass`, and only creates the droplet. It
  runs before the host is ready.
- **No `main.swift`.** The harness entry is `@main` in
  `Sources/HappyQuickAIHarness/HappyQuickAIHarness.swift`; a file named
  `main.swift` cannot coexist with `@main`.
- **Look like Droppy, not like a guest.** Surfaces are dark. Foreground colours
  come from `AdaptiveColors`, spacing from `DroppySpacing`, radii from
  `DroppyRadius` with `style: .continuous`. No borders, gradients or ALL-CAPS;
  sentence case everywhere. Settings panes are built from `DropletSettingsCard`,
  `DropletControlRow`, `DropletStackedRow` and the SecureField rows for keys.
- **`droplet.json` is the truth for the build.** `Info.plist` is generated from
  it. `version` is numeric `major.minor.patch`; `summary` is at most 60
  characters; `minAppVersion` stays `15.3.0`; `kit.minAPI` is the oldest
  DroppyKit API the droplet actually calls (1.6.0).

## Where the truth is

Read these before guessing at an API. They are on disk, in the SDK checkout
under `./droppykit/`.

- Guides, as Markdown: `droppykit/Sources/DroppyKit/Documentation.docc/`
  `CreateYourFirstDroplet.md`, `DropletSetup.md`, `DesignGuidelines.md`,
  `ShelfWidgets.md`, `SettingsPanes.md`, `Harness.md`, `Playground.md`,
  `Submitting.md`, and `BuildWithCodingAgents.md` for this workflow in full.
- The surface protocols, one file each: `droppykit/Sources/DroppyKit/Capabilities/`
- The host services a droplet calls:
  `droppykit/Sources/DroppyKit/Services/DropletServices.swift` and
  `droppykit/Sources/DroppyKit/Core/DropletHost.swift`
- The manifest type, with every field documented:
  `droppykit/Sources/DroppyKit/Bundle/DropletManifest.swift`
- Design tokens and the settings components: `droppykit/Sources/DroppyKit/DesignSystem/`

## This droplet's design, and the traps

- **The chat input keeps a local event monitor on purpose.** The text field is
  `ChatInputField` (an `NSTextField` via `NSViewRepresentable`). While it is
  being edited, a local `keyDown` monitor feeds every keystroke straight into
  the field editor and *consumes* it (`return nil`, never `?? event` — that
  fallback redelivers the keystroke and every character types twice). The guard
  is `field.currentEditor()` alone, deliberately **not** `NSApp.isActive`: a
  shelf panel can be editing while the app is not the active app. Keystrokes go
  in through `editor.insertText(...)` so the text lands even when the host (in
  any language) swallows key events at its own dispatch. Do not replace this
  with a SwiftUI `TextField`.
- **The model list is fetched per provider with a generation token.** When the
  user switches provider or edits an API key, `updateAvailableModelsList()` is
  called (debounced 600 ms for key typing). Each call bumps
  `modelFetchGeneration`; only the newest fetch may write `availableModels`, so
  a slow response can never show one provider's list under another's picker. On
  failure the previous list is kept only when it belongs to the same provider,
  otherwise the provider's fallbacks are shown, and `modelsFetchError` explains
  why in the settings pane.
- **API keys are plain preferences, not Keychain.** DroppyKit preferences store
  Codable values per droplet and are the only persistence. If a provider
  rejects a stored key ("invalid credentials", OpenRouter's "User not found"
  for expired keys), the key itself is wrong or expired — use the **Test**
  button in Settings (Connection row) to see the masked key and the server's
  exact reply before changing code.
- **Provider surface area.** Adding a provider means touching the `AIProvider`
  enum (default/fallback models), its API-key preference and setter, the
  `activeApiKey` switch, `listModels(provider:apiKey:)`, the matching
  `call<Provider>API`, a Settings row, and `droplet.json` (summary ≤ 60 chars +
  keywords).
- **Surfaces the droplet provides:** `shelf-widget`, `settings-pane`.

## Surfaces

| `surfaces` value in droplet.json | Conform to | Shot |
| --- | --- | --- |
| `shelf-widget` | `ShelfWidgetProviding` | `shelf-widget.png` |
| `settings-pane` | `SettingsPaneProviding` | `settings-pane.png` |

`activity.png` shows every host call in order, refused ones marked.

## Done means

- `droppykit build` and `droppykit validate` both pass (with the Xcode-beta
  environment above).
- The report's `problems` is empty and `activation.error` is null.
- You have looked at the shot of every surface you touched.
- The bundle loaded in Droppy Playground: `droppykit_install` says loaded, or
  the Store row shows it switched on.
- `droplet.json` still describes what the code does: surfaces, capabilities,
  summary.

## Package layout

```
Package.swift                     product HappyQuickAI (dynamic) and HappyQuickAIHarness
droplet.json                      the manifest; Info.plist is generated from it
Sources/HappyQuickAI/            the droplet
Sources/HappyQuickAIHarness/     the @main harness entry; never main.swift
HappyQuickAI.icon/                Icon Composer document, required
Assets/Creator.png                square creator avatar, at least 256px, required
droppykit/                        the SDK checkout (read-only, do not edit)
.build/HappyQuickAI.droplet      what droppykit build writes
shots/                            renders from droppykit run; regenerable, gitignored
AGENTS.md, CLAUDE.md, .cursor/    this brief and the agent wiring
.mcp.json, .cursor/mcp.json       the DroppyKit MCP server; points at ~/droppykit
```

`droppykit/`, `.build/`, `shots/` and `.DS_Store` are gitignored.

## Submitting

Your own build runs in Droppy only after you approve it under Settings, Store,
Local droplets, and Droppy asks again each time it opens; everyone else gets
the droplet from the Store, signed by Droppy after review. The repo still has
no `.git/`; before shipping, `git init`, commit (dodging the gitignored paths),
push, and run `droppykit submit`. It opens getdroppy.app/submit-droplet with
the repository, commit and id filled in.
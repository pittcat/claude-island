# Repository Guidelines

## Project Structure & Module Organization

- `ClaudeIsland/` — App source (Swift/SwiftUI).
  - `App/` — app entry, lifecycle, window/screen management.
  - `UI/` — SwiftUI views, windows, reusable components.
  - `Core/` — core domain/state (settings, notch behavior, geometry).
  - `Services/` — integrations (hooks, sessions, chat, updates, tmux, etc.).
  - `Models/`, `Events/`, `Utilities/` — shared types and helpers.
  - `Resources/`, `Assets.xcassets/` — bundled resources and images.
- `ClaudeIsland.xcodeproj/` — Xcode project and scheme (`ClaudeIsland`).
- `scripts/` — release automation (archive/export, notarization, DMG, Sparkle keys).

## Build, Test, and Development Commands

- Open in Xcode: `open ClaudeIsland.xcodeproj`
- Debug build (CLI): `xcodebuild -scheme ClaudeIsland -configuration Debug build`
- Release build (CLI): `xcodebuild -scheme ClaudeIsland -configuration Release build`
- Release archive + export: `./scripts/build.sh` (outputs to `build/export/`)
- Release packaging/notarization: `./scripts/create-release.sh` (requires Apple notarization creds)
- Sparkle keys (one-time): `./scripts/generate-keys.sh` (never commit `.sparkle-keys/`)

## Coding Style & Naming Conventions

- Use Swift API Design Guidelines, 4-space indentation, and no trailing whitespace.
- Prefer small, focused types; keep UI state in view models/services rather than views.
- Naming:
  - Types/protocols: `UpperCamelCase`, methods/vars: `lowerCamelCase`.
  - SwiftUI views: `SomethingView.swift`; extensions: `Ext+Type.swift`.

## Testing Guidelines

- There is no dedicated test target in this repo today. If you add tests, prefer `XCTest` in a `ClaudeIslandTests` target and name tests `test_<behavior>`.
- For UI changes, include a short manual QA checklist in the PR (e.g., “multi-monitor”, “notch open/close”, “approvals flow”).

## Commit & Pull Request Guidelines

- Commit messages are short, imperative, and title-cased (e.g., “Fix window leak on screen changes”, “Bump version to 1.2”).
- PRs should include:
  - What/why summary and test steps.
  - Screenshots or a short screen recording for UI behavior changes.
  - Notes for release-impacting changes (versioning, update/feed behavior, signing).

## Security & Configuration Tips

- The app installs/uses Claude hooks under `~/.claude/hooks/`; avoid changing hook behavior without documenting migration steps.
- Release scripts can modify signing/notarization state and create artifacts in `build/` and `releases/`; don’t run them in CI unless explicitly configured.

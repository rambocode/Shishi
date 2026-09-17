# Repository Guidelines

## Project Structure & Module Organization

Shishi is a macOS 13+ AppKit task manager built with SwiftPM (Swift 5.9+).
`Sources/ShishiCore/` contains the domain model, persistence, import logic, and
other UI-independent rules. `Sources/Shishi/` contains the AppKit application;
organize view code by feature, such as `list/`, `editor/`, `settings/`, and
`sidebar/`. `Sources/CSQLite/` is the system SQLite module shim. Place XCTest
coverage in `Tests/ShishiCoreTests/`; test files use lowercase, hyphenated
feature names (for example, `project-operations-tests.swift`). Runtime assets
are in `resources/`, while product and acceptance documentation belongs in
`docs/`.

## Build, Test, and Development Commands

- `swift test` builds all targets and runs the XCTest suite.
- `swift build` compiles the debug executable for local development.
- `bash scripts/package.sh debug` packages `build/拾事.app` with a local ad-hoc
  signature; pass `release` for an optimized build.
- `open build/拾事.app --args --demo` starts an isolated demo-data instance.

The app normally writes to `~/Library/Application Support/Shishi/library.json`.
Use `--data-path /absolute/path/library.json` for experiments, and never run
two writers against the same library.

## Coding Style & Naming Conventions

Follow the existing Swift style: four-space indentation, `camelCase` for
members, `PascalCase` for types, and one focused responsibility per file.
Keep domain rules in `ShishiCore`; AppKit controllers and views should only
coordinate UI state and call core APIs. Prefer explicit failure handling over
silently ignoring errors. There is no repository formatter or linter configured,
so match nearby code and run `swift test` before handing off changes.

## Testing Guidelines

Add or update XCTest cases for changes to core behavior, persistence, imports,
or UI-controller logic. Name tests `test<Behavior>()` and cover success,
boundary, and failure paths where relevant. Tests must be deterministic: use
temporary directories and fixed `Calendar`/dates instead of the user library or
current clock. `SHISHI_THINGS_TEST_SOURCE` is opt-in for checks requiring a
local Things export; do not make ordinary tests depend on external app data.

## Commit & Pull Request Guidelines

Use concise Conventional Commit-style subjects, optionally scoped, such as
`feat(list): add inline task menu` or `fix: preserve backup on failed write`.
Keep each commit focused. Pull requests should explain the user-visible change,
link the relevant issue or acceptance document, list verification commands, and
include screenshots for AppKit visual or interaction changes. Call out data
format, import, or permission implications explicitly.

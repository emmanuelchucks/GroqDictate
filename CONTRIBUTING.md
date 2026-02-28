# Contributing

Thanks for helping improve GroqDictate.

## Before you start

- Read `README.md` for setup and workflow.
- Search existing issues and PRs first.
- Keep changes focused and small.

## Development setup

Requirements:

- macOS 14+
- Xcode 16+ (with Command Line Tools)

Common commands:

```bash
make doctor
make dev
```

If you need a clean test run:

```bash
make dev RESET=1 FORCE=1
```

## Branches and commits

- Create a feature branch from `main`.
- Use clear commit messages (conventional commits preferred), for example:
  - `feat: add menu bar state indicator`
  - `fix: prevent duplicate hotkey registration`

## Pull requests

1. Keep PR scope narrow.
2. Describe the problem and the fix.
3. Include test steps and results.
4. Add screenshots/GIFs for UI changes.
5. Ensure local checks pass:

```bash
make doctor
xcodebuild -project GroqDictate.xcodeproj -scheme GroqDictate -configuration Debug -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

## Coding guidelines

- Prefer simple, readable code.
- Add comments only when they explain *why*.
- Avoid unrelated refactors in the same PR.

## Reporting bugs

Please use the Bug Report issue template and include:

- macOS version
- app version / commit SHA
- steps to reproduce
- expected vs actual behavior
- relevant logs (`~/Library/Logs/GroqDictate/app.log` when enabled)

## Security issues

Do **not** report security issues in public issues.
See `SECURITY.md` for private reporting guidance.

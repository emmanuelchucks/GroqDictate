# Contributing

Thanks for helping with GroqDictate.

## Keep it simple

- Keep changes small and focused.
- Prefer fixing one clear problem per PR.
- Avoid broad refactors unless they are necessary.

## Local setup

Requirements:

- macOS 14+
- Xcode 16+ with Command Line Tools

Useful commands:

```bash
make doctor
make test
make dev
```

Prefer Makefile targets over raw `xcodebuild` commands for normal local work.
- `make test` runs signed local Debug tests.
- `make validate` runs the unsigned automation validation path.
- `make run` is a short alias for `make dev`.

Run a single signed local test:

```bash
make test TEST_ONLY=GroqDictateTests/HotkeyMonitorTests
```

If you want a clean local run:

```bash
make dev RESET=1 FORCE=1
```

## Pull requests

- Explain what changed and why.
- Include quick manual test steps.
- Add screenshots only for visible UI changes.
- Make sure the app builds before opening the PR.

Build check:

```bash
make test
```

## Tests

- Add tests when they validate behavior or prevent regressions.
- Skip tests that only restate implementation details or wording.
- If no meaningful test exists for a change, call that out in the PR.

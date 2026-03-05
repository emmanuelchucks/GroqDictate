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
make dev
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
xcodebuild -project GroqDictate.xcodeproj -scheme GroqDictate -configuration Debug -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

## Tests

- Add tests when they validate behavior or prevent regressions.
- Skip tests that only restate implementation details or wording.
- If no meaningful test exists for a change, call that out in the PR.

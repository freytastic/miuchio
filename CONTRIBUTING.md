# Contributing to Miuchio

Thank you for wanting to help. Miuchio is built by one person, so this page explains what is easiest for me to review and what needs a conversation first.

I am open to changes to the design, theme, UI and UX, and to ideas for new features. New features can take a while, because I spend most of my time on the protocol.

Start with the [website](https://www.miuchio.com) for the design and reasoning behind Miuchio, and ask if anything is unclear.

## Before you start

- **Bugs and small fixes:** open a pull request directly. A short description of the problem and how you checked the fix is enough.
- **Anything bigger:** open an issue first so we can agree on the approach before you spend time on code. This includes new features, new dependencies and changes to how an existing screen behaves.
- **Protocol and cryptography changes:** always open an issue first. Anything that changes key handling, signatures, wire formats, what the server stores or what it checks needs the design agreed before any code. The [protocol pages](https://www.miuchio.com/protocol/overview) describe the current design.
- **Serious security or protocol bugs:** reach out to me first. [SECURITY.md](SECURITY.md) lists how.
- **Questions:** ask me directly, using any contact in [Get in touch](README.md#get-in-touch).

## Setting up and testing

[docs/development.md](docs/development.md) explains how to run the server and the app. Before opening a pull request, run the commands in its [Tests](docs/development.md#tests) section. If you change the server's repositories, epochs, invites or prekeys, also run the tests that need a real Postgres and Redis, described there too.

## Rules for the code

- **Known answer test vectors are frozen.** `test_vectors/crypto_kat.json` and `server/test_vectors/` pin the exact bytes that the Dart app and the Go server must both produce. Never regenerate or edit a vector to make a test pass. A vector that disagrees with your change means the change broke compatibility.
- **Fail closed.** When a check about keys, signatures, epochs or photo metadata cannot be completed, refuse instead of continuing with less protection.
- **Add tests** for new behaviour, especially security checks, failure paths and races.
- **Comments** explain why, not what. Keep them short, and only where the code is not obvious.
- **Match the surrounding code** in naming and structure rather than introducing a new style.

## Commits and pull requests

Commit messages follow `type(scope): short description` with a one word scope, for example:

```
fix(onboarding): choose a lighter animation on slower phones
feat(viewer): add swipe navigation, zoom and shared photo sheets
```

Common types are `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build` and `chore`. Keep one change per pull request where you can.

## License

Miuchio is licensed under the [GNU AGPL v3](LICENSE). By contributing, you agree that your contribution is licensed under the same terms.

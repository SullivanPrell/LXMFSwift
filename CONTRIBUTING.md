# Contributing to LXMFSwift

LXMFSwift aims for **wire compatibility with Python LXMF** — a message must
round-trip with the reference implementation (<https://github.com/markqvist/LXMF>).

## Ground rules

- **Test-driven**: failing test first, implement to green, commit. Zero
  regressions — `swift test` must stay at 398/0.
- **Wire format is checked against Python** captured bytes where possible.

## Setup

```sh
git clone https://github.com/SullivanPrell/LXMFSwift.git
cd LXMFSwift
swift test
```

By default the package resolves ReticulumSwift from its published GitHub release.
To develop both at once, check out ReticulumSwift as a **sibling directory** and
set the env flag so the local copy is used:

```
parent/
├── ReticulumSwift/
└── LXMFSwift/
```

```sh
RETICULUM_LOCAL_DEPS=1 swift test
```

## Conventions

- `LXMessage` is a `final class`; all stored properties live in the class body
  (not in `extension` blocks).
- Byte fields use `Data`; string convenience via `contentAsString` / `titleAsString`.
- `LXMRouter` guards state with an `NSLock`; do not hold the lock when invoking
  callbacks.
- File / type naming mirrors the Python snake_case → Swift camelCase convention.

## Submitting changes

Branch from `main`, keep commits focused, ensure `swift test` is green, and note
any interop implications in the PR. Contributions are licensed under the
[Reticulum License](LICENSE).

# Ankra: instructions for contributors and agents

Ankra is the window, input, and platform layer of the AMAGE UI ecosystem,
implemented in **Bend 2**. Read the README for current capabilities and limits;
a roadmap item is not implemented merely because it appears in the project scope.

## Implementation

- Implement library logic in Bend 2, rather than wrapping an equivalent toolkit
  written in another language.
- The official Bend compiler/runtime, OS APIs, and drivers remain external
  dependencies. Keep any future native bridge minimal, explicit, and separate.
- Before writing Bend, run `bend version` and read `bend guide` from the installed
  toolchain. Verify available syntax/effects instead of assuming old examples work.
- Keep source, comments, documentation, and commit messages in English.

## Linux first

The initial goal is excellent behavior on Ian's actual Linux development machine:
correctness, stability, measured performance, and a finished user experience.
Inspect the effective environment before choosing integrations.

Build compatibility layers as the project progresses, after visible, well-made
Linux results. Do not let speculative Windows or macOS abstractions delay local
quality. Introduce abstractions from concrete needs.

## Working practice

- Preserve existing work and keep the library's boundary clear.
- Favor simple, maintainable code. Pursue fast, polished behavior with evidence.
- Run relevant native checks after changes. Validate affected visual interactions
  on a real window when changing visible behavior, then close the window.
- Compilation is not visual proof. Runtime checks are not proofs of the entire
  system. State partial support and unverified behavior explicitly.
- Build sequentially. Do not impose virtual-address limits on the Bend runtime
  or suppress crash reporting. Investigate failures before retrying.
- Keep generated binaries, logs, crash dumps, credentials, and machine-specific
  evidence out of Git. Stage explicit paths and preserve concurrent changes.

See [CONTRIBUTING.md](CONTRIBUTING.md) for validation commands.

# Contributing to Ankra

Use Bend 2.0.35 for the current baseline. Read `bend guide` before editing Bend
and keep project text in English. Library implementation belongs in Bend; the
official runtime and operating system remain external dependencies.

## Validation

From the repository root:

```sh
export BEND_NO_TELEMETRY=1
mkdir -p build
bend tests.bend -o build/tests
./build/tests --threads 2 --gpu off
bend examples/window.bend -o build/window
```

When a change affects visible behavior, also run the example in an X11/XWayland
session. Check input, the affected rendering scenario, and normal window closure.
A successful build alone does not validate the user experience. The native core
tests run without a display.

Build one target at a time. The native Bend runtime reserves substantial virtual
address space; a virtual-memory limit is not a resident-memory limit. Preserve
crash evidence and investigate before repeating a failed compiler invocation.

## Changes

Keep the API small and ownership explicit. Add a focused regression check when
behavior changes, update affected contracts, and report what was actually
validated. Distinguish scene recomputation from runtime presentation when
measuring redraw behavior or idle performance.

Use English commit messages that explain the result. Do not commit `build/`,
generated C, logs, crash dumps, credentials, or machine-specific paths. Do not
publish BendHub packages or create releases as a side effect of validation.

Compatibility work follows concrete Linux progress. New backends and platform
features need explicit implementations and their own validation before being
advertised as supported.

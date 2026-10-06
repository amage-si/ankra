# Ankra

**Windows, input events, and application lifecycle in Bend 2.**

Ankra is the platform foundation of the AMAGE UI ecosystem. It owns the window
loop so applications can retain their state, react to ordered input, and replace
their image when needed. The library implementation is written in Bend 2;
native window creation and presentation currently use the official Bend runtime.

**Status:** early Linux implementation, tested with **Bend 2.0.35** on
X11/XWayland. The first priority is a polished, reliable experience on the
development Linux machine. Compatibility layers will follow proven progress.

![Minimal window example running on Linux.](docs/preview.png)

## What works today

- Window creation with dimensions validated before allocation.
- Ordered event batches, including detection of window close requests.
- An explicit `Keep`, `Redraw`, or `Stop` decision for each update.
- Retention of the previous image between application changes.
- Normal closure on a close event, `Stop`, or exhaustion of the frame budget.

The native suite has **6 checks** for bounds, event order, empty batches,
and rejection of invalid windows. The tests do not open a valid window.
The example has also been exercised with a primary-button click and normal
window closure on Linux/XWayland.

## Quick start

Requirements: the [Bend 2 toolchain](https://bend-lang.com), Clang 14 or newer,
and X11 development headers/libraries. Running the example also needs an X11
display, directly or through XWayland. Native Wayland support is not implemented.

```sh
git clone https://github.com/amage-si/ankra.git Ankra
cd Ankra
export BEND_NO_TELEMETRY=1
bend version
mkdir -p build
bend tests.bend -o build/tests
./build/tests --threads 2 --gpu off
```

Open the minimal interactive example:

```sh
bend examples/window.bend -o build/window
./build/window --threads 2 --gpu off
```

Click the primary mouse button to switch colors. Close the window normally to
exit. It also closes after 3,600 frame cycles, approximately one minute at the
runtime's nominal pacing.

## The application contract

An update receives a `Batch` and the application state, then returns one of:

| Decision | Behavior |
| --- | --- |
| `Keep{state}` | Retain the current image and continue with the new state. |
| `Redraw{state, image}` | Use the replacement image on the next frame. |
| `Stop{}` | Close the window and end the loop. |

`run` opens the window and drives this contract. A close event ends the loop
before calling the application's update. An explicit frame budget makes the
loop finite.

Images use the official `Base.Image` quadtree and packed RGB colors. For shapes,
clipping, and alpha composition, pair Ankra with
[Chromi](https://github.com/amage-si/chromi).

Read the [API reference](docs/api.md) or the complete
[window example](examples/window.bend).

## Current boundaries

`Keep` avoids recomputing the application's image. The runtime still presents
the retained image and polls events on each `Window.frame` cycle. There is no
independent wait-for-events API in this backend.

The current runtime bridge does not provide resize notifications, text input/IME,
focus or pointer-leave events, clipboard integration, monitor discovery, or
automatic scale changes. Windows are treated as fixed-size surfaces.
Presentation uses the runtime's CPU/X11 path; Ankra does not supply a GPU renderer.

## Repository map

| Path | Purpose |
| --- | --- |
| [main.bend](main.bend) | Window lifecycle, event batches, and application loop. |
| [tests.bend](tests.bend) | Native checks that can run without a display. |
| [examples/window.bend](examples/window.bend) | Minimal application using Ankra. |
| [probe.bend](probe.bend) | Direct Base window probe for backend diagnostics. |
| [docs/api.md](docs/api.md) | Types, ownership, and behavioral contracts. |

## Direction

The next platform work is resize and scale tracking, complete input delivery,
and separating event waits from presentation. Each capability needs a working
Linux example and measured behavior before broader platform support is added.
These are goals, not supported features.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development rules. The API is
experimental and may change. A distribution license has not yet been selected.

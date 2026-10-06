# The native bridge

`native/ankra.c` is Ankra's only hand-written native code. Bend splices it
into the generated C program after the runtime (see `bend guide effects`);
`native/ankra.js` is the JavaScript twin every Bend effect needs, and it
answers `Fail` with ENOTSUP (95), so the JS lane fails cleanly (programs
there can use the official backend, `main.bend`). The effects are declared
in [native.bend](../native.bend).

## Shape of the bridge

- **One call per effect.** Each effect performs one Xlib call, or a fixed
  translation of Xlib event structs into words. Event masks, size hints,
  focus filtering, key repeat, key codes, button numbering, position
  queries and timeouts are decided in Bend (`window.bend`, `keys.bend`).
- **Slots.** Displays and windows live in a 256-entry table and cross into
  Bend as `U32` slot ids (0 means none). A stale or wrong-kind id fails
  instead of crashing. Bend owns lifetimes: windows before their display.
- **Waiting.** `x11_wait` drains events already read; with none, it parks
  on the connection's socket with `io_wait_on` (and an optional deadline),
  so the runtime's event loop sleeps in the kernel. A wake that brought no
  event (a reply, a partial read) parks again until the deadline.
- **Linking.** Including `<X11/Xlib.h>` makes `bend` link libX11, the same
  rule the official Window effect relies on; XKB is part of libX11.
- **Failures** answer `Fail{(code, text)}`: 22 (EINVAL) for a bad slot or
  argument, 24 (EMFILE) when the slot table is full, 95 (ENOTSUP) when no
  display is reachable.

Size: 538 lines (381 non-blank, non-comment), 13 effects, each with its
`#ifdef` guard and registration.

## Effects

All answer `IO(Result<&1, &1, U32 & String, T>)`.

| Effect | Xlib call | Arguments → answer |
| --- | --- | --- |
| `x11_connect()` | `XOpenDisplay(NULL)` | → display slot |
| `x11_create(display, x, y, w, h, events, background)` | `XCreateWindow` on the root | Event mask chosen by Bend; background `0xFFFFFFFF` is None (`CWBackPixmap`), else a `0xRRGGBB` pixel (`CWBackPixel`). → window slot |
| `x11_protocols(window)` | `XInternAtom` + `XSetWMProtocols` | Registers `WM_DELETE_WINDOW`. → Unit |
| `x11_title(window, title)` | `XStoreName` + `XChangeProperty(_NET_WM_NAME, UTF8_STRING)` | → Unit |
| `x11_class(window, name, class)` | `XSetClassHint` | → Unit |
| `x11_size_hints(window, minW, minH, maxW, maxH)` | `XSetWMNormalHints` | A zero pair leaves that bound unset. → Unit |
| `x11_autorepeat(display, on)` | `XkbSetDetectableAutoRepeat` | → 1 when supported, 0 otherwise |
| `x11_map(window)` | `XMapWindow` + `XFlush` | → Unit |
| `x11_position(window)` | `XTranslateCoordinates` to the root | → `[x, y]` (two's complement words) |
| `x11_native(window, display)` | none (fields) | → `[1, Display* high, Display* low, window id, screen]` for `display` |
| `x11_wait(display, ms)` | `XPending`/`XNextEvent`; parks with `io_wait_on` | 0 polls, 4294967295 no deadline. → event words (below) |
| `x11_destroy(slot)` | `XDestroyWindow` + `XFlush`, or `XCloseDisplay` | → Unit |
| `x11_live()` | none | → live slots (0 after a full teardown) |

### Event words (`x11_wait`)

Eight words per event: kind, window slot, then six fields. Signed values
travel as 32-bit two's complement.

| Kind | Event | Fields |
| --- | --- | --- |
| 1 | `ClientMessage` with `WM_DELETE_WINDOW` | — |
| 2 | `ConfigureNotify` | width height x y synthetic |
| 3 | `Expose` | x y width height count |
| 4 | `KeyPress`/`KeyRelease` | keysym keycode down state chars time |
| 5 | `ButtonPress`/`ButtonRelease` | x y button down state time |
| 6 | `MotionNotify` | x y state time |
| 7 | `FocusIn`/`FocusOut` | in mode detail |
| 8 | `EnterNotify`/`LeaveNotify` | enter x y mode detail state |
| 9 | `MapNotify`/`UnmapNotify` | mapped |

`keysym` and `chars` (count << 8 | first byte) come from `XLookupString`
with only Shift and Lock applied, as Base's window does; `state` is the full
modifier mask. A `MappingNotify` refreshes Xlib's keymap cache
(`XRefreshKeyboardMapping`, which `XLookupString` needs) and produces no
word. Other events are dropped.

## Why two connections

`open` makes two connections to the X server: the window is created and its
events are read on the first; `native` hands the second to GPU layers. The
Vulkan driver reads the connection its surface was made on from its own
threads. When that was the event connection, those threads consumed the
socket's readiness, and Ankra's wait slept through input until some later
event woke it: synthetic clicks sent to the window took about 0.8 s to be
handled. With the presentation connection apart, the same clicks are
handled at once. Window ids are global to the server, so a surface made on
the second connection presents into the window owned by the first. Ankra
owns and closes both.

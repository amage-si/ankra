# The native bridge

`native/ankra.c` is Ankra's only hand-written native code. Bend splices it
into the generated C program after the runtime (see `bend guide effects`);
`native/ankra.js` is the JavaScript twin every Bend effect needs, and it
answers `Fail` with ENOTSUP (95), so the JS lane fails cleanly (programs
there can use the official backend, `main.bend`). The effects are declared
in [native.bend](../native.bend).

## Shape of the bridge

- **One call per effect.** Each effect performs one Xlib call (or the
  short fixed sequence one protocol step needs, such as an ICCCM reply), or
  a fixed translation of Xlib event structs into words. Event masks, size
  hints, focus filtering, key repeat, key codes, which characters are
  text, button numbering, position queries, timeouts, clipboard answers
  and when to read a paste are decided in Bend (`window.bend`,
  `keys.bend`, `clipboard.bend`).
- **Slots.** Displays and windows live in a 256-entry table and cross into
  Bend as `U32` slot ids (0 means none). A stale or wrong-kind id fails
  instead of crashing. Bend owns lifetimes: windows before their display.
- **Waiting.** `x11_wait` drains events already read; with none, it parks
  on the connection's socket with `io_wait_on` (and an optional deadline),
  so the runtime's event loop sleeps in the kernel. A wake that brought no
  event (a reply, a partial read) parks again until the deadline. After
  `x11_watch`, it parks on an epoll set holding the connection and one
  more descriptor instead, and a wake for that descriptor ends the wait
  with a kind-14 record.
- **Registration.** Each effect registers as `io_eff(CID(name), run)` (the
  Bend 2.0.36 form): the loop runs it at once, and an effect that waits
  parks itself with `io_wait_on`, as `x11_wait` does.
- **Linking.** Including `<X11/Xlib.h>` makes `bend` link libX11, the same
  rule the official Window effect relies on; XKB is part of libX11.
- **Failures** answer `Fail{(code, text)}`: 22 (EINVAL) for a bad slot or
  argument, 24 (EMFILE) when the slot table is full, 95 (ENOTSUP) when no
  display is reachable; `x11_clip_take` adds the codes in its row.

Size: 1006 lines, 19 effects, each
with its `#ifdef` guard and registration.

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
| `x11_wait(display, ms)` | `XPending`/`XNextEvent` (+ `XFilterEvent` with an input method); parks with `io_wait_on` | 0 polls, 4294967295 no deadline. → event words (below) |
| `x11_watch(display, fd)` | `epoll_create1` + `epoll_ctl` (once), `epoll_ctl` per call | Waits on `display` also end when `fd` is readable; 0xFFFFFFFF stops watching. The epoll set is closed with the display. → Unit |
| `x11_input(window)` | `setlocale(LC_CTYPE)` + `XSetLocaleModifiers("@im=none")` + `XOpenIM` (once per display), `XCreateIC` + `XSetICFocus` | → 1 with an input context, 0 without (text then crosses as keysyms). See [Text](#text). |
| `x11_clip_own(window, time)` | `XSetSelectionOwner(CLIPBOARD)` + `XGetSelectionOwner` | → 1 when the window owns the clipboard |
| `x11_clip_reply(window, requestor, property, target, format, time, text)` | `XChangeProperty` on the requestor + `XSendEvent(SelectionNotify)` + `XSync` | `target` is the requested atom (repeated in the notify). `format`: 0 refuse (property None), 1 TARGETS with STRING, 2 TARGETS without STRING, 3 `text` as UTF8_STRING, 4 `text` as STRING (Latin-1; a scalar past 255 is EINVAL). Text past the server's maximum request size is refused (no INCR). X errors during the call (a requestor that vanished) are ignored instead of ending the program. → Unit |
| `x11_clip_ask(window, time)` | `XConvertSelection(CLIPBOARD, UTF8_STRING)` into `ANKRA_PASTE` + `XFlush` | The owner's answer arrives as a notify record. → Unit |
| `x11_clip_take(window, limit)` | `XGetWindowProperty(ANKRA_PASTE, delete)` | UTF8_STRING as strict UTF-8, STRING as Latin-1. → String of at most `limit` scalars; fails 61 (ENODATA) with no property, 27 (EFBIG) for INCR or past the limit, 84 (EILSEQ) for invalid UTF-8, 95 for another type |
| `x11_destroy(slot)` | `XDestroyIC` + `XDestroyWindow` + `XFlush`, or `XCloseIM` + `XCloseDisplay` | → Unit |
| `x11_live()` | none | → live slots (0 after a full teardown) |

### Event words (`x11_wait`)

Eight words per record: kind, window slot, then six fields. An X event
gives one record, none, or (a key press with text) several. Signed values
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
| 10 | text of a `KeyPress` (after its kind-4 record) | n \| more << 8 \| keysym << 16, c1 c2 c3 c4, state |
| 11 | `SelectionRequest` | requestor property target_code time clipboard target |
| 12 | `SelectionClear` | clipboard time |
| 13 | `SelectionNotify` | ok clipboard |
| 14 | (none: the descriptor of `x11_watch` is readable; window slot 0, so `decode` skips it and `wait` ends) | — |

`keysym` and `chars` (count << 8 | first byte) come from `XLookupString`
with only Shift and Lock applied, as Base's window does; `state` is the full
modifier mask. A `MappingNotify` refreshes Xlib's keymap cache
(`XRefreshKeyboardMapping`, which `XLookupString` needs) and produces no
word. `target_code` is 1 TARGETS, 2 UTF8_STRING, 3 STRING, 4 TEXT, 0
anything else; `clipboard` is 1 when the selection is CLIPBOARD; `ok` is 1
when the notify names a property (the owner answered). Other events are
dropped.

## Text

`x11_input` gives the window an input context on Xlib's built-in input
method (`@im=none`): dead keys, compose sequences (the locale's Compose
table and `~/.XCompose`) and AltGr levels, with no IME server. The
explicit modifier overrides `XMODIFIERS` (fcitx here), so typing never
waits on another process. `x11_wait` then passes every event through
`XFilterEvent`: the method swallows a dead key's press, and when a
sequence completes it puts back a press with keycode 0 that carries the
result. Each press's text comes from `Xutf8LookupString` (retried with a
larger buffer on `XBufferOverflow`), is decoded as strict UTF-8 in C and
crosses as scalars, four per kind-10 record, `more` set on all records but
the last. Without an input context, the record carries the keysym of
`XLookupString` on the full state, with the keysym bit set.

The decisions are Bend's (`window.bend`): the records of one press become
one `TextTyped` right after its `KeyDown`; controls (C0, DEL, C1) are not
text; nothing is typed while Ctrl, Alt (Mod1) or Super (Mod4) is held,
while AltGr (Mod5) types; a press with keycode 0 gives text without a
`KeyDown`; keysyms map with `Keys.unicode`.

**Locale.** Xlib takes the locale's charset and compose table when the
input method opens, so `x11_input` sets `LC_CTYPE` from the environment
only around `XOpenIM` and then puts the previous value back (C, for a Bend
program): the runtime never runs under a changed locale, and lookups keep
working because Xlib holds the locale data in the input method.

## Clipboard

The CLIPBOARD selection follows ICCCM with whole-property transfers. To
copy, Bend takes ownership with the time of the last key or button event
(`Win.time`). A `SelectionRequest` becomes a kind-11 record and a
`Clipboard{Asked}` event; Bend's `answer` picks the format and
`x11_clip_reply` writes the property and sends the notify. A
`SelectionClear` becomes `Clipboard{Lost}`. To paste from another owner,
`x11_clip_ask` converts the selection into the window's `ANKRA_PASTE`
property; the notify (kind 13) tells `wait` to read it with
`x11_clip_take` after the batch, and the text arrives as
`Clipboard{Pasted}` (or `PasteFailed{code}`). INCR transfers are not
supported in either direction: a larger paste fails with 27, a larger copy
is refused.

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

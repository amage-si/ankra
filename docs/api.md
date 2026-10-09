# Ankra API

Ankra depends only on `Base` from the official Bend toolchain and on its own
modules. Import paths are relative to the calling file. An application next to
the `Ankra` directory uses:

```bend
import Base
import ./Ankra/window.bend as A      # native X11 window
import ./Ankra/app.bend as Loop      # its application loop
import ./Ankra/clipboard.bend as Clip # the CLIPBOARD selection
import ./Ankra/main.bend as Official # the official-runtime backend
```

## Native window (`window.bend`)

### Opening and closing

| Function | Contract |
| --- | --- |
| `options(title, width, height)` | `Options` for a resizable window with a 160x120 minimum, class `Ankra` and no background. |
| `Options{title, width, height, resizable, min_width, min_height, class, background}` | `resizable` False asks the window manager for a fixed size. `background` is `0xRRGGBBAA`: alpha 0 means none (GPU windows: the server never clears a presented frame), any other alpha has the server paint the opaque RGB. |
| `open(options)` | `IO(Result<&1, &1, U32 & String, Win>)`. Fails with 22 for dimensions outside 1..4096 and 95 when no X display is reachable (callers may fall back to the official backend); other failures end the program. Opens the event connection, creates and maps the window, registers `WM_DELETE_WINDOW`, asks for detectable autorepeat, and opens a second connection for GPU presentation. |
| `close(win)` | `IO(U32)`. Destroys the window, then the presentation and event connections; answers how many native objects the bridge still holds (0). Destroy every GPU surface made from the window first. |
| `set_title(win, title)` | `IO(Win)`. |
| `native(win)` | `IO(List<&2, U32>)`: `[1 (Xlib), Display* high word, Display* low word, window id, screen]` on the presentation connection, for a Vulkan Xlib surface. Valid until `close`. |

### State

`Win{display, presenter, window, width, height, x, y, focused, visible, held,
detectable, time, frame, refresh}` is `Data`: native slots and what Ankra
knows about the window. `wait` returns the next value; use the accessors
`width`, `height`, `position_x`, `position_y`, `focused`, `visible`,
`detectable` (whether the server suppresses autorepeat releases), `time`
(the X server time of the last key or button event, 0 before any; clipboard
requests carry it), `frame_time` and `refresh` (below). The window starts
unmapped, unfocused, at (0, 0), at the requested size; events bring the real
values.

| Accessor | Meaning |
| --- | --- |
| `frame_time(win)` | `U32` ms of the monotonic clock `IO.now` reads (truncated to 32 bits: it wraps after 49.7 days, so compare times by their difference): when the frame being prepared is meant to be shown. The loop sets it before every `update` and `draw` (see [Animation](#animation)); 0 before the loop runs. |
| `refresh(win)` | `U32` millihertz: the refresh rate of the monitor the window is on (119930 for 119.93 Hz), 0 when unknown (no RandR). |

### Monitors and refresh

`monitors(win)` (`IO(Win)`) asks RandR for the screen's active CRTCs
(`x11_monitors`) and records the refresh of the one the window is on. `open`
calls it, and `wait` calls it again after a batch with `Moved` or
`Shown{True}`, so the rate follows the window to another monitor. The policy
is pure and in Bend:

- `mode_mhz(dotClock, hTotal, vTotal, flags)`: dotClock / (hTotal x vTotal),
  doubled for an interlaced mode (flag 0x10), halved for a doublescan one
  (0x20), in mHz.
- `refresh_of(words, x, y, width, height, old)`: the rate of the CRTC the
  window rectangle overlaps most (the first one on a tie); `old` when it
  overlaps none or RandR answered nothing.

Under XWayland, RandR describes each Wayland output with a generated mode:
this machine's 120.002 Hz panel reads as 119.93 Hz, and outputs sit in X's
own coordinates (the same ones as `Moved`). Not handled yet: a mode change
on a monitor while the window stays put (no RandR event is selected), and
per-output scale.

### Events

`wait(win, ms)` answers `IO(Win & List<&2, Input>)`: 0 polls, `forever()`
(4294967295) waits without a deadline, anything else is a timeout in
milliseconds (the list may then be empty). The wait parks on the X connection
in Bend's event loop.

`watch(win, fd)` (`IO(Win)`) makes every later wait also end when the file
descriptor `fd` is readable or hung up: a second event source, such as an
accessibility bus socket, without a polling timer. Such a wait answers the
window's events, possibly none; the app then reads `fd` itself (reading it
until it would block keeps the next wait asleep). `watch(win, unwatched())`
stops; a descriptor closed later stops counting by itself. Auvia's
`descriptor(service)` gives the bus socket's descriptor.

| `Input` | Meaning |
| --- | --- |
| `Resized{width, height}` | The window's size changed (physical pixels). |
| `Moved{x, y}` | The window's top-left corner moved on the screen. From synthetic configure events (root coordinates) or, after a real one, from `XTranslateCoordinates`; appended at the end of its batch in that case. |
| `Focused{gained}` | The window gained or lost keyboard focus. Changes caused by keyboard grabs (mode Grab/Ungrab) or about inferior windows or the pointer (detail Inferior/Pointer) are ignored. Losing focus forgets held keys. |
| `Exposed{}` | Part of the window needs repainting; at most once per batch. |
| `Shown{visible}` | Mapped or unmapped (minimized, moved to a hidden workspace). |
| `CloseRequested{}` | The window manager asked to close the window. |
| `KeyDown{code, repeat, mods}` | `code` in Base's convention (below); `repeat` True for autorepeat. |
| `KeyUp{code, mods}` | |
| `PointerMoved{x, y}` | Window coordinates (F32 physical pixels, may be negative while a button is held). Consecutive motions in a batch keep the last. |
| `PointerDown{x, y, button, mods}`, `PointerUp{...}` | Buttons 0 primary, 1 secondary, 2 middle, 3 back, 4 forward. |
| `PointerEntered{x, y}`, `PointerLeft{}` | Crossing caused by grabs or inferior windows is ignored. |
| `Wheel{x, y, dx, dy}` | One notch per event, as Base: up `dy = 1`, down `-1`, left `dx = 1`, right `-1`. |
| `TextTyped{text}` | The text one key press produced, right after its `KeyDown`: a character, an AltGr level, or a completed dead-key/compose sequence (whose final press has no `KeyDown`). Never contains controls (C0, DEL, C1); never sent while Ctrl, Alt or Super is held (AltGr types). A held key gives one per repeat. |
| `Clipboard{event}` | `ClipEvent`: `Asked{Request{requestor, property, target, time, atom}}` (another client wants the clipboard this app owns: answer with `Clip.serve`), `Lost{}` (another client took the clipboard), `Pasted{text}` (the answer to `Clip.paste`), `PasteFailed{code}` (61 no owner or refused, 27 too large or INCR, 84 invalid UTF-8, 95 unsupported type). |

Helpers: `closing(events)`, `exposed(events)`, `resized(events, None{})` (the
last `Size{width, height}` of a batch), `signed(word)` (two's complement word
to F32).

### Keys (`keys.bend`)

`KeyDown`/`KeyUp` codes follow Base's `Key` convention, decided in Bend from
the keysym and the characters `XLookupString` produced with Shift and Lock:
a key's character in lower case (Escape 27, Tab 9, Return 13, Space 32),
Backspace 127, arrows from 63232, F1-F12 from 63236, Insert 63271, Delete
63272, Home 63273, End 63275, Page Up/Down 63276/63277, modifiers 65590-65598,
Shift+Tab (ISO_Left_Tab) 25, any other key 65536 + its X keycode.

`mods` bits: `shift()` 1, `control()` 2, `alt()` 4, `super()` 8,
`caps_lock()` 16.

`unicode(keysym)` is a keysym's character for text without an input method:
Latin-1 keysyms are themselves, `0x01000000 + c` is `c`, anything else 0.

### Text input

`open` gives the window an input context on Xlib's built-in input method:
dead keys, compose sequences (`~/.XCompose` included) and AltGr levels work
with any XKB layout; there is no IME server yet (no preedit, no candidate
window). When no input method can be opened, text arrives from keysyms
(no dead keys). See [the bridge](bridge.md#text).

## Clipboard (`clipboard.bend`)

The CLIPBOARD selection, text only. The app keeps a `Clip{owned, text}`.

| Function | Contract |
| --- | --- |
| `none()` | A `Clip` that owns nothing. |
| `copy(win, text)` | `IO(Clip)`: takes the clipboard with `time(win)` and offers `text`; `owned` says whether the server gave ownership. |
| `paste(win, clip)` | `IO(Maybe<&2, String>)`: `Some{text}` at once when `clip` is owned; otherwise `None{}` now, and the owner's answer arrives in a later batch as `Clipboard{Pasted{text}}` or `Clipboard{PasteFailed{code}}`. Texts over `paste_limit()` (4096 scalars) fail. |
| `serve(win, clip, events)` | `IO(Clip)`: answers every `Clipboard{Asked}` in the batch and clears `owned` on `Clipboard{Lost}`. Call it with every batch. |
| `answer(clip, request)` | Pure policy, an `Answer`: `Refuse{}` when not owned or for an unknown target; `Targets{latin1}` for TARGETS (STRING listed only when every scalar is Latin-1); `Utf8{text}` for UTF8_STRING; `Latin1{text}` for STRING when it fits, else `Refuse{}`; TEXT as `Latin1` when it fits, else `Utf8`. |

Transfers are whole properties: no INCR, so a copy larger than the server's
maximum request size is refused, and PRIMARY (middle-click paste) is not
supported.

## Application loop (`app.bend`)

```bend
Loop.run(~S, ~update, ~draw, win, state) -> IO(A.Win & S)
#   update: A.Win -> List<&2, A.Input> -> S -> IO(Loop.Step<S>)
#   draw:   A.Win -> S -> IO(Loop.Step<S>)
```

`Step<S>`: `Keep{state}`, `Redraw{state}`, `Sleep{state, ms}`, `Stop{state}`,
and `animate(S, state)` (which is `Sleep{state, frame()}`, `frame()` =
4294967294).

Each turn: if the content is stale, `draw` runs (its `Redraw` means another
frame is owed, e.g. a rebuilt swapchain); then `wait` runs with no wait at all
while a frame is owed, the `Sleep` deadline if one was asked, until the next
frame while animating, or without a deadline; then `update` gets the window
and the batch. `Redraw` from `update` marks the content stale. A batch
containing `CloseRequested` ends the loop after `update`; so does `Stop`. The
first turn draws. The loop is bounded by 4294967295 turns because Bend
requires termination.

### Animation

```bend
def update(win: A.Win, es: List<&2, A.Input>, s: S) -> IO(Loop.Step<S>):
  ...  # start a motion at A.frame_time(win); answer Loop.animate(S, s')

def draw(win: A.Win, s: S) -> IO(Loop.Step<S>):
  ...  # evaluate every motion at A.frame_time(win) and draw;
       # Loop.animate(S, s') while something still moves, Keep{s'} once all rest
```

| Answer | From `update` | From `draw` |
| --- | --- | --- |
| `animate(S, s)` | Starts animating: the next frame is drawn at once (at once also when idle), stamped with the current time. Already animating: nothing changes. | Draw the next frame one refresh period after this one. |
| `Keep{s}` | Leaves a running animation alone. | Ends the animation: the loop waits with no deadline (0 frames, 0 wakeups). |
| `Redraw{s}` | Content stale. While animating, it is drawn with the next frame, not at once (it would land in the same refresh). | Ends the animation; one more frame at once. |
| `Sleep{s, ms}` | A deadline, as before; while animating the loop wakes at whichever comes first. | Ends the animation; wakes within `ms`. |

Frames follow a grid of the monitor's refresh period (`refresh(win)`, 60 Hz
when unknown): the loop sleeps in the event wait until 1 ms before the next
grid time, draws as soon as it wakes within 3 ms of it, and stamps the frame
with the grid time itself. Animated frames are therefore exactly one period
apart in `frame_time` whatever the moment the loop woke; motion evaluated
there advances evenly. A loop a period or more late skips to the latest grid
time instead of drawing the missed ones. Outside animation, the frame time is
the moment the turn began. While animating, `update` also runs once per
frame with the events since the last (often none). Events still end the wait
at once, so input is read between frames.

The pure decisions are exported and tested without a display: `updated`
(after `update`), `drew` (after `draw`), `paints` (does this turn draw),
`wait_ms` (how long the next wait is), `frame_at` and `slot` (the frame
time), `period` (µs per frame for a refresh in mHz), `stamp`.

**Why a timed grid rather than drawing back to back.** Voltra presents with
FIFO, but under XWayland FIFO does not hold an app to the refresh rate.
Measured with `Voltra/examples/motion.bend` (one rounded rect sliding 520 px
in 2 s, 720x400 window on the 120 Hz eDP-1 panel, visible workspace without
focus, timestamps from eco-bench's present-log layer, three runs each):

| | Grid (`animate`) | Back to back (`Redraw` every frame) |
| --- | --- | --- |
| Frames presented for the 2 s slide | 241, 241, 241 (120.5/s) | 436, 415, 358 (180-218/s) |
| Present interval p50 / p99, ms | 8.43-8.47 / 9.55-9.62 | 4.9-6.7 / 8.8-11.2 (p1 0.23-0.32) |
| Intervals of 1.5 periods or more | 0, 0, 0 | 1, 2, 1 |
| Frame time vs. present, deviation p99 | 0.54-0.63 ms | 5.0-6.6 ms (max 14 ms) |
| Time blocked in vkAcquireNextImageKHR, p50 | 0.03 ms | 4.6-5.9 ms |
| Main-thread CPU per frame | 0.40-0.46 ms | 0.33-0.52 ms |
| Main-thread switches per frame | 1.1-1.2 | 1.1-1.5 |
| After the slide, 5 s idle: frames / main-thread wakeups / main CPU | 0 / 0 / 0 ms | 0 / 0 / 0 ms |

The same grid on HDMI-A-1 (the window moved there, the slide restarted with a
synthetic Space): p50 8.44 ms, p99 9.56 ms, no interval over 9.7 ms.
`VK_KHR_present_wait` is offered by this NVIDIA driver (610.57) for X11
surfaces and was tried through a measuring layer: a present completes about
0.03 ms after `vkQueuePresentKHR` returns (XWayland copies and completes at
once), so it carries no vblank time. `VK_EXT_present_timing` on the X11
surface reports only the queue-operations-end stage and no target times. Neither
was adopted; the RandR period plus the timed grid is the pacing.

`run` hands back the window and the final state: tear down what the app owns
(GPU surfaces first), then `A.close(win)`.

## Official-runtime backend (`main.bend`)

`Batch{closed, count, events}` (Base `Event`s), `Step<S>` with `Keep{state}`,
`Redraw{state, image}`, `Stop{}`, and:

| Function | Contract |
| --- | --- |
| `valid_size(width, height)` | Accepts `U32` dimensions from 1 through 4096 on both axes. |
| `collect(events)` | Converts a runtime event list into an ordered `Batch`. |
| `open(title, width, height)` | `IO(Result<&1, &1, U32 & String, Window>)`; invalid dimensions fail with code 22 before the runtime is called. |
| `run(~S, ~update, title, width, height, fuel, state, image)` | Opens a window and runs a finite loop; `IO(Unit)`. |

The runtime's `Window.frame` presents the retained image with `XPutImage` and
polls events every frame (nominally 60 Hz); a batch with `Close` closes the
window before `update`. Base images are `0xRRGGBB` quadtrees. `run` does not
return the final state.

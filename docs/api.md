# Ankra API

Ankra depends only on `Base` from the official Bend toolchain and on its own
modules. Import paths are relative to the calling file. An application next to
the `Ankra` directory uses:

```bend
import Base
import ./Ankra/window.bend as A      # native X11 window
import ./Ankra/app.bend as Loop      # its application loop
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
detectable}` is `Data`: native slots and what Ankra knows about the window.
`wait` returns the next value; use the accessors `width`, `height`,
`position_x`, `position_y`, `focused`, `visible`, `detectable` (whether the
server suppresses autorepeat releases). The window starts unmapped, unfocused,
at (0, 0), at the requested size; events bring the real values.

### Events

`wait(win, ms)` answers `IO(Win & List<&2, Input>)`: 0 polls, `forever()`
(4294967295) waits without a deadline, anything else is a timeout in
milliseconds (the list may then be empty). The wait parks on the X connection
in Bend's event loop.

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

## Application loop (`app.bend`)

```bend
Loop.run(~S, ~update, ~draw, win, state) -> IO(A.Win & S)
#   update: A.Win -> List<&2, A.Input> -> S -> IO(Loop.Step<S>)
#   draw:   A.Win -> S -> IO(Loop.Step<S>)
```

`Step<S>`: `Keep{state}`, `Redraw{state}`, `Sleep{state, ms}`, `Stop{state}`.

Each turn: if the content is stale, `draw` runs (its `Redraw` means another
frame is owed, e.g. a rebuilt swapchain); then `wait` runs with no wait at all
while a frame is owed, the `Sleep` deadline if one was asked, or without a
deadline; then `update` gets the window and the batch. `Redraw` from `update`
marks the content stale. A batch containing `CloseRequested` ends the loop
after `update`; so does `Stop`. The first turn draws. The loop is bounded by
4294967295 turns because Bend requires termination.

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

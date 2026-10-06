# Ankra API

Ankra depends only on `Base` from the official Bend toolchain. Import paths are
relative to the calling file. An application next to the `Ankra` directory uses:

```bend
import Base
import ./Ankra/main.bend as A
```

## Data and ownership

`Batch{closed, count, events}` is reusable data. `events` is a `List<&2, Event>`
in the order supplied by the runtime. `count` includes every event, including
`Close`. `closed` is true if any event in the batch is `Close`.

`Step<S>` is affine and has three constructors:

```bend
Keep{state: S}
Redraw{state: S, image: Image}
Stop{}
```

The window and current image remain owned by the loop. The update receives
ownership of the application state and returns the next state when continuing.
A `Base.Image` leaf uses RGB in the low 24 bits (`0xRRGGBB`), not Chromi's
internal RGBA format.

## Entry points

| Function | Contract |
| --- | --- |
| `valid_size(width, height)` | Accepts `U32` dimensions from 1 through 4096 on both axes. |
| `collect(events)` | Converts a runtime event list into an ordered `Batch`. |
| `open(title, width, height)` | Returns `IO(Result<&1, &1, U32 & String, Window>)`. Invalid dimensions fail with code 22 before the runtime is called. |
| `run(~S, ~update, title, width, height, fuel, state, image)` | Opens a window and runs a finite application loop, returning `IO(Unit)`. |

`~S` is the state type. `~update` has type `Batch -> S -> IO(Step<S>)`.
`fuel` is a `Nat` frame budget. Width and height are physical pixels; Ankra does
not currently infer scale from the display.

The initial image is presented before the first update. A `Redraw` replacement
is presented on the following cycle. Empty event batches still reach `update`.
A batch containing `Close` closes the window without calling `update`, even
when the same batch contains other events.

`run` unwraps an opening failure with `IO.try`, which terminates the program on
failure. Use `open` directly to handle opening errors yourself; the caller then
owns the returned window and must close it.

Helpers such as `loop`, `shown`, `dispatch`, and `advance` implement the loop.
Applications should prefer `run`. The API is not stable yet.

## Runtime boundary

Ankra implements validation, batching, lifecycle decisions, and image retention
in Bend. The official runtime implements native `Window.open`, `Window.frame`,
and `Window.close` effects. Its OS calls and the OS/driver stack are external
dependencies.

The loop forwards runtime event data without adding timestamps, keyboard-repeat
normalization, text composition, focus tracking, or resize events. Keyboard and
mouse events alone do not imply those additional capabilities.

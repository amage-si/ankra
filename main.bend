import Base

# Window.frame is the only official native event pump. Keep retains the image,
# but the official effect still uploads it every turn (nominally 60 Hz).
type Step<-S: Type> is Type:
  Keep{state: S}
  Redraw{state: S, image: Image}
  Stop{}

type Batch is Data:
  Batch{closed: Bool, count: U32, events: List<&2, Event>}

def is_close(event: Event) -> Bool:
  match event:
    case Close{}:
      True{}
    case _:
      False{}

def collect.prepend(+event: Event, batch: Batch) -> Batch:
  Batch{closed, count, events} = batch
  Batch{is_close(event) || closed, (count + 1 : U32), event <> events}

def collect(events: List<Event>) -> Batch:
  match events:
    case Nil{}:
      Batch{False{}, 0, Nil{}}
    case event <> rest:
      collect.prepend(event, collect(rest))

def valid_size(+width: U32, +height: U32) -> Bool:
  (width > 0 : U32) && (height > 0 : U32) &&
    (width <= 4096 : U32) && (height <= 4096 : U32)

def open.checked(valid: Bool, title: String, width: U32, height: U32) ->
  IO(Result<&1, &1, U32 & String, Window>):
  match valid:
    case False{}:
      IO.pure(Result<&1, &1, U32 & String, Window>,
        Fail{(22, "Ankra: window dimensions must be between 1 and 4096")})
    case True{}:
      Window.open(title, width, height)

def open(title: String, +width: U32, +height: U32) ->
  IO(Result<&1, &1, U32 & String, Window>):
  open.checked(valid_size(width, height), title, width, height)

def advance(-S: Type, window: Window, old: Image,
  rest: Window -> Image -> S -> IO(Unit), next: Step<S>) -> IO(Unit):
  match next:
    case Keep{state}:
      rest(window, old, state)
    case Redraw{state, image}:
      rest(window, image, state)
    case Stop{}:
      Window.close(window)

def dispatch(-S: Type, batch: Batch, window: Window, image: Image, state: S,
  update: Batch -> S -> IO(Step<S>),
  rest: Window -> Image -> S -> IO(Unit)) -> IO(Unit):
  match batch:
    case Batch{True{}, count, events}:
      Window.close(window)
    case Batch{False{}, count, events}:
      IO.bind(Step<S>, Unit, update(Batch{False{}, count, events}, state),
        advance(S, window, image, rest))

def shown(-S: Type, frame: Window & Image & List<Event>, state: S,
  update: Batch -> S -> IO(Step<S>),
  rest: Window -> Image -> S -> IO(Unit)) -> IO(Unit):
  (window, image, events) = frame
  dispatch(S, collect(events), window, image, state, update, rest)

def loop(~S: Type, ~update: Batch -> S -> IO(Step<S>), fuel: Nat,
  window: Window, image: Image, state: S) -> IO(Unit):
  match fuel:
    case 0n:
      Window.close(window)
    case 1n+remaining:
      do IO<Unit>:
        frame : Window & Image & List<Event> <- Window.frame(window, image)
        shown(S, frame, state, update,
          w => img => s => loop(~S, ~update, remaining, w, img, s))

def run(~S: Type, ~update: Batch -> S -> IO(Step<S>), title: String,
  width: U32, height: U32, fuel: Nat, state: S, image: Image) -> IO(Unit):
  do IO<Unit>:
    window : Window <- IO.try(Window, open(title, width, height))
    loop(~S, ~update, fuel, window, image, state)

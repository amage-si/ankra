import Base
import ./native.bend as N
import ./keys.bend as Keys

# Ankra's native window on X11 (directly, or through XWayland).
#
# The window is a value: `Win` holds the native slots and what Ankra knows
# about the window (size, position, focus, visibility, held keys). `wait`
# hands back the next `Win` beside the decoded events. The bridge
# (native/ankra.c) only performs Xlib calls and copies event fields into
# words; selection of events, size hints, focus filtering, key repeat and
# key codes, position queries and timeouts are decided here.
#
# Coordinates are physical pixels with the origin at the window's top left
# (pointer) or the screen's top left (window position), carried as F32.
# Sizes are U32 physical pixels.

def forever() -> U32:
  4294967295

# KeyPress, KeyRelease, ButtonPress, ButtonRelease, EnterWindow,
# LeaveWindow, PointerMotion, Exposure, StructureNotify, FocusChange.
def event_mask() -> U32:
  2261119

# `background` is 0xRRGGBBAA: alpha 0 asks for no background at all (what
# GPU-presented windows want: the server never paints over a frame); any
# other alpha has the server paint the opaque RGB.
type Options is Data:
  Options{title: String, width: U32, height: U32, resizable: Bool,
    min_width: U32, min_height: U32, class: String, background: U32}

# A resizable window with a 160x120 minimum, the class "Ankra" and no
# background (for GPU presentation).
def options(title: String, +width: U32, +height: U32) -> Options:
  Options{title, width, height, True{}, 160, 120, "Ankra", 0}

def background_word(+rgba: U32) -> U32:
  Bool.pick(U32, U32.is_eq((rgba .&. 255 : U32), 0), 4294967295, (rgba >> 8n : U32))

type Win is Data:
  Win{display: U32, window: U32, width: U32, height: U32, x: F32, y: F32,
    focused: Bool, visible: Bool, held: List<&2, U32>, detectable: Bool}

type Input is Data:
  Resized{width: U32, height: U32}
  Moved{x: F32, y: F32}
  Focused{gained: Bool}
  Exposed{}
  Shown{visible: Bool}
  CloseRequested{}
  KeyDown{code: U32, repeat: Bool, mods: U32}
  KeyUp{code: U32, mods: U32}
  PointerMoved{x: F32, y: F32}
  PointerDown{x: F32, y: F32, button: U32, mods: U32}
  PointerUp{x: F32, y: F32, button: U32, mods: U32}
  PointerEntered{x: F32, y: F32}
  PointerLeft{}
  Wheel{x: F32, y: F32, dx: F32, dy: F32}

# Accessors
# ---------

def width(w: Win) -> U32:
  Win{d, n, width, h, x, y, f, v, k, r} = w
  width

def height(w: Win) -> U32:
  Win{d, n, wd, height, x, y, f, v, k, r} = w
  height

def focused(w: Win) -> Bool:
  Win{d, n, wd, h, x, y, focused, v, k, r} = w
  focused

def position_x(w: Win) -> F32:
  Win{d, n, wd, h, x, y, f, v, k, r} = w
  x

def position_y(w: Win) -> F32:
  Win{d, n, wd, h, x, y, f, v, k, r} = w
  y

def visible(w: Win) -> Bool:
  Win{d, n, wd, h, x, y, f, visible, k, r} = w
  visible

# Whether the server suppresses autorepeat's synthetic releases
# (XkbSetDetectableAutoRepeat). Repeats are flagged either way.
def detectable(w: Win) -> Bool:
  Win{d, n, wd, h, x, y, f, v, k, detectable} = w
  detectable

def display(w: Win) -> U32:
  Win{display, n, wd, h, x, y, f, v, k, r} = w
  display

def window(w: Win) -> U32:
  Win{d, window, wd, h, x, y, f, v, k, r} = w
  window

def valid_size(+width: U32, +height: U32) -> Bool:
  (width > 0 : U32) && (height > 0 : U32) &&
    (width <= 4096 : U32) && (height <= 4096 : U32)

# Signed 32-bit values arrive in U32 bits.
def signed(+v: U32) -> F32:
  Bool.pick(F32, U32.is_ge(v, 2147483648), F32.neg(U32.to_f32((0 - v : U32))), U32.to_f32(v))

# Batch helpers
# -------------

def closing(es: List<&2, Input>) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{CloseRequested{}, rest}:
      True{}
    case Con{e, rest}:
      closing(rest)

def exposed(es: List<&2, Input>) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{Exposed{}, rest}:
      True{}
    case Con{e, rest}:
      exposed(rest)

type Size is Data:
  Size{width: U32, height: U32}

# The last size reported in a batch, if any.
def resized(es: List<&2, Input>, last: Maybe<&2, Size>) -> Maybe<&2, Size>:
  match es:
    case Nil{}:
      last
    case Con{Resized{w, h}, rest}:
      resized(rest, Some{Size{w, h}})
    case Con{e, rest}:
      resized(rest, last)

# Decoding
# --------
#
# Bridge words, eight per event: kind, window slot, a b c d e f (see
# native/ankra.c). Decoding folds them in order into the next `Win` and a
# reversed event list, with these rules:
# - configure: Resized when the size changed; Moved when a synthetic event
#   (sent by the window manager in root coordinates) changed the position.
#   A real one carries parent-relative coordinates, so `wait` asks the
#   server for the position afterwards (XTranslateCoordinates).
# - focus: changes caused by keyboard grabs (mode Grab/Ungrab) or about
#   inferior windows or the pointer (detail Inferior/Pointer) are ignored,
#   as other toolkits do; only real changes produce Focused. Losing focus
#   forgets held keys.
# - keys: a press of a key already held is a repeat. Without detectable
#   autorepeat, X sends release+press pairs with one timestamp; the pair
#   collapses into a repeated press.
# - pointer: buttons 1/3/2 become 0/1/2 (primary, secondary, middle) and
#   8/9 become 3/4; buttons 4-7 are wheel notches, as in Base. Consecutive
#   motions keep only the last position. Crossing caused by grabs or
#   inferior windows is ignored.
# - expose: one Exposed per batch, once the last region (count 0) arrives.

type Decode is Data:
  Decode{win: Win, out: List<&2, Input>, ask: Bool, release: U32, at: U32}

def has(xs: List<&2, U32>, +k: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{h, t}:
      U32.is_eq(h, k) || has(t, k)

def without(xs: List<&2, U32>, +k: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{h, t}:
      +x = h
      +rest = without(t, k)
      Bool.pick(List<&2, U32>, U32.is_eq(x, k), rest, x <> rest)

def push.exposed(seen: Bool, out: List<&2, Input>) -> List<&2, Input>:
  match seen:
    case True{}:
      out
    case False{}:
      Exposed{} <> out

def push(ev: Input, +out: List<&2, Input>) -> List<&2, Input>:
  match ev out:
    case PointerMoved{x, y} Con{PointerMoved{a, b}, rest}:
      PointerMoved{x, y} <> rest
    case Exposed{} xs:
      push.exposed(exposed(xs), xs)
    case other xs:
      other <> xs

def emit(d: Decode, ev: Input) -> Decode:
  Decode{win, out, ask, r, t} = d
  Decode{win, push(ev, out), ask, 0, 0}

def keep(d: Decode) -> Decode:
  Decode{win, out, ask, r, t} = d
  Decode{win, out, ask, 0, 0}

def maybe_emit(go: Bool, d: Decode, ev: Input) -> Decode:
  match go:
    case True{}:
      emit(d, ev)
    case False{}:
      keep(d)

def configure.size(d: Decode, +w: U32, +h: U32) -> Decode:
  Decode{Win{dp, n, +ow, +oh, x, y, f, v, k, r}, out, ask, rl, at} = d
  maybe_emit(U32.is_ne(ow, w) || U32.is_ne(oh, h),
    Decode{Win{dp, n, w, h, x, y, f, v, k, r}, out, ask, rl, at}, Resized{w, h})

def configure.place(synthetic: Bool, d: Decode, +x: F32, +y: F32) -> Decode:
  match synthetic:
    case False{}:
      Decode{win, out, ask, r, t} = d
      Decode{win, out, True{}, 0, 0}
    case True{}:
      Decode{Win{dp, n, w, h, +ox, +oy, f, v, k, r}, out, ask, rl, at} = d
      maybe_emit(F32.is_ne(ox, x) || F32.is_ne(oy, y),
        Decode{Win{dp, n, w, h, x, y, f, v, k, r}, out, ask, rl, at}, Moved{x, y})

def configure(d: Decode, +w: U32, +h: U32, +x: U32, +y: U32, +synthetic: U32) -> Decode:
  configure.place(U32.is_ne(synthetic, 0), configure.size(d, w, h), signed(x), signed(y))

def focus.change(d: Decode, +gained: Bool) -> Decode:
  Decode{Win{dp, n, w, h, x, y, +was, v, k, r}, out, ask, rl, at} = d
  +held = Bool.pick(List<&2, U32>, gained, k, Nil{})
  maybe_emit(Bool.xor(was, gained),
    Decode{Win{dp, n, w, h, x, y, gained, v, held, r}, out, ask, rl, at}, Focused{gained})

def focus.pick(ignored: Bool, d: Decode, +gained: Bool) -> Decode:
  match ignored:
    case True{}:
      keep(d)
    case False{}:
      focus.change(d, gained)

def focus(d: Decode, +gained: U32, +mode: U32, +detail: U32) -> Decode:
  focus.pick(U32.is_eq(mode, 1) || U32.is_eq(mode, 2) || U32.is_eq(detail, 2) ||
    U32.is_eq(detail, 5), d, U32.is_ne(gained, 0))

def shown(d: Decode, +mapped: U32) -> Decode:
  Decode{Win{dp, n, w, h, x, y, f, +was, k, r}, out, ask, rl, at} = d
  +now = U32.is_ne(mapped, 0)
  maybe_emit(Bool.xor(was, now),
    Decode{Win{dp, n, w, h, x, y, f, now, k, r}, out, ask, rl, at}, Shown{now})

def drop_head(drop: Bool, xs: List<&2, Input>) -> List<&2, Input>:
  match drop xs:
    case True{} Con{h, t}:
      t
    case _ ys:
      ys

# A press right after a release of the same key with the same timestamp is
# X autorepeat without detection: drop that release, flag the press.
def key.press(d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  Decode{Win{dp, n, w, h, x, y, f, v, +held, r}, out, ask, +release, +at} = d
  +pair = U32.is_ne(release, 0) && U32.is_eq(release, keycode) && U32.is_eq(at, time)
  +repeat = pair || has(held, keycode)
  +now = Bool.pick(List<&2, U32>, has(held, keycode), held, keycode <> held)
  Decode{Win{dp, n, w, h, x, y, f, v, now, r},
    KeyDown{code, repeat, mods} <> drop_head(pair, out),
    ask, 0, 0}

def key.release(d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  Decode{Win{dp, n, w, h, x, y, f, v, held, r}, out, ask, rl, at} = d
  Decode{Win{dp, n, w, h, x, y, f, v, without(held, keycode), r},
    KeyUp{code, mods} <> out, ask, keycode, time}

def key.pick(down: Bool, d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  match down:
    case True{}:
      key.press(d, code, keycode, mods, time)
    case False{}:
      key.release(d, code, keycode, mods, time)

def key(d: Decode, +sym: U32, +keycode: U32, +down: U32, +state: U32, +chars: U32, +time: U32) -> Decode:
  key.pick(U32.is_ne(down, 0), d, Keys.code(sym, keycode, chars), keycode, Keys.mods(state), time)

def button_index(+b: U32) -> U32:
  Bool.pick(U32, U32.is_eq(b, 1), 0,
  Bool.pick(U32, U32.is_eq(b, 3), 1,
  Bool.pick(U32, U32.is_eq(b, 2), 2, (b - 5 : U32))))

def wheel(+b: U32, +x: F32, +y: F32) -> Input:
  +s = Bool.pick(F32, U32.is_eq((b % 2 : U32), 0), 1.0, F32.neg(1.0))
  Wheel{x, y, Bool.pick(F32, U32.is_gt(b, 5), s, 0.0), Bool.pick(F32, U32.is_gt(b, 5), 0.0, s)}

def pressed(down: Bool, +x: F32, +y: F32, +b: U32, +mods: U32) -> Input:
  match down:
    case True{}:
      PointerDown{x, y, button_index(b), mods}
    case False{}:
      PointerUp{x, y, button_index(b), mods}

def button.pick(notch: Bool, d: Decode, +x: F32, +y: F32, +b: U32, +down: Bool, +mods: U32) -> Decode:
  match notch:
    case True{}:
      maybe_emit(down, d, wheel(b, x, y))
    case False{}:
      emit(d, pressed(down, x, y, b, mods))

def button(d: Decode, +x: U32, +y: U32, +b: U32, +down: U32, +state: U32) -> Decode:
  button.pick(U32.is_ge(b, 4) && U32.is_le(b, 7), d, signed(x), signed(y), b,
    U32.is_ne(down, 0), Keys.mods(state))

def entered(enter: Bool, +x: F32, +y: F32) -> Input:
  match enter:
    case True{}:
      PointerEntered{x, y}
    case False{}:
      PointerLeft{}

def crossing(d: Decode, +enter: U32, +x: U32, +y: U32, +mode: U32, +detail: U32) -> Decode:
  maybe_emit(Bool.not(U32.is_eq(mode, 1) || U32.is_eq(mode, 2) || U32.is_eq(detail, 2)), d,
    entered(U32.is_ne(enter, 0), signed(x), signed(y)))

def one(k: U32, d: Decode, +a: U32, +b: U32, +c: U32, +e: U32, +f: U32, +g: U32) -> Decode:
  match k:
    case 1:
      emit(d, CloseRequested{})
    case 2:
      configure(d, a, b, c, e, f)
    case 3:
      maybe_emit(U32.is_eq(f, 0), d, Exposed{})
    case 4:
      key(d, a, b, c, e, f, g)
    case 5:
      button(d, a, b, c, e, f)
    case 6:
      emit(d, PointerMoved{signed(a), signed(b)})
    case 7:
      focus(d, a, b, c)
    case 8:
      crossing(d, a, b, c, e, f)
    case 9:
      shown(d, a)
    case _:
      keep(d)

def slot_of(d: Decode) -> U32:
  Decode{Win{dp, n, w, h, x, y, f, v, k, r}, out, ask, rl, at} = d
  n

def step.mine(mine: Bool, d: Decode, +k: U32, +a: U32, +b: U32, +c: U32, +e: U32, +f: U32, +g: U32) -> Decode:
  match mine:
    case True{}:
      one(k, d, a, b, c, e, f, g)
    case False{}:
      d

def step(+d: Decode, +k: U32, +slot: U32, +a: U32, +b: U32, +c: U32, +e: U32, +f: U32, +g: U32) -> Decode:
  step.mine(U32.is_eq(slot_of(d), slot), d, k, a, b, c, e, f, g)

def decode.go(ws: List<&2, U32>, d: Decode) -> Decode:
  match ws:
    case Con{k, Con{s, Con{a, Con{b, Con{c, Con{e, Con{f, Con{g, rest}}}}}}}}:
      decode.go(rest, step(d, k, s, a, b, c, e, f, g))
    case _:
      d

# Folds bridge words into the next window state, the events in order and
# whether the position must be asked of the server.
def decoded(d: Decode) -> Win & List<&2, Input> & Bool:
  Decode{w, out, ask, r, t} = d
  (w, List.reverse(&2, Input, out), ask)

def decode(ws: List<&2, U32>, win: Win) -> Win & List<&2, Input> & Bool:
  decoded(decode.go(ws, Decode{win, Nil{}, False{}, 0, 0}))

# Opening and closing
# -------------------

def need(-A: Data, r: Result<&1, &1, U32 & String, A>) -> IO(A):
  IO.try(A, IO.pure(Result<&1, &1, U32 & String, A>, r))

def open.window(o: Options, +dpy: U32) -> IO(Win):
  Options{title, +w, +h, +resizable, +mw, +mh, cls, bg} = o
  do IO<Win>:
    +win : U32 <- IO.try(U32, N.x11_create(dpy, 0, 0, w, h, event_mask(), background_word(bg)))
    IO.try(Unit, N.x11_protocols(win))
    IO.try(Unit, N.x11_title(win, title))
    IO.try(Unit, N.x11_class(win, "ankra", cls))
    IO.try(Unit, N.x11_size_hints(win, Bool.pick(U32, resizable, mw, w),
      Bool.pick(U32, resizable, mh, h), Bool.pick(U32, resizable, 0, w),
      Bool.pick(U32, resizable, 0, h)))
    +repeat : U32 <- IO.try(U32, N.x11_autorepeat(dpy, True{}))
    IO.try(Unit, N.x11_map(win))
    return Win{dpy, win, w, h, 0.0, 0.0, False{}, False{}, Nil{}, U32.is_ne(repeat, 0)}

def open.connected(r: Result<&1, &1, U32 & String, U32>, o: Options) ->
  IO(Result<&1, &1, U32 & String, Win>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, Win>, Fail{e})
    case Done{+dpy}:
      do IO<Result<&1, &1, U32 & String, Win>>:
        +win : Win <- open.window(o, dpy)
        return Done{win}

def open.checked(ok: Bool, o: Options) -> IO(Result<&1, &1, U32 & String, Win>):
  match ok:
    case False{}:
      IO.pure(Result<&1, &1, U32 & String, Win>,
        Fail{(22, "Ankra: window dimensions must be between 1 and 4096")})
    case True{}:
      do IO<Result<&1, &1, U32 & String, Win>>:
        c : Result<&1, &1, U32 & String, U32> <- N.x11_connect()
        open.connected(c, o)

# Opens and maps a window on the X display named by $DISPLAY. Fails with
# 22 for invalid dimensions and 95 when no display is reachable (so a
# caller can fall back to the official runtime window, main.bend); other
# failures end the program. The window starts unfocused and unmapped
# until its events say otherwise.
def open(o: Options) -> IO(Result<&1, &1, U32 & String, Win>):
  Options{t, +w, +h, r, mw, mh, c, bg} = o
  open.checked(valid_size(w, h), Options{t, w, h, r, mw, mh, c, bg})

# Destroys the window, then its display connection. Answers how many native
# objects the bridge still holds (0 when nothing leaked). Destroy every GPU
# surface made from the window first.
def close(w: Win) -> IO(U32):
  Win{+dpy, +win, wd, h, x, y, f, v, k, r} = w
  do IO<U32>:
    IO.try(Unit, N.x11_destroy(win))
    IO.try(Unit, N.x11_destroy(dpy))
    IO.try(U32, N.x11_live())

def set_title(+w: Win, title: String) -> IO(Win):
  do IO<Win>:
    IO.try(Unit, N.x11_title(window(w), title))
    return w

# The native handle for a GPU surface: [1 (Xlib), Display* high word,
# Display* low word, Window id, screen]. Valid until `close`.
def native(w: Win) -> IO(List<&2, U32>):
  IO.try(List<&2, U32>, N.x11_native(window(w)))

# Waiting
# -------

def placed.at(moved: Bool, w: Win, es: List<&2, Input>, +x: F32, +y: F32) -> Win & List<&2, Input>:
  match moved:
    case False{}:
      (w, es)
    case True{}:
      Win{dp, n, wd, h, ox, oy, f, v, k, r} = w
      (Win{dp, n, wd, h, x, y, f, v, k, r}, List.append(&2, Input, es, [Moved{x, y}]))

def placed(at: List<&2, U32>, +w: Win, es: List<&2, Input>) -> Win & List<&2, Input>:
  match at:
    case Con{a, Con{b, rest}}:
      +x = signed(a)
      +y = signed(b)
      placed.at(F32.is_ne(position_x(w), x) || F32.is_ne(position_y(w), y), w, es, x, y)
    case _:
      (w, es)

def asked(ask: Bool, +w: Win, es: List<&2, Input>) -> IO(Win & List<&2, Input>):
  match ask:
    case False{}:
      IO.pure(Win & List<&2, Input>, (w, es))
    case True{}:
      do IO<Win & List<&2, Input>>:
        +at : List<&2, U32> <- IO.try(List<&2, U32>, N.x11_position(window(w)))
        return placed(at, w, es)

def waited(d: Win & List<&2, Input> & Bool) -> IO(Win & List<&2, Input>):
  (w, rest) = d
  (es, ask) = rest
  asked(ask, w, es)

# Waits up to `ms` milliseconds for events: 0 polls, `forever()` waits
# without a deadline. The wait parks on the X connection: an idle window
# costs no CPU and no wakeups. Answers the next window state and the
# decoded events in order (possibly none, after a timeout).
def wait(+w: Win, ms: U32) -> IO(Win & List<&2, Input>):
  do IO<Win & List<&2, Input>>:
    +ws : List<&2, U32> <- IO.try(List<&2, U32>, N.x11_wait(display(w), ms))
    waited(decode(ws, w))

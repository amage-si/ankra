import Base
import ./native.bend as N
import ./keys.bend as Keys

# Ankra's native window on X11 (directly, or through XWayland).
#
# The window is a value: `Win` holds the native slots and what Ankra knows
# about the window (size, position, focus, visibility, held keys, the
# server time of the last key or button event). `wait`
# hands back the next `Win` beside the decoded events. The bridge
# (native/ankra.c) only performs Xlib calls and copies event fields into
# words; selection of events, size hints, focus filtering, key repeat and
# key codes, text filtering, clipboard reads, position queries and
# timeouts are decided here.
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

# `display` is the connection Ankra reads events from and owns the window
# on; `presenter` a second connection to the same server, handed to GPU
# layers for their surface (see `native`).
type Win is Data:
  Win{display: U32, presenter: U32, window: U32, width: U32, height: U32, x: F32, y: F32,
    focused: Bool, visible: Bool, held: List<&2, U32>, detectable: Bool, time: U32}

# A request for the clipboard's content (ICCCM SelectionRequest).
# `target` is what is asked: 1 TARGETS, 2 UTF8_STRING, 3 STRING, 4 TEXT,
# 0 anything else; `atom` is the target atom itself, which the answer
# repeats. `property` is where the requestor wants it (an obsolete
# requestor that names none gets the target atom, as ICCCM says). Answer
# with clipboard.bend's `serve`.
type Request is Data:
  Request{requestor: U32, property: U32, target: U32, time: U32, atom: U32}

type ClipEvent is Data:
  Asked{request: Request}
  Lost{}
  Pasted{text: String}
  PasteFailed{code: U32}

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
  TextTyped{text: String}
  Clipboard{event: ClipEvent}

# Accessors
# ---------

def width(w: Win) -> U32:
  Win{d, pr, n, width, h, x, y, f, v, k, r, tm} = w
  width

def height(w: Win) -> U32:
  Win{d, pr, n, wd, height, x, y, f, v, k, r, tm} = w
  height

def focused(w: Win) -> Bool:
  Win{d, pr, n, wd, h, x, y, focused, v, k, r, tm} = w
  focused

def position_x(w: Win) -> F32:
  Win{d, pr, n, wd, h, x, y, f, v, k, r, tm} = w
  x

def position_y(w: Win) -> F32:
  Win{d, pr, n, wd, h, x, y, f, v, k, r, tm} = w
  y

def visible(w: Win) -> Bool:
  Win{d, pr, n, wd, h, x, y, f, visible, k, r, tm} = w
  visible

# Whether the server suppresses autorepeat's synthetic releases
# (XkbSetDetectableAutoRepeat). Repeats are flagged either way.
def detectable(w: Win) -> Bool:
  Win{d, pr, n, wd, h, x, y, f, v, k, detectable, tm} = w
  detectable

# The X server time of the last key or button event (0 before any): the
# timestamp clipboard requests carry.
def time(w: Win) -> U32:
  Win{d, pr, n, wd, h, x, y, f, v, k, r, tm} = w
  tm

def display(w: Win) -> U32:
  Win{display, pr, n, wd, h, x, y, f, v, k, r, tm} = w
  display

def window(w: Win) -> U32:
  Win{d, pr, window, wd, h, x, y, f, v, k, r, tm} = w
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
# - text: the scalars of one key press, in one or more records, become one
#   TextTyped right after its KeyDown. Controls (C0, DEL, C1) are not
#   text, and nothing is typed while Ctrl, Alt (Mod1) or Super (Mod4) is
#   held; AltGr (Mod5) types. A press with keycode 0 is an input method's
#   result (a dead key or compose sequence completed): text, no KeyDown.
#   Without an input context, records carry keysyms (Keys.unicode).
# - clipboard: requests and the loss of ownership for CLIPBOARD become
#   Clipboard events; the owner's answer to a paste is read after the
#   batch (x11_clip_take) and becomes Pasted or PasteFailed (61 when there
#   is no owner or it refused).
# - time: key and button events stamp the window with their server time.

type Decode is Data:
  Decode{win: Win, out: List<&2, Input>, ask: Bool, release: U32, at: U32,
    paste: Bool, text: List<&2, U32>}

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
  Decode{win, out, ask, r, t, pa, tx} = d
  Decode{win, push(ev, out), ask, 0, 0, pa, tx}

def keep(d: Decode) -> Decode:
  Decode{win, out, ask, r, t, pa, tx} = d
  Decode{win, out, ask, 0, 0, pa, tx}

def maybe_emit(go: Bool, d: Decode, ev: Input) -> Decode:
  match go:
    case True{}:
      emit(d, ev)
    case False{}:
      keep(d)

def configure.size(d: Decode, +w: U32, +h: U32) -> Decode:
  Decode{Win{dp, pr, n, +ow, +oh, x, y, f, v, k, r, tm}, out, ask, rl, at, pa, tx} = d
  maybe_emit(U32.is_ne(ow, w) || U32.is_ne(oh, h),
    Decode{Win{dp, pr, n, w, h, x, y, f, v, k, r, tm}, out, ask, rl, at, pa, tx}, Resized{w, h})

def configure.place(synthetic: Bool, d: Decode, +x: F32, +y: F32) -> Decode:
  match synthetic:
    case False{}:
      Decode{win, out, ask, r, t, pa, tx} = d
      Decode{win, out, True{}, 0, 0, pa, tx}
    case True{}:
      Decode{Win{dp, pr, n, w, h, +ox, +oy, f, v, k, r, tm}, out, ask, rl, at, pa, tx} = d
      maybe_emit(F32.is_ne(ox, x) || F32.is_ne(oy, y),
        Decode{Win{dp, pr, n, w, h, x, y, f, v, k, r, tm}, out, ask, rl, at, pa, tx}, Moved{x, y})

def configure(d: Decode, +w: U32, +h: U32, +x: U32, +y: U32, +synthetic: U32) -> Decode:
  configure.place(U32.is_ne(synthetic, 0), configure.size(d, w, h), signed(x), signed(y))

def focus.change(d: Decode, +gained: Bool) -> Decode:
  Decode{Win{dp, pr, n, w, h, x, y, +was, v, k, r, tm}, out, ask, rl, at, pa, tx} = d
  +held = Bool.pick(List<&2, U32>, gained, k, Nil{})
  maybe_emit(Bool.xor(was, gained),
    Decode{Win{dp, pr, n, w, h, x, y, gained, v, held, r, tm}, out, ask, rl, at, pa, tx}, Focused{gained})

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
  Decode{Win{dp, pr, n, w, h, x, y, f, +was, k, r, tm}, out, ask, rl, at, pa, tx} = d
  +now = U32.is_ne(mapped, 0)
  maybe_emit(Bool.xor(was, now),
    Decode{Win{dp, pr, n, w, h, x, y, f, now, k, r, tm}, out, ask, rl, at, pa, tx}, Shown{now})

def drop_head(drop: Bool, xs: List<&2, Input>) -> List<&2, Input>:
  match drop xs:
    case True{} Con{h, t}:
      t
    case _ ys:
      ys

# A press right after a release of the same key with the same timestamp is
# X autorepeat without detection: drop that release, flag the press.
def key.press(d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  Decode{Win{dp, pr, n, w, h, x, y, f, v, +held, r, tm}, out, ask, +release, +at, pa, tx} = d
  +pair = U32.is_ne(release, 0) && U32.is_eq(release, keycode) && U32.is_eq(at, time)
  +repeat = pair || has(held, keycode)
  +now = Bool.pick(List<&2, U32>, has(held, keycode), held, keycode <> held)
  Decode{Win{dp, pr, n, w, h, x, y, f, v, now, r, tm},
    KeyDown{code, repeat, mods} <> drop_head(pair, out),
    ask, 0, 0, pa, tx}

def key.release(d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  Decode{Win{dp, pr, n, w, h, x, y, f, v, held, r, tm}, out, ask, rl, at, pa, tx} = d
  Decode{Win{dp, pr, n, w, h, x, y, f, v, without(held, keycode), r, tm},
    KeyUp{code, mods} <> out, ask, keycode, time, pa, tx}

# Keycode 0 is the press an input method puts back with its result.
def key.real(real: Bool, d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  match real:
    case True{}:
      key.press(d, code, keycode, mods, time)
    case False{}:
      d

def key.pick(down: Bool, d: Decode, +code: U32, +keycode: U32, +mods: U32, +time: U32) -> Decode:
  match down:
    case True{}:
      key.real(U32.is_ne(keycode, 0), d, code, keycode, mods, time)
    case False{}:
      key.release(d, code, keycode, mods, time)

def key(d: Decode, +sym: U32, +keycode: U32, +down: U32, +state: U32, +chars: U32, +time: U32) -> Decode:
  key.pick(U32.is_ne(down, 0), d, Keys.code(sym, keycode, chars), keycode, Keys.mods(state), time)

def stamp(d: Decode, +time: U32) -> Decode:
  Decode{Win{dp, pr, n, w, h, x, y, f, v, k, r, tm}, out, ask, rl, at, pa, tx} = d
  Decode{Win{dp, pr, n, w, h, x, y, f, v, k, r, time}, out, ask, rl, at, pa, tx}

# Text
# ----

def control(+c: U32) -> Bool:
  U32.is_lt(c, 32) || U32.is_eq(c, 127) || (U32.is_ge(c, 128) && U32.is_le(c, 159))

# Ctrl (4), Mod1 (8) and Mod4 (64) make a key a shortcut, not text.
def typing(+state: U32) -> Bool:
  U32.is_eq((state .&. 76 : U32), 0)

def text.char(drop: Bool, +c: U32, acc: String) -> String:
  match drop:
    case True{}:
      acc
    case False{}:
      SCon{Chr{c}, acc}

# Reversed scalars to a String in order, controls left out.
def text.string(rev: List<&2, U32>, acc: String) -> String:
  match rev:
    case Nil{}:
      acc
    case Con{+c, rest}:
      text.string(rest, text.char(control(c), c, acc))

def text.typed(ok: Bool, rev: List<&2, U32>) -> List<&2, U32>:
  match ok:
    case True{}:
      rev
    case False{}:
      Nil{}

def text.emit(s: String, d: Decode) -> Decode:
  match s:
    case SNil{}:
      keep(d)
    case typed:
      emit(d, TextTyped{typed})

def text.pending(d: Decode, rev: List<&2, U32>) -> Decode:
  Decode{win, out, ask, rl, at, pa, tx} = d
  Decode{win, out, ask, rl, at, pa, rev}

def text.end(more: Bool, d: Decode, rev: List<&2, U32>, +state: U32) -> Decode:
  match more:
    case True{}:
      text.pending(d, rev)
    case False{}:
      text.emit(text.string(text.typed(typing(state), rev), ""), d)

def text.add(take: Bool, rev: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match take:
    case True{}:
      c <> rev
    case False{}:
      rev

def text.scalar(+keysym: Bool, +c: U32) -> U32:
  Bool.pick(U32, keysym, Keys.unicode(c), c)

# flags: count | more << 8 | keysym << 16; up to four scalars; state.
def text(d: Decode, +flags: U32, +c1: U32, +c2: U32, +c3: U32, +c4: U32, +state: U32) -> Decode:
  Decode{win, out, ask, rl, at, pa, tx} = d
  +n = (flags .&. 255 : U32)
  +sym = U32.is_ne(((flags >> 16n) .&. 1 : U32), 0)
  text.end(U32.is_ne(((flags >> 8n) .&. 1 : U32), 0), Decode{win, out, ask, rl, at, pa, Nil{}},
    text.add(U32.is_gt(n, 3), text.add(U32.is_gt(n, 2), text.add(U32.is_gt(n, 1),
      text.add(U32.is_gt(n, 0), tx, text.scalar(sym, c1)), text.scalar(sym, c2)),
      text.scalar(sym, c3)), text.scalar(sym, c4)), state)

# Clipboard
# ---------

def request(d: Decode, +requestor: U32, +property: U32, +target: U32, +time: U32, +clipboard: U32, +atom: U32) -> Decode:
  maybe_emit(U32.is_ne(clipboard, 0), d, Clipboard{Asked{Request{requestor,
    Bool.pick(U32, U32.is_eq(property, 0), atom, property), target, time, atom}}})

def notified.pick(clipboard: Bool, ok: Bool, d: Decode) -> Decode:
  match clipboard ok:
    case False{} _:
      keep(d)
    case True{} True{}:
      Decode{win, out, ask, rl, at, pa, tx} = d
      Decode{win, out, ask, rl, at, True{}, tx}
    case True{} False{}:
      emit(d, Clipboard{PasteFailed{61}})

# Pointer
# -------

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
      key(stamp(d, g), a, b, c, e, f, g)
    case 5:
      button(stamp(d, g), a, b, c, e, f)
    case 6:
      emit(d, PointerMoved{signed(a), signed(b)})
    case 7:
      focus(d, a, b, c)
    case 8:
      crossing(d, a, b, c, e, f)
    case 9:
      shown(d, a)
    case 10:
      text(d, a, b, c, e, f, g)
    case 11:
      request(d, a, b, c, e, f, g)
    case 12:
      maybe_emit(U32.is_ne(a, 0), d, Clipboard{Lost{}})
    case 13:
      notified.pick(U32.is_ne(b, 0), U32.is_ne(a, 0), d)
    case _:
      keep(d)

def slot_of(d: Decode) -> U32:
  Decode{Win{dp, pr, n, w, h, x, y, f, v, k, r, tm}, out, ask, rl, at, pa, tx} = d
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

# Folds bridge words into the next window state, the events in order,
# whether the position must be asked of the server and whether a paste
# answer waits on the window.
def decoded(d: Decode) -> Win & List<&2, Input> & Bool & Bool:
  Decode{w, out, ask, r, t, pa, tx} = d
  (w, List.reverse(&2, Input, out), ask, pa)

def decode(ws: List<&2, U32>, win: Win) -> Win & List<&2, Input> & Bool & Bool:
  decoded(decode.go(ws, Decode{win, Nil{}, False{}, 0, 0, False{}, Nil{}}))

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
    # A second connection for GPU presentation: driver threads that read
    # it never consume the readiness of the connection events come from.
    +presenter : U32 <- IO.try(U32, N.x11_connect())
    IO.try(Unit, N.x11_map(win))
    # Text input through Xlib's local input method (dead keys, compose,
    # AltGr); without one, text arrives as keysyms.
    +im : U32 <- IO.try(U32, N.x11_input(win))
    return Win{dpy, presenter, win, w, h, 0.0, 0.0, False{}, False{}, Nil{}, U32.is_ne(repeat, 0), 0}

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

# Destroys the window, then its presentation and event connections.
# Answers how many native objects the bridge still holds (0 when nothing
# leaked). Destroy every GPU surface made from the window first.
def close(w: Win) -> IO(U32):
  Win{+dpy, +pr, +win, wd, h, x, y, f, v, k, r, tm} = w
  do IO<U32>:
    IO.try(Unit, N.x11_destroy(win))
    IO.try(Unit, N.x11_destroy(pr))
    IO.try(Unit, N.x11_destroy(dpy))
    IO.try(U32, N.x11_live())

def set_title(+w: Win, title: String) -> IO(Win):
  do IO<Win>:
    IO.try(Unit, N.x11_title(window(w), title))
    return w

def presenter(w: Win) -> U32:
  Win{d, presenter, n, wd, h, x, y, f, v, k, r, tm} = w
  presenter

# The native handle for a GPU surface: [1 (Xlib), Display* high word,
# Display* low word, Window id, screen]. The display is Ankra's dedicated
# presentation connection, not the one events are read from: a Vulkan
# driver reads its connection from its own threads, and on a shared one
# it consumed the socket's readiness, delaying input until some later
# event (measured: about 0.8 s per synthetic click). Valid until `close`.
def native(+w: Win) -> IO(List<&2, U32>):
  IO.try(List<&2, U32>, N.x11_native(window(w), presenter(w)))

# Waiting
# -------

def placed.at(moved: Bool, w: Win, es: List<&2, Input>, +x: F32, +y: F32) -> Win & List<&2, Input>:
  match moved:
    case False{}:
      (w, es)
    case True{}:
      Win{dp, pr, n, wd, h, ox, oy, f, v, k, r, tm} = w
      (Win{dp, pr, n, wd, h, x, y, f, v, k, r, tm}, List.append(&2, Input, es, [Moved{x, y}]))

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

# Clipboard text longer than this many scalars is refused (PasteFailed 27).
def paste_limit() -> U32:
  4096

def taken(r: Result<&1, &1, U32 & String, String>) -> Input:
  match r:
    case Done{text}:
      Clipboard{Pasted{text}}
    case Fail{(code, message)}:
      Clipboard{PasteFailed{code}}

def pasted(paste: Bool, got: Win & List<&2, Input>) -> IO(Win & List<&2, Input>):
  match paste:
    case False{}:
      IO.pure(Win & List<&2, Input>, got)
    case True{}:
      (+w, es) = got
      do IO<Win & List<&2, Input>>:
        r : Result<&1, &1, U32 & String, String> <- N.x11_clip_take(window(w), paste_limit())
        return (w, List.append(&2, Input, es, [taken(r)]))

def waited(d: Win & List<&2, Input> & Bool & Bool) -> IO(Win & List<&2, Input>):
  (w, rest) = d
  (es, flags) = rest
  (ask, paste) = flags
  do IO<Win & List<&2, Input>>:
    got : Win & List<&2, Input> <- asked(ask, w, es)
    pasted(paste, got)

# Whether the bridge's words hold the record (kind 14) saying the watched
# descriptor is readable. It names no window, so `decode` skips it.
def watched(ws: List<&2, U32>) -> Bool:
  match ws:
    case Con{14, rest}:
      True{}
    case Con{k, Con{s, Con{a, Con{b, Con{c, Con{e, Con{f, Con{g, rest}}}}}}}}:
      watched(rest)
    case _:
      False{}

def waited.with(+woke: Bool, got: Win & List<&2, Input>) -> Win & List<&2, Input> & Bool:
  (w, es) = got
  (w, es, woke)

# One wait on the connection, decoded, and whether the watched descriptor
# ended it.
def wait.once(+w: Win, ms: U32) -> IO(Win & List<&2, Input> & Bool):
  do IO<Win & List<&2, Input> & Bool>:
    +ws : List<&2, U32> <- IO.try(List<&2, U32>, N.x11_wait(display(w), ms))
    got : Win & List<&2, Input> <- waited(decode(ws, w))
    return waited.with(watched(ws), got)

def wait.plain(got: Win & List<&2, Input> & Bool) -> Win & List<&2, Input>:
  (w, rest) = got
  (es, woke) = rest
  (w, es)

# The milliseconds left before `due`, or `forever()` without a deadline.
def wait.left(+forever: Bool, +due: Nat, +now: Nat) -> U32:
  Bool.pick(U32, forever, 4294967295, U32.from_nat(Nat.sub(due, now)))

def wait.over(+forever: Bool, +due: Nat, +now: Nat) -> Bool:
  Bool.not(forever) && Bool.not(Nat.is_lt(now, due))

def wait.sorted(es: List<&2, Input>, +w: Win, +over: Bool,
  again: Win -> IO(Win & List<&2, Input>)) -> IO(Win & List<&2, Input>):
  match es over:
    case Nil{} False{}:
      again(w)
    case xs _:
      IO.pure(Win & List<&2, Input>, (w, xs))

# Waits again while nothing decoded, the deadline is ahead and the watched
# descriptor did not end the wait.
def wait.until(n: Nat, got: Win & List<&2, Input> & Bool, +forever: Bool, +due: Nat) -> IO(Win & List<&2, Input>):
  match n:
    case 0n:
      IO.pure(Win & List<&2, Input>, wait.plain(got))
    case 1n+p:
      (+w, rest) = got
      (es, woke) = rest
      do IO<Win & List<&2, Input>>:
        +now : Nat <- IO.now()
        wait.sorted(es, w, woke || wait.over(forever, due, now), ww => IO.bind(Win & List<&2, Input> & Bool,
          Win & List<&2, Input>, wait.once(ww, wait.left(forever, due, now)),
          g => wait.until(p, g, forever, due)))

def wait.timed(+w: Win, +ms: U32) -> IO(Win & List<&2, Input>):
  +forever = U32.is_eq(ms, forever())
  do IO<Win & List<&2, Input>>:
    +start : Nat <- IO.now()
    got : Win & List<&2, Input> & Bool <- wait.once(w, ms)
    wait.until(4294967295n, got, forever, Nat.add(start, U32.to_nat(ms)))

def wait.pick(poll: Bool, +w: Win, +ms: U32) -> IO(Win & List<&2, Input>):
  match poll:
    case True{}:
      do IO<Win & List<&2, Input>>:
        got : Win & List<&2, Input> & Bool <- wait.once(w, 0)
        return wait.plain(got)
    case False{}:
      wait.timed(w, ms)

# Waits up to `ms` milliseconds for events: 0 polls, `forever()` waits
# without a deadline. The wait parks on the X connection (and the watched
# descriptor, see `watch`): an idle window costs no CPU and no wakeups.
# Answers the next window state and the decoded events in order. An empty
# list means the deadline passed or the watched descriptor is readable: X
# events that decode to nothing (a configure that changed nothing, an
# ignored focus change) do not end the wait early.
def wait(+w: Win, +ms: U32) -> IO(Win & List<&2, Input>):
  wait.pick(U32.is_eq(ms, 0), w, ms)

# Makes every later wait also end when the file descriptor `fd` is
# readable (or hung up): a second event source, such as an accessibility
# bus socket, without polling it on a timer. `unwatched()` stops. The wait
# answers the window's events, possibly none; the app then reads `fd`
# itself. Reading it until it would block keeps the next wait asleep. A
# descriptor closed later stops counting by itself.
def watch(+w: Win, fd: U32) -> IO(Win):
  do IO<Win>:
    IO.try(Unit, N.x11_watch(display(w), fd))
    return w

def unwatched() -> U32:
  4294967295

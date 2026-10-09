import Base
import ./main.bend as A
import ./window.bend as W
import ./keys.bend as Keys
import ./app.bend as Loop
import ./clipboard.bend as C

# Native checks that run without a display: the official-runtime loop's
# batching and bounds (main.bend), and the native backend's decoding of
# bridge words into window state and events, key codes and the loop's
# decisions (window.bend, keys.bend, app.bend).

def check(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.print("PASS " ++ message)
    case False{}: IO.die(Unit, 1, "FAIL " ++ message)

def rejected(result: Result<&1, &1, U32 & String, Window>) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      check(U32.is_eq(code, 22), "invalid window rejected before allocation")
    case Done{window}:
      do IO<Unit>:
        Window.close(window)
        IO.die(Unit, 1, "invalid dimensions unexpectedly opened a window")

def native_rejected(result: Result<&1, &1, U32 & String, W.Win>) -> IO(Unit):
  match result:
    case Fail{(code, message)}:
      check(U32.is_eq(code, 22), "native window: invalid size rejected before connecting")
    case Done{w}:
      IO.die(Unit, 1, "invalid dimensions unexpectedly opened a native window")

def batch_empty(batch: A.Batch) -> Bool:
  match batch:
    case A.Batch{False{}, 0, Nil{}}: True{}
    case _: False{}

def batch_order(batch: A.Batch) -> Bool:
  match batch:
    case A.Batch{True{}, 4, Move{7, 9} <> Mouse{7, 9, 0, True{}} <> Key{32, False{}} <> Close{} <> Nil{}}:
      True{}
    case _: False{}

# Decoding
# --------

# A 640x400 window in slot 2 of display 1, focused and mapped at (10, 20).
def win() -> W.Win:
  W.Win{1, 5, 2, 640, 400, 10.0, 20.0, True{}, True{}, Nil{}, True{}, 0}

def ev(+k: U32, +a: U32, +b: U32, +c: U32, +d: U32, +e: U32, +f: U32) -> List<&2, U32>:
  [k, 2, a, b, c, d, e, f]

def events.of(r: W.Win & List<&2, W.Input> & Bool & Bool) -> List<&2, W.Input>:
  (w, rest) = r
  (es, flags) = rest
  es

def state.of(r: W.Win & List<&2, W.Input> & Bool & Bool) -> W.Win:
  (w, rest) = r
  w

def asks.of(r: W.Win & List<&2, W.Input> & Bool & Bool) -> Bool:
  (w, rest) = r
  (es, flags) = rest
  (ask, paste) = flags
  ask

def pastes.of(r: W.Win & List<&2, W.Input> & Bool & Bool) -> Bool:
  (w, rest) = r
  (es, flags) = rest
  (ask, paste) = flags
  paste

def events(ws: List<&2, U32>) -> List<&2, W.Input>:
  events.of(W.decode(ws, win()))

def state(ws: List<&2, U32>) -> W.Win:
  state.of(W.decode(ws, win()))

def asks(ws: List<&2, U32>) -> Bool:
  asks.of(W.decode(ws, win()))

def pastes(ws: List<&2, U32>) -> Bool:
  pastes.of(W.decode(ws, win()))

def none(es: List<&2, W.Input>) -> Bool:
  match es:
    case Nil{}: True{}
    case _: False{}

def is_resized(es: List<&2, W.Input>, +w: U32, +h: U32) -> Bool:
  match es:
    case Con{W.Resized{a, b}, Nil{}}: U32.is_eq(a, w) && U32.is_eq(b, h)
    case _: False{}

def is_moved(es: List<&2, W.Input>, +x: F32, +y: F32) -> Bool:
  match es:
    case Con{W.Moved{a, b}, Nil{}}: F32.is_eq(a, x) && F32.is_eq(b, y)
    case _: False{}

def is_focus(es: List<&2, W.Input>, +g: Bool) -> Bool:
  match es:
    case Con{W.Focused{a}, Nil{}}: Bool.not(Bool.xor(a, g))
    case _: False{}

def key_downs(es: List<&2, W.Input>) -> List<&2, U32>:
  match es:
    case Nil{}: Nil{}
    case Con{W.KeyDown{c, r, m}, rest}: c <> Bool.to_u32(r) <> m <> key_downs(rest)
    case Con{W.KeyUp{c, m}, rest}: 1000 <> c <> key_downs(rest)
    case Con{e, rest}: key_downs(rest)

def same(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}: True{}
    case Con{a, ra} Con{b, rb}: U32.is_eq(a, b) && same(ra, rb)
    case _ _: False{}

def is_button(es: List<&2, W.Input>, +down: Bool, +button: U32) -> Bool:
  match es:
    case Con{W.PointerDown{x, y, b, m}, Nil{}}: down && U32.is_eq(b, button)
    case Con{W.PointerUp{x, y, b, m}, Nil{}}: Bool.not(down) && U32.is_eq(b, button)
    case _: False{}

def is_wheel(es: List<&2, W.Input>, +dx: F32, +dy: F32) -> Bool:
  match es:
    case Con{W.Wheel{x, y, a, b}, Nil{}}: F32.is_eq(a, dx) && F32.is_eq(b, dy)
    case _: False{}

def is_pointer(es: List<&2, W.Input>, +x: F32, +y: F32) -> Bool:
  match es:
    case Con{W.PointerMoved{a, b}, Nil{}}: F32.is_eq(a, x) && F32.is_eq(b, y)
    case _: False{}

def count(es: List<&2, W.Input>) -> U32:
  U32.from_nat(List.length(&2, W.Input, es))

def is_left(es: List<&2, W.Input>) -> Bool:
  match es:
    case Con{W.PointerLeft{}, Nil{}}: True{}
    case _: False{}

def is_shown(es: List<&2, W.Input>, +v: Bool) -> Bool:
  match es:
    case Con{W.Shown{a}, Nil{}}: Bool.not(Bool.xor(a, v))
    case _: False{}

def no_keys(w: W.Win) -> Bool:
  W.Win{d, pr, n, wd, h, x, y, f, v, k, r, tm} = w
  U32.is_eq(U32.from_nat(List.length(&2, U32, k)), 0)

# keysym, keycode, down, state, chars (count << 8 | byte), time
def key(+sym: U32, +code: U32, +down: U32, +state: U32, +chars: U32, +time: U32) -> List<&2, U32>:
  [4, 2, sym, code, down, state, chars, time]

# Text and clipboard
# ------------------

# A text record: count | more << 8 | keysym << 16, four scalars, state.
def txt(+flags: U32, +a: U32, +b: U32, +c: U32, +d: U32, +state: U32) -> List<&2, U32>:
  [10, 2, flags, a, b, c, d, state]

def cat(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xs)

def chars(s: String) -> List<&2, U32>:
  match s:
    case SNil{}: Nil{}
    case SCon{Chr{c}, rest}: c <> chars(rest)

# Events as words: KeyDown code repeat, KeyUp 1000 code, TextTyped 2000
# then its scalars, clipboard events 3000 + kind and their fields.
def trace(es: List<&2, W.Input>) -> List<&2, U32>:
  match es:
    case Nil{}: Nil{}
    case Con{W.KeyDown{c, r, m}, rest}: c <> Bool.to_u32(r) <> trace(rest)
    case Con{W.KeyUp{c, m}, rest}: 1000 <> c <> trace(rest)
    case Con{W.TextTyped{t}, rest}: 2000 <> List.append(&2, U32, chars(t), trace(rest))
    case Con{W.Clipboard{W.Asked{W.Request{q, p, t, tm, a}}}, rest}: 3001 <> q <> p <> t <> tm <> a <> trace(rest)
    case Con{W.Clipboard{W.Lost{}}, rest}: 3002 <> trace(rest)
    case Con{W.Clipboard{W.Pasted{t}}, rest}: 3003 <> List.append(&2, U32, chars(t), trace(rest))
    case Con{W.Clipboard{W.PasteFailed{c}}, rest}: 3004 <> c <> trace(rest)
    case Con{e, rest}: 9999 <> trace(rest)

def traced(ws: List<&2, U32>) -> List<&2, U32>:
  trace(events(ws))

def request(+target: U32) -> W.Request:
  W.Request{77, 88, target, 5, 99}

def is_refused(a: C.Answer) -> Bool:
  match a:
    case C.Refuse{}: True{}
    case _: False{}

def is_targets(a: C.Answer, +latin1: Bool) -> Bool:
  match a:
    case C.Targets{l}: Bool.not(Bool.xor(l, latin1))
    case _: False{}

def is_utf8(a: C.Answer, +want: String) -> Bool:
  match a:
    case C.Utf8{t}: String.eq(t, want)
    case _: False{}

def is_latin1(a: C.Answer, +want: String) -> Bool:
  match a:
    case C.Latin1{t}: String.eq(t, want)
    case _: False{}

# The loop's decisions
# --------------------

def finished(t: Loop.Turn<U32>, +want: U32) -> Bool:
  match t:
    case Loop.Finish{w, s}: U32.is_eq(s, want)
    case _: False{}

def continued(t: Loop.Turn<U32>, +want: U32, +dirty: Bool, +ms: U32) -> Bool:
  match t:
    case Loop.Continue{w, s, d, m}: U32.is_eq(s, want) && Bool.not(Bool.xor(d, dirty)) && U32.is_eq(m, ms)
    case _: False{}

def main() -> IO(Unit):
  do IO<Unit>:
    check(batch_empty(A.collect(Nil{})), "empty batch")
    check(batch_order(A.collect([Move{7, 9}, Mouse{7, 9, 0, True{}}, Key{32, False{}}, Close{}])), "event order and close")
    check(A.valid_size(1, 1) && A.valid_size(4096, 4096), "accepted bounds")
    check(Bool.not(A.valid_size(0, 1)) && Bool.not(A.valid_size(1, 4097)), "invalid bounds")
    zero : Result<&1, &1, U32 & String, Window> <- A.open("Ankra invalid", 0, 8)
    rejected(zero)
    big : Result<&1, &1, U32 & String, Window> <- A.open("Ankra invalid", 8, 4097)
    rejected(big)
    tiny : Result<&1, &1, U32 & String, W.Win> <- W.open(W.options("Ankra invalid", 0, 8))
    native_rejected(tiny)
    check(is_resized(events(ev(2, 800, 500, 10, 20, 1, 0)), 800, 500), "configure: new size is one Resized")
    check(none(events(ev(2, 640, 400, 10, 20, 1, 0))), "configure: unchanged size and position say nothing")
    check(is_moved(events(ev(2, 640, 400, 300, 4294967246, 1, 0)), 300.0, F32.neg(50.0)), "configure: synthetic position is a signed Moved")
    check(asks(ev(2, 640, 400, 0, 0, 0, 0)) && none(events(ev(2, 640, 400, 0, 0, 0, 0))), "configure: real event asks the server for the position")
    check(is_focus(events(ev(7, 0, 0, 3, 0, 0, 0)), False{}), "focus: a real focus out")
    check(none(events(ev(7, 0, 1, 3, 0, 0, 0))) && none(events(ev(7, 0, 2, 3, 0, 0, 0))), "focus: grab and ungrab changes ignored")
    check(none(events(ev(7, 0, 0, 5, 0, 0, 0))) && none(events(ev(7, 0, 0, 2, 0, 0, 0))), "focus: pointer and inferior details ignored")
    check(none(events(ev(7, 1, 0, 3, 0, 0, 0))), "focus: no event when focus does not change")
    check(no_keys(state(List.append(&2, U32, key(97, 38, 1, 0, 353, 5), ev(7, 0, 0, 3, 0, 0, 0)))), "focus: losing focus forgets held keys")
    check(same(key_downs(events(key(65293, 36, 1, 0, 269, 9))), [13, 0, 0]), "key: Return is 13")
    check(same(key_downs(events(key(65056, 23, 1, 1, 0, 9))), [25, 0, 1]), "key: Shift+Tab is 25 with shift")
    check(same(key_downs(events(key(65, 38, 1, 1, 321, 9))), [97, 0, 1]), "key: shifted letter reads lower case")
    check(same(key_downs(events(key(65474, 71, 1, 0, 0, 9))), [63240, 0, 0]), "key: F5")
    check(same(key_downs(events(key(65288, 22, 1, 0, 264, 9))), [127, 0, 0]), "key: BackSpace is 127")
    check(same(key_downs(events(key(269025042, 121, 1, 0, 0, 9))), [65657, 0, 0]), "key: unmapped key is 65536 + keycode")
    check(U32.is_eq(Keys.mods(69), 11), "key: Shift, Control and Super modifiers")
    check(same(key_downs(events(List.append(&2, U32, key(32, 65, 1, 0, 288, 7), key(32, 65, 1, 0, 288, 40)))), [32, 0, 0, 32, 1, 0]), "key: a held key's press is a repeat")
    check(same(key_downs(events(List.append(&2, U32, key(32, 65, 1, 0, 288, 7),
      List.append(&2, U32, key(32, 65, 0, 0, 288, 40), key(32, 65, 1, 0, 288, 40))))), [32, 0, 0, 32, 1, 0]),
      "key: release+press with one timestamp collapses into a repeat")
    check(same(key_downs(events(List.append(&2, U32, key(32, 65, 1, 0, 288, 7), key(32, 65, 0, 0, 288, 40)))), [32, 0, 0, 1000, 32]), "key: a plain release")
    check(is_button(events(ev(5, 5, 6, 1, 1, 0, 0)), True{}, 0) && is_button(events(ev(5, 5, 6, 3, 0, 0, 0)), False{}, 1), "pointer: buttons 1 and 3 are primary 0 and secondary 1")
    check(is_button(events(ev(5, 5, 6, 2, 1, 0, 0)), True{}, 2), "pointer: middle button is 2")
    check(is_wheel(events(ev(5, 5, 6, 4, 1, 0, 0)), 0.0, 1.0) && is_wheel(events(ev(5, 5, 6, 7, 1, 0, 0)), F32.neg(1.0), 0.0), "pointer: wheel notches as in Base")
    check(none(events(ev(5, 5, 6, 5, 0, 0, 0))), "pointer: wheel releases ignored")
    check(is_pointer(events(List.append(&2, U32, ev(6, 1, 2, 0, 0, 0, 0), ev(6, 3, 4, 0, 0, 0, 0))), 3.0, 4.0), "pointer: consecutive motions keep the last")
    check(is_left(events(ev(8, 0, 1, 1, 0, 0, 0))) && none(events(ev(8, 0, 1, 1, 1, 0, 0))), "pointer: leave reported, grab crossing ignored")
    check(U32.is_eq(count(events(List.append(&2, U32, ev(3, 0, 0, 9, 9, 1, 0), List.append(&2, U32, ev(3, 0, 0, 9, 9, 0, 0), ev(3, 0, 0, 9, 9, 0, 0))))), 1), "expose: one event per batch, after the last region")
    check(is_shown(events(ev(9, 0, 0, 0, 0, 0, 0)), False{}), "map: unmapping reported")
    check(W.closing(events(ev(1, 0, 0, 0, 0, 0, 0))), "close request")
    check(none(events([1, 3, 0, 0, 0, 0, 0, 0])), "events of another window are not ours")
    check(W.watched(cat([ev(6, 1, 2, 0, 0, 0, 0), [14, 0, 0, 0, 0, 0, 0, 0]])) && is_pointer(events(cat([ev(6, 1, 2, 0, 0, 0, 0), [14, 0, 0, 0, 0, 0, 0, 0]])), 1.0, 2.0) &&
      Bool.not(W.watched(ev(6, 14, 14, 0, 0, 0, 0))), "watch: the watched descriptor's record ends a wait and decodes to nothing")
    check(F32.is_eq(W.signed(4294967295), F32.neg(1.0)), "signed coordinates")
    check(finished(Loop.next(U32, True{}, win(), Loop.Keep{7}, False{}), 7), "loop: a close request finishes after update")
    check(continued(Loop.next(U32, False{}, win(), Loop.Keep{7}, True{}), 7, True{}, W.forever()), "loop: Keep waits without deadline, an owed frame stays owed")
    check(continued(Loop.next(U32, False{}, win(), Loop.Redraw{8}, False{}), 8, True{}, W.forever()), "loop: Redraw marks the content stale")
    check(continued(Loop.next(U32, False{}, win(), Loop.Sleep{9, 50}, False{}), 9, False{}, 50), "loop: Sleep sets the next deadline")
    check(finished(Loop.next(U32, False{}, win(), Loop.Stop{3}, False{}), 3), "loop: Stop hands the final state back")
    check(same(traced(cat([key(97, 38, 1, 0, 353, 5), txt(1, 97, 0, 0, 0, 0)])), [97, 0, 2000, 97]), "text: KeyDown, then TextTyped a")
    check(same(traced(cat([key(0, 0, 1, 0, 0, 5), txt(1, 227, 0, 0, 0, 0)])), [2000, 227]), "text: an input method's result (keycode 0) is text without a KeyDown")
    check(same(traced(cat([key(97, 38, 1, 0, 353, 5), txt(260, 111, 108, 225, 32, 0), txt(1, 120, 0, 0, 0, 0)])), [97, 0, 2000, 111, 108, 225, 32, 120]),
      "text: a 5-scalar commit split across records is one TextTyped")
    check(same(traced(cat([key(99, 54, 1, 4, 355, 5), txt(1, 3, 0, 0, 0, 4)])), [99, 0]), "text: Ctrl+C (0x03) types nothing")
    check(same(traced(cat([key(65293, 36, 1, 0, 269, 5), txt(1, 13, 0, 0, 0, 0), key(65288, 22, 1, 0, 264, 6), txt(1, 127, 0, 0, 0, 0), txt(2, 133, 97, 0, 0, 0)])), [13, 0, 127, 0, 2000, 97]),
      "text: C0, DEL and C1 controls are not text")
    check(same(traced(cat([txt(1, 99, 0, 0, 0, 4), txt(1, 99, 0, 0, 0, 8), txt(1, 99, 0, 0, 0, 64)])), []), "text: none while Ctrl, Alt or Super is held")
    check(same(traced(cat([txt(1, 47, 0, 0, 0, 128), txt(1, 65, 0, 0, 0, 1)])), [2000, 47, 2000, 65]), "text: AltGr (Mod5) and Shift keep the text")
    check(same(traced(cat([txt(65537, 231, 0, 0, 0, 0), txt(65537, 16785580, 0, 0, 0, 0), txt(65537, 65105, 0, 0, 0, 0)])), [2000, 231, 2000, 8364]),
      "text: keysym fallback maps 0xE7 to ç, 0x10020AC to €, dead_acute to nothing")
    check(U32.is_eq(Keys.unicode(126), 126) && U32.is_eq(Keys.unicode(160), 160) && U32.is_eq(Keys.unicode(65288), 0) &&
      U32.is_eq(Keys.unicode(16832512), 0), "text: Keys.unicode bounds (ASCII, NBSP, BackSpace, a surrogate)")
    check(same(traced(cat([key(97, 38, 1, 0, 353, 5), txt(1, 97, 0, 0, 0, 0), key(97, 38, 1, 0, 353, 40), txt(1, 97, 0, 0, 0, 0),
      key(97, 38, 1, 0, 353, 70), txt(1, 97, 0, 0, 0, 0)])), [97, 0, 2000, 97, 97, 1, 2000, 97, 97, 1, 2000, 97]),
      "text: a held key repeats KeyDown with one TextTyped each")
    check(same(traced(cat([key(97, 38, 1, 0, 353, 7), txt(1, 97, 0, 0, 0, 0), key(97, 38, 0, 0, 353, 40), key(97, 38, 1, 0, 353, 40),
      txt(1, 97, 0, 0, 0, 0)])), [97, 0, 2000, 97, 97, 1, 2000, 97]),
      "text: release+press with one timestamp still collapses with text records around it")
    check(same(traced(cat([ev(11, 77, 88, 2, 5, 1, 99), ev(11, 77, 0, 3, 5, 1, 31), ev(11, 77, 88, 2, 5, 0, 99)])), [3001, 77, 88, 2, 5, 99, 3001, 77, 31, 3, 5, 31]),
      "clipboard: requests decode (no property means the target atom; PRIMARY is not ours)")
    check(same(traced(cat([ev(12, 1, 9, 0, 0, 0, 0), ev(12, 0, 9, 0, 0, 0, 0), ev(13, 0, 1, 0, 0, 0, 0)])), [3002, 3004, 61]),
      "clipboard: lost ownership, and a refused paste fails with 61")
    check(pastes(ev(13, 1, 1, 0, 0, 0, 0)) && none(events(ev(13, 1, 1, 0, 0, 0, 0))) && Bool.not(pastes(ev(13, 1, 0, 0, 0, 0, 0))),
      "clipboard: an answered paste is read after the batch")
    check(U32.is_eq(W.time(state(cat([key(97, 38, 1, 0, 353, 5), ev(5, 5, 6, 1, 1, 0, 812)]))), 812) &&
      U32.is_eq(W.time(state(key(97, 38, 0, 0, 353, 640))), 640) && U32.is_eq(W.time(win()), 0), "time: key and button events stamp the window")
    check(is_targets(C.answer(C.Clip{True{}, "ação"}, request(1)), True{}) && is_targets(C.answer(C.Clip{True{}, "5 €"}, request(1)), False{}),
      "clipboard answer: TARGETS lists STRING only for Latin-1 text")
    check(is_utf8(C.answer(C.Clip{True{}, "5 €"}, request(2)), "5 €") && is_latin1(C.answer(C.Clip{True{}, "ã"}, request(3)), "ã"),
      "clipboard answer: UTF8_STRING, and STRING for Latin-1 text")
    check(is_refused(C.answer(C.Clip{True{}, "5 €"}, request(3))) && is_utf8(C.answer(C.Clip{True{}, "5 €"}, request(4)), "5 €") &&
      is_latin1(C.answer(C.Clip{True{}, "ã"}, request(4)), "ã"), "clipboard answer: € refused as STRING; TEXT falls back to UTF-8")
    check(is_refused(C.answer(C.Clip{True{}, "a"}, request(0))) && is_refused(C.answer(C.Clip{False{}, "a"}, request(2))) &&
      is_refused(C.answer(C.none(), request(1))), "clipboard answer: unknown target, or a clipboard not owned, is refused")
    IO.print("62 Ankra checks passed")

import Base
import ../window.bend as W
import ../app.bend as Loop
import ../clipboard.bend as C

# Ankra's native X11 window without a renderer: the server paints the
# background, and the program prints every event it receives (resize,
# position, focus, visibility, keys, pointer, close). Between events it
# waits without a deadline, so an idle window costs no CPU. Resize it, move
# it, focus other windows, type (dead keys and AltGr work), press Ctrl+C to
# copy "Ankra: ação" and Ctrl+V to paste, then close it normally (or press
# Escape).

# `asked`: IO.now() (ms) when a paste was asked of another owner.
type Log is Data:
  Log{events: U32, turns: U32, clip: C.Clip, asked: Nat}

def clip_event(e: W.ClipEvent) -> String:
  match e:
    case W.Asked{W.Request{q, p, t, tm, a}}:
      "clipboard asked for target " ++ U32.show(t)
    case W.Lost{}:
      "clipboard lost"
    case W.Pasted{t}:
      "pasted \"" ++ t ++ "\""
    case W.PasteFailed{c}:
      "paste failed (" ++ U32.show(c) ++ ")"

def show(e: W.Input) -> String:
  match e:
    case W.Resized{w, h}:
      "resized " ++ U32.show(w) ++ "x" ++ U32.show(h)
    case W.Moved{x, y}:
      "moved to " ++ F32.show(x) ++ "," ++ F32.show(y)
    case W.Focused{g}:
      Bool.pick(String, g, "focus in", "focus out")
    case W.Exposed{}:
      "exposed"
    case W.Shown{v}:
      Bool.pick(String, v, "mapped", "unmapped")
    case W.CloseRequested{}:
      "close requested"
    case W.KeyDown{c, r, m}:
      "key down " ++ U32.show(c) ++ Bool.pick(String, r, " (repeat)", "") ++ " mods " ++ U32.show(m)
    case W.KeyUp{c, m}:
      "key up " ++ U32.show(c)
    case W.PointerMoved{x, y}:
      "pointer " ++ F32.show(x) ++ "," ++ F32.show(y)
    case W.PointerDown{x, y, b, m}:
      "button " ++ U32.show(b) ++ " down at " ++ F32.show(x) ++ "," ++ F32.show(y)
    case W.PointerUp{x, y, b, m}:
      "button " ++ U32.show(b) ++ " up"
    case W.PointerEntered{x, y}:
      "pointer entered"
    case W.PointerLeft{}:
      "pointer left"
    case W.Wheel{x, y, dx, dy}:
      "wheel " ++ F32.show(dx) ++ "," ++ F32.show(dy)
    case W.TextTyped{t}:
      "text \"" ++ t ++ "\""
    case W.Clipboard{c}:
      clip_event(c)

def print_all(es: List<&2, W.Input>) -> IO(Unit):
  match es:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{e, rest}:
      do IO<Unit>:
        IO.print("ankra: " ++ show(e))
        print_all(rest)

def escape(es: List<&2, W.Input>) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{W.KeyDown{27, r, m}, rest}:
      True{}
    case Con{e, rest}:
      escape(rest)

# Ctrl+C (1) or Ctrl+V (2) in a batch, the last one winning; 0 for none.
def command(es: List<&2, W.Input>, +last: U32) -> U32:
  match es:
    case Nil{}:
      last
    case Con{W.KeyDown{+c, r, +m}, rest}:
      +ctrl = U32.is_ne((m .&. 2 : U32), 0)
      command(rest, Bool.pick(U32, ctrl && U32.is_eq(c, 99), 1,
        Bool.pick(U32, ctrl && U32.is_eq(c, 118), 2, last)))
    case Con{e, rest}:
      command(rest, last)

# Milliseconds since a paste was asked, when its answer is in the batch.
def answered(es: List<&2, W.Input>, +asked: Nat, +now: Nat) -> IO(Unit):
  match es:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{W.Clipboard{W.Pasted{t}}, rest}:
      IO.print("ankra: paste answered in " ++ Nat.show(Nat.sub(now, asked)) ++ " ms")
    case Con{e, rest}:
      answered(rest, asked, now)

def pasted(m: Maybe<&2, String>) -> IO(Unit):
  match m:
    case Some{t}:
      IO.print("ankra: pasted \"" ++ t ++ "\" (own clipboard)")
    case None{}:
      IO.print("ankra: paste asked of the clipboard owner")

def act(+code: U32, +win: W.Win, +c: C.Clip, +asked: Nat, +n: U32, +t: U32) -> IO(Log):
  match code:
    case 1:
      do IO<Log>:
        +k : C.Clip <- C.copy(win, "Ankra: ação")
        IO.print("ankra: copied \"Ankra: ação\", owner: " ++ Bool.show(C.owned(k)))
        return Log{n, t, k, asked}
    case 2:
      do IO<Log>:
        +now : Nat <- IO.now()
        got : Maybe<&2, String> <- C.paste(win, c)
        pasted(got)
        return Log{n, t, c, now}
    case _:
      IO.pure(Log, Log{n, t, c, asked})

def counted(+win: W.Win, +es: List<&2, W.Input>, log: Log) -> IO(Loop.Step<Log>):
  Log{+n, +t, clip, +asked} = log
  do IO<Loop.Step<Log>>:
    print_all(es)
    +now : Nat <- IO.now()
    answered(es, asked, now)
    served : C.Clip <- C.serve(win, clip, es)
    +next : Log <- act(command(es, 0), win, served, asked,
      (n + U32.from_nat(List.length(&2, W.Input, es)) : U32), (t + 1 : U32))
    return Bool.pick(Loop.Step<Log>, escape(es), Loop.Stop{next}, Loop.Keep{next})

def update(win: W.Win, es: List<&2, W.Input>, log: Log) -> IO(Loop.Step<Log>):
  counted(win, es, log)

def draw(win: W.Win, log: Log) -> IO(Loop.Step<Log>):
  IO.pure(Loop.Step<Log>, Loop.Keep{log})

def finished(end: W.Win & Log) -> IO(Unit):
  (w, log) = end
  Log{n, t, c, a} = log
  do IO<Unit>:
    +left : U32 <- W.close(w)
    IO.print("ankra: " ++ U32.show(n) ++ " events in " ++ U32.show(t) ++
      " turns; native objects left: " ++ U32.show(left))

def opened(r: Result<&1, &1, U32 & String, W.Win>) -> IO(Unit):
  match r:
    case Fail{(code, message)}:
      IO.die(Unit, code, message)
    case Done{+win}:
      do IO<Unit>:
        IO.print("ankra: native window open (X11); detectable autorepeat: " ++
          Bool.show(W.detectable(win)))
        end : W.Win & Log <- Loop.run(~Log, ~update, ~draw, win, Log{0, 0, C.none(), 0n})
        finished(end)

def main() -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, W.Win> <- W.open(W.Options{"Ankra - native window",
      480, 320, True{}, 160, 120, "Ankra", 336860415})
    opened(r)

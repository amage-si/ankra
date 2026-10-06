import Base
import ../window.bend as W
import ../app.bend as Loop

# Ankra's native X11 window without a renderer: the server paints the
# background, and the program prints every event it receives (resize,
# position, focus, visibility, keys, pointer, close). Between events it
# waits without a deadline, so an idle window costs no CPU. Resize it, move
# it, focus other windows, then close it normally (or press Escape).

type Log is Data:
  Log{events: U32, turns: U32}

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

def counted(+es: List<&2, W.Input>, log: Log) -> IO(Loop.Step<Log>):
  Log{n, t} = log
  +next = {Log{(n + U32.from_nat(List.length(&2, W.Input, es)) : U32), (t + 1 : U32)} : Log}
  do IO<Loop.Step<Log>>:
    print_all(es)
    return Bool.pick(Loop.Step<Log>, escape(es), Loop.Stop{next}, Loop.Keep{next})

def update(win: W.Win, es: List<&2, W.Input>, log: Log) -> IO(Loop.Step<Log>):
  counted(es, log)

def draw(win: W.Win, log: Log) -> IO(Loop.Step<Log>):
  IO.pure(Loop.Step<Log>, Loop.Keep{log})

def finished(end: W.Win & Log) -> IO(Unit):
  (w, log) = end
  Log{n, t} = log
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
        end : W.Win & Log <- Loop.run(~Log, ~update, ~draw, win, Log{0, 0})
        finished(end)

def main() -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, W.Win> <- W.open(W.Options{"Ankra - native window",
      480, 320, True{}, 160, 120, "Ankra", 336860415})
    opened(r)

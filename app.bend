import Base
import ./window.bend as W

# The application loop for Ankra's native window.
#
# An app supplies two templates:
#   update(win, events, state) -> IO(Step<S>)   input and window changes;
#   draw(win, state) -> IO(Step<S>)              paint the current state.
# Each turn draws only when the content is stale, then waits for events:
# without a deadline when nothing is pending (an idle app sleeps in the
# kernel, presents nothing and wakes for nothing), with no wait at all while
# a redraw is still owed, or until the app's own deadline (`Sleep`).
#
# Step decisions, from either template:
#   Keep{s}       nothing new to show;
#   Redraw{s}     the content changed: draw before waiting again (from
#                 `draw`: one more frame is owed, e.g. a rebuilt swapchain);
#   Sleep{s, ms}  nothing new to show, but wake within ms even without
#                 events (timers, polling another source);
#   Stop{s}       end the loop.
# A batch with a close request ends the loop after `update` has seen it.
# `run` hands back the window and the final state, so the app tears down
# its own resources (GPU surfaces first) and then closes the window.

type Step<-S: Type> is Type:
  Keep{state: S}
  Redraw{state: S}
  Sleep{state: S, ms: U32}
  Stop{state: S}

type Turn<-S: Type> is Type:
  Continue{win: W.Win, state: S, dirty: Bool, ms: U32}
  Finish{win: W.Win, state: S}

def paint(~S: Type, ~draw: W.Win -> S -> IO(Step<S>), dirty: Bool, +win: W.Win,
  state: S) -> IO(Step<S>):
  match dirty:
    case True{}:
      draw(win, state)
    case False{}:
      IO.pure(Step<S>, Keep{state})

def next(-S: Type, closing: Bool, +win: W.Win, step: Step<S>, +dirty: Bool) -> Turn<S>:
  match closing step:
    case True{} Keep{s}:
      Finish{win, s}
    case True{} Redraw{s}:
      Finish{win, s}
    case True{} Sleep{s, t}:
      Finish{win, s}
    case _ Stop{s}:
      Finish{win, s}
    case False{} Keep{s}:
      Continue{win, s, dirty, W.forever()}
    case False{} Redraw{s}:
      Continue{win, s, True{}, W.forever()}
    case False{} Sleep{s, t}:
      Continue{win, s, dirty, t}

def decided(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  got: W.Win & List<&2, W.Input>, state: S, +dirty: Bool) -> IO(Turn<S>):
  (+win, +es) = got
  do IO<Turn<S>>:
    step : Step<S> <- update(win, es, state)
    return next(S, W.closing(es), win, step, dirty)

def heard(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  +win: W.Win, state: S, +dirty: Bool, ms: U32) -> IO(Turn<S>):
  do IO<Turn<S>>:
    got : W.Win & List<&2, W.Input> <- W.wait(win, ms)
    decided(~S, ~update, got, state, dirty)

def listen(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  +win: W.Win, painted: Step<S>, +ms: U32) -> IO(Turn<S>):
  match painted:
    case Stop{s}:
      IO.pure(Turn<S>, Finish{win, s})
    case Keep{s}:
      heard(~S, ~update, win, s, False{}, ms)
    case Redraw{s}:
      heard(~S, ~update, win, s, True{}, 0)
    case Sleep{s, t}:
      heard(~S, ~update, win, s, False{}, U32.min(ms, t))

# One turn: paint when stale, wait, update.
def turn(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), +win: W.Win, state: S, dirty: Bool,
  +ms: U32) -> IO(Turn<S>):
  do IO<Turn<S>>:
    painted : Step<S> <- paint(~S, ~draw, dirty, win, state)
    listen(~S, ~update, win, painted, ms)

def loop(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), fuel: Nat, next: Turn<S>) -> IO(W.Win & S):
  match fuel next:
    case _ Finish{win, state}:
      IO.pure(W.Win & S, (win, state))
    case 0n Continue{win, state, d, ms}:
      IO.pure(W.Win & S, (win, state))
    case 1n+p Continue{win, state, dirty, ms}:
      do IO<W.Win & S>:
        t : Turn<S> <- turn(~S, ~update, ~draw, win, state, dirty, ms)
        loop(~S, ~update, ~draw, p, t)

# Runs the loop until a close request, a Stop, or 4294967295 turns (one
# turn per batch of events; the bound exists because Bend requires every
# loop to terminate). The first turn draws.
def run(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), win: W.Win, state: S) -> IO(W.Win & S):
  loop(~S, ~update, ~draw, 4294967295n, Continue{win, state, True{}, W.forever()})

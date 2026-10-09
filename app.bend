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
# a redraw is still owed, until the app's own deadline (`Sleep`), or until
# the next frame while the app animates.
#
# Step decisions, from either template:
#   Keep{s}       nothing new to show;
#   Redraw{s}     the content changed: draw before waiting again (from
#                 `draw`: one more frame is owed, e.g. a rebuilt swapchain);
#   Sleep{s, ms}  nothing new to show, but wake within ms even without
#                 events (timers, polling another source);
#   animate(s)    the content moves with time: draw once per refresh of the
#                 window's monitor (`Sleep{s, frame()}`, see Animation);
#   Stop{s}       end the loop.
# A batch with a close request ends the loop after `update` has seen it.
# `run` hands back the window and the final state, so the app tears down
# its own resources (GPU surfaces first) and then closes the window.
#
# Animation
# ---------
#
# `animate(s)` from `update` starts drawing every frame (at once when the
# loop was not animating); from `draw` it asks for the next frame. The loop
# keeps animating while each `draw` answers `animate`; any other answer
# from `draw` ends it (Keep: back to waiting with no deadline, 0 frames
# and 0 wakeups). From `update`, Keep, Redraw and Sleep leave a running
# animation alone, and a Redraw while animating is drawn with the next
# frame instead of at once (it would land in the same refresh).
#
# Frames follow a grid of the monitor's refresh period (`W.refresh`, from
# RandR; 60 Hz when unknown): the loop sleeps in the event wait until just
# before the next grid time, then draws. `W.frame_time(win)`, in `update`
# and `draw`, is that grid time in ms: consecutive animated frames are one
# period apart, so a motion evaluated at it advances evenly whatever the
# moment the loop woke. A loop that falls a period or more behind skips to
# the latest grid time instead of drawing old ones. Outside animation the
# frame time is the moment the turn began. While animating, `update` also
# runs once per frame, with the events since the last (often none).
#
# Why a timed grid and not back-to-back frames throttled by FIFO: measured
# on XWayland (docs/api.md#animation), back-to-back drawing presented 131
# frames a second on a 120 Hz monitor, some 0.3 ms apart, and blocked the
# thread about 8 ms per frame inside the driver's acquire, where input is
# not read; the grid presents 120 a second, 0 dropped, never blocks in
# acquire and reads input between frames.

type Step<-S: Type> is Type:
  Keep{state: S}
  Redraw{state: S}
  Sleep{state: S, ms: U32}
  Stop{state: S}

# The `Sleep` value that means "animate": draw again at the next frame.
def frame() -> U32:
  4294967294

def animate(-S: Type, state: S) -> Step<S>:
  Sleep{state, frame()}

# Whether a step asks for animation.
def animating(-S: Type, step: Step<S>) -> Bool:
  match step:
    case Sleep{s, t}:
      U32.is_eq(t, frame())
    case _:
      False{}

# The clock
# ---------
#
# The loop's timing state, in microseconds of the monotonic clock (IO.now
# times 1000): whether it animates, the grid time of the next frame, and
# the app's Sleep deadline (0 for none).
type Clock is Data:
  Clock{anim: Bool, due: Nat, timer: Nat}

def idle() -> Clock:
  Clock{False{}, 0n, 0n}

# How long before a frame's grid time the loop asks to wake, and how early
# a wake still draws that frame: the runtime's timers and IO.now count
# whole milliseconds, so a wait can end up to 2 ms before its target as
# measured; drawing then (instead of polling until the target) keeps the
# thread asleep between frames. The frame keeps its grid time either way.
def lead() -> Nat:
  1000n

def slack() -> Nat:
  2000n

# One refresh period in microseconds for a refresh rate in millihertz;
# 60 Hz when unknown, and rates outside 20-1000 Hz are clamped.
def period(+mhz: U32) -> Nat:
  +r = Bool.pick(U32, U32.is_eq(mhz, 0), 60000, U32.clamp(mhz, 20000, 1000000))
  Nat.div(1000000000n, U32.to_nat(r))

# The grid time a frame drawn at `now` shows: `due`, or, when the loop is
# a period or more late, the latest grid time not after `now`.
def slot(+due: Nat, +now: Nat, +p: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(now, Nat.add(due, p)), due,
    Nat.add(due, Nat.mul(Nat.div(Nat.sub(now, due), p), p)))

# The frame time of a turn at `now`: the grid while animating, else now.
def frame_at(c: Clock, +now: Nat, +p: Nat) -> Nat:
  Clock{anim, +due, t} = c
  Bool.pick(Nat, anim, slot(due, now, p), now)

# Whether a turn at `now` draws: content is stale, and while animating
# the next frame's grid time is reached (within lead and slack).
def paints(+dirty: Bool, c: Clock, +now: Nat) -> Bool:
  Clock{anim, +due, t} = c
  dirty && (Bool.not(anim) || Nat.is_ge(Nat.add(Nat.add(now, lead()), slack()), due))

def earliest(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(a, 0n), b, Bool.pick(Nat, Nat.is_eq(b, 0n), a, Nat.min(a, b)))

# The wait before the next turn, in ms: 0 while a redraw is owed outside
# animation; until the lead before the next frame while animating; until
# the app's Sleep deadline; W.forever() when nothing is due.
def wait_ms(+dirty: Bool, c: Clock, +now: Nat) -> U32:
  Clock{+anim, +due, +timer} = c
  +frame = Bool.pick(Nat, anim, Nat.max(Nat.sub(due, lead()), 1n), 0n)
  +at = earliest(frame, timer)
  Bool.pick(U32, dirty && Bool.not(anim), 0,
    Bool.pick(U32, Nat.is_eq(at, 0n), W.forever(),
      U32.from_nat(Nat.min(Nat.div(Nat.sub(at, now), 1000n), 4294967293n))))

# A Sleep of `ms` from `now`, as a deadline (0: none).
def deadline(+ms: U32, +now: Nat) -> Nat:
  Bool.pick(Nat, U32.is_ge(ms, frame()), 0n, Nat.add(now, Nat.mul(U32.to_nat(ms), 1000n)))

# Decisions
# ---------

type Turn<-S: Type> is Type:
  Continue{win: W.Win, state: S, dirty: Bool, clock: Clock}
  Finish{win: W.Win, state: S}

def untimed(c: Clock) -> Clock:
  Clock{anim, due, t} = c
  Clock{anim, due, 0n}

# The clock after `update` answered Sleep{_, t} at `now`: a deadline, or
# (t = frame()) an animation, which starts at `now` unless it runs.
def slept(c: Clock, +t: U32, +now: Nat) -> Clock:
  Clock{+anim, +due, x} = c
  +go = U32.is_eq(t, frame())
  Clock{anim || go, Bool.pick(Nat, anim, due, now), deadline(t, now)}

# The clock after `draw` painted the frame of grid time `shown` and
# answered Sleep{_, t}: animate is due one period of `p` µs later.
def resumed(c: Clock, +t: U32, +shown: Nat, +p: Nat, +now: Nat) -> Clock:
  Clock{a, d, +timer} = c
  Clock{U32.is_eq(t, frame()), Nat.add(shown, p), earliest(timer, deadline(t, now))}

def stopped(c: Clock) -> Clock:
  Clock{a, d, timer} = c
  Clock{False{}, 0n, timer}

# After `update` at `now`. Keep, Redraw and Sleep replace the app's
# deadline and leave the animation alone; animate starts it at `now`.
def updated(-S: Type, closing: Bool, +win: W.Win, step: Step<S>, +dirty: Bool,
  c: Clock, +now: Nat) -> Turn<S>:
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
      Continue{win, s, dirty, untimed(c)}
    case False{} Redraw{s}:
      Continue{win, s, True{}, untimed(c)}
    case False{} Sleep{s, +t}:
      Continue{win, s, dirty || U32.is_eq(t, frame()), slept(c, t, now)}

# After `draw` painted the frame of grid time `shown`, `p` µs per frame,
# at `now`. Only animate keeps the animation: the next frame is due one
# period after this one.
def drew(-S: Type, +win: W.Win, step: Step<S>, c: Clock, +shown: Nat, +p: Nat,
  +now: Nat) -> Turn<S>:
  match step:
    case Stop{s}:
      Finish{win, s}
    case Keep{s}:
      Continue{win, s, False{}, stopped(c)}
    case Redraw{s}:
      Continue{win, s, True{}, stopped(c)}
    case Sleep{s, +t}:
      Continue{win, s, U32.is_eq(t, frame()), resumed(c, t, shown, p, now)}

# The loop
# --------

def stamp(+win: W.Win, +at: Nat) -> W.Win:
  W.with_frame(win, U32.from_nat(Nat.mod(Nat.div(at, 1000n), Nat.mul(65536n, 65536n))))

def decided(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  got: W.Win & List<&2, W.Input>, state: S, +dirty: Bool, +c: Clock) -> IO(Turn<S>):
  (+got_win, +es) = got
  do IO<Turn<S>>:
    +ms : Nat <- IO.now()
    +win : W.Win <- IO.pure(W.Win, stamp(got_win, frame_at(c, Nat.mul(ms, 1000n), period(W.refresh(got_win)))))
    step : Step<S> <- update(win, es, state)
    return updated(S, W.closing(es), win, step, dirty, c, Nat.mul(ms, 1000n))

# Waits as the clock says, then hands the events to `update`.
def listen(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  t: Turn<S>) -> IO(Turn<S>):
  match t:
    case Finish{win, s}:
      IO.pure(Turn<S>, Finish{win, s})
    case Continue{+win, s, +dirty, +c}:
      do IO<Turn<S>>:
        +ms : Nat <- IO.now()
        got : W.Win & List<&2, W.Input> <- W.wait(win, wait_ms(dirty, c, Nat.mul(ms, 1000n)))
        decided(~S, ~update, got, s, dirty, c)

def painted(~S: Type, ~draw: W.Win -> S -> IO(Step<S>), go: Bool, +win: W.Win,
  state: S, +dirty: Bool, +c: Clock, +now: Nat) -> IO(Turn<S>):
  match go:
    case False{}:
      IO.pure(Turn<S>, Continue{win, state, dirty, c})
    case True{}:
      +p = period(W.refresh(win))
      +shown = frame_at(c, now, p)
      do IO<Turn<S>>:
        step : Step<S> <- draw(stamp(win, shown), state)
        +after : Nat <- IO.now()
        return drew(S, stamp(win, shown), step, c, shown, p, Nat.mul(after, 1000n))

# One turn: paint when due, wait, update.
def turn(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), +win: W.Win, state: S, +dirty: Bool,
  +c: Clock) -> IO(Turn<S>):
  do IO<Turn<S>>:
    +ms : Nat <- IO.now()
    t : Turn<S> <- painted(~S, ~draw, paints(dirty, c, Nat.mul(ms, 1000n)), win, state, dirty, c,
      Nat.mul(ms, 1000n))
    listen(~S, ~update, t)

def loop(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), fuel: Nat, next: Turn<S>) -> IO(W.Win & S):
  match fuel next:
    case _ Finish{win, state}:
      IO.pure(W.Win & S, (win, state))
    case 0n Continue{win, state, d, c}:
      IO.pure(W.Win & S, (win, state))
    case 1n+p Continue{win, state, dirty, c}:
      do IO<W.Win & S>:
        t : Turn<S> <- turn(~S, ~update, ~draw, win, state, dirty, c)
        loop(~S, ~update, ~draw, p, t)

# Runs the loop until a close request, a Stop, or 4294967295 turns (one
# turn per batch of events or animated frame; the bound exists because
# Bend requires every loop to terminate). The first turn draws.
def run(~S: Type, ~update: W.Win -> List<&2, W.Input> -> S -> IO(Step<S>),
  ~draw: W.Win -> S -> IO(Step<S>), win: W.Win, state: S) -> IO(W.Win & S):
  loop(~S, ~update, ~draw, 4294967295n, Continue{win, state, True{}, idle()})

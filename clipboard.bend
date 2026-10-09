import Base
import ./native.bend as N
import ./window.bend as W

# The CLIPBOARD selection for Ankra's native window (ICCCM).
#
# The app holds a `Clip`: whether its window owns the clipboard and the
# text it offers. `copy` takes ownership, `serve` answers other clients'
# requests from a batch of events (and notices the loss of ownership), and
# `paste` reads the clipboard: at once when the app owns it, otherwise by
# asking the owner, whose answer arrives later in a batch as
# `Clipboard{Pasted{text}}` or `Clipboard{PasteFailed{code}}`. `answer`
# is the pure policy that decides what a request gets. Transfers are whole
# properties (no INCR), so very large texts are refused.

type Clip is Data:
  Clip{owned: Bool, text: String}

# What a request gets: a refusal, the list of targets (STRING among them
# only when the text is Latin-1), or the text as UTF8_STRING or STRING.
type Answer is Data:
  Refuse{}
  Targets{latin1: Bool}
  Utf8{text: String}
  Latin1{text: String}

def none() -> Clip:
  Clip{False{}, ""}

def owned(c: Clip) -> Bool:
  Clip{o, t} = c
  o

def text(c: Clip) -> String:
  Clip{o, t} = c
  t

# Whether every scalar fits in Latin-1 (STRING).
def latin1(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{c}, rest}:
      U32.is_le(c, 255) && latin1(rest)

def answer.text(+target: U32, +ok: Bool, +t: String) -> Answer:
  match target:
    case 1:
      Targets{ok}
    case 2:
      Utf8{t}
    case 3:
      Bool.pick(Answer, ok, Latin1{t}, Refuse{})
    case 4:
      Bool.pick(Answer, ok, Latin1{t}, Utf8{t})
    case _:
      Refuse{}

# TARGETS lists what we serve; UTF8_STRING is the text; STRING only when
# every scalar is Latin-1; TEXT as STRING when it can be, else UTF-8;
# anything else, or a clipboard we do not own, is refused.
def answer(c: Clip, r: W.Request) -> Answer:
  match c:
    case Clip{False{}, t}:
      Refuse{}
    case Clip{True{}, +t}:
      W.Request{q, p, +target, tm, a} = r
      answer.text(target, latin1(t), t)

# The bridge's reply format: 0 refuse, 1/2 TARGETS with/without STRING,
# 3 UTF8_STRING, 4 STRING.
def format(a: Answer) -> U32 & String:
  match a:
    case Refuse{}:
      (0, "")
    case Targets{True{}}:
      (1, "")
    case Targets{False{}}:
      (2, "")
    case Utf8{t}:
      (3, t)
    case Latin1{t}:
      (4, t)

def reply(+window: U32, r: W.Request, f: U32 & String) -> IO(Unit):
  W.Request{+requestor, +property, target, +time, +atom} = r
  (+code, t) = f
  IO.try(Unit, N.x11_clip_reply(window, requestor, property, atom, code, time, t))

# Takes the clipboard with the window's last event time and offers `text`.
# The answer says whether the server gave the window ownership.
def copy(+win: W.Win, text: String) -> IO(Clip):
  do IO<Clip>:
    +got : U32 <- IO.try(U32, N.x11_clip_own(W.window(win), W.time(win)))
    return Clip{U32.is_ne(got, 0), text}

# The clipboard's text: Some at once when this app owns it; otherwise None
# now, and the owner's answer arrives as a Clipboard event of a later batch.
def paste(+win: W.Win, c: Clip) -> IO(Maybe<&2, String>):
  match c:
    case Clip{True{}, t}:
      IO.pure(Maybe<&2, String>, Some{t})
    case Clip{False{}, t}:
      do IO<Maybe<&2, String>>:
        IO.try(Unit, N.x11_clip_ask(W.window(win), W.time(win)))
        return None{}

def serve.one(+window: U32, +c: Clip, e: W.Input) -> IO(Clip):
  match e:
    case W.Clipboard{W.Asked{+r}}:
      do IO<Clip>:
        reply(window, r, format(answer(c, r)))
        return c
    case W.Clipboard{W.Lost{}}:
      IO.pure(Clip, Clip{False{}, text(c)})
    case _:
      IO.pure(Clip, c)

def serve.go(es: List<&2, W.Input>, +window: U32, c: Clip) -> IO(Clip):
  match es:
    case Nil{}:
      IO.pure(Clip, c)
    case Con{e, rest}:
      do IO<Clip>:
        next : Clip <- serve.one(window, c, e)
        serve.go(rest, window, next)

# Answers every clipboard request in a batch and drops ownership on Lost.
# Call it with each batch while the app may own the clipboard.
def serve(+win: W.Win, c: Clip, es: List<&2, W.Input>) -> IO(Clip):
  serve.go(es, W.window(win), c)

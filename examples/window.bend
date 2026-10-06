import Base
import ../main.bend as A

# Base.Image uses RGB packed in the low 24 bits. Ankra does not rasterize shapes.
def image(+color: U32) -> Image:
  Qua{Pix{color}, Pix{2173749}, Pix{1382173}, Pix{color}}

def clicks(events: List<&2, Event>, color: U32) -> U32:
  match events:
    case Nil{}:
      color
    case Mouse{x, y, 0, True{}} <> rest:
      clicks(rest, U32.xor(color, 16777215))
    case _ <> rest:
      clicks(rest, color)

def changed(same: Bool, +color: U32) -> IO(A.Step<U32>):
  match same:
    case True{}:
      IO.pure(A.Step<U32>, A.Keep{color})
    case False{}:
      IO.pure(A.Step<U32>, A.Redraw{color, image(color)})

def update(batch: A.Batch, color: U32) -> IO(A.Step<U32>):
  A.Batch{closed, count, events} = batch
  +current = color
  +next = clicks(events, current)
  changed(U32.is_eq(next, current), next)

def main() -> IO(Unit):
  # Close with the window manager, or let the 3,600-frame budget expire.
  A.run(~U32, ~update, "Ankra - click to change color", 480, 320,
    3600n, 4248719, image(4248719))

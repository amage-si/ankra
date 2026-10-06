import Base

def finish(shown: Window & Image & List<Event>) -> IO(Unit):
  (window, image, events) = shown
  do IO<Unit>:
    IO.sleep(1200)
    Window.close(window)

def main() -> IO(Unit):
  do IO<Unit>:
    window : Window <- IO.try(Window, Window.open("AMAGE Eco - backend probe", 256, 192))
    shown : Window & Image & List<Event> <- Window.frame(window,
      Qua{Pix{16711680}, Pix{65280}, Pix{255}, Pix{16777215}})
    finish(shown)

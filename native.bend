import Base

# The native X11 bridge: one Bend effect per thin Xlib call, implemented in
# native/ankra.c (native builds) and native/ankra.js (JS lane, always
# ENOTSUP). Objects are U32 slot ids; 0 means "none". Word layouts are
# documented beside each effect in native/ankra.c and in docs/bridge.md.
# Prefer the typed API in window.bend; these are the raw calls it composes.

def x11_connect() -> IO(Result<&1, &1, U32 & String, U32>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_create(display: U32, x: U32, y: U32, width: U32, height: U32,
  events: U32, background: U32) -> IO(Result<&1, &1, U32 & String, U32>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_protocols(window: U32) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_title(window: U32, title: String) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_class(window: U32, name: String, class: String) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_size_hints(window: U32, min_width: U32, min_height: U32,
  max_width: U32, max_height: U32) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_autorepeat(display: U32, detectable: Bool) ->
  IO(Result<&1, &1, U32 & String, U32>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_map(window: U32) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_position(window: U32) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_native(window: U32, display: U32) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_wait(display: U32, ms: U32) ->
  IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_destroy(slot: U32) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./native/ankra.c"
  import "./native/ankra.js"

def x11_live() -> IO(Result<&1, &1, U32 & String, U32>):
  import "./native/ankra.c"
  import "./native/ankra.js"

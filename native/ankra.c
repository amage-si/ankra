// Ankra native bridge (X11)
// =========================
//
// The only hand-written native code in Ankra. Bend splices this file into
// the generated C program after its runtime (see `bend guide effects`), so
// the runtime helpers (Term, Env, io_done, io_fail, io_node, io_wait_on,
// ...) are in scope. It is not a toolkit: each effect below is one Xlib
// call, or a field-by-field translation of Xlib structs into Bend words.
// Every decision -- which events to select, size hints, which focus
// changes count, how keys map to codes, when to ask for the window's
// position, when to wait and for how long -- is made in Bend (window.bend).
//
// Objects cross into Bend as U32 slot ids (0 means none). The bridge checks
// that a slot is alive and of the expected kind, so a stale id fails
// instead of crashing. Bend owns lifetimes and destruction order (windows
// before their display).
//
// Including <X11/Xlib.h> makes `bend` link libX11, the same rule the
// official Window effect relies on. XKB functions live in libX11 as well.
//
// Failures answer `Fail{(code, text)}`: 22 (EINVAL) for a bad slot or
// argument, 24 (EMFILE) when the slot table is full, 95 (ENOTSUP) when no
// X display is reachable.

#include <poll.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/XKBlib.h>

// Slots
// -----

enum { AK_FREE, AK_DISPLAY, AK_WINDOW };

typedef struct {
  u32      kind;
  u32      display;  // a window's display slot
  Display* dpy;
  Window   xid;      // a window's X id
  Atom     close;    // WM_DELETE_WINDOW once x11_protocols ran
} AkSlot;

#define AK_SLOTS 256
static AkSlot ak_slot[AK_SLOTS];
static u32    ak_live;

static u32 ak_new(AkSlot s) {
  for (u32 i = 1; i < AK_SLOTS; i += 1) {
    if (ak_slot[i].kind == AK_FREE) {
      ak_slot[i] = s;
      ak_live += 1;
      return i;
    }
  }
  return 0;
}

static AkSlot* ak_get(u32 id, u32 kind) {
  if (id == 0 || id >= AK_SLOTS || ak_slot[id].kind != kind) {
    return NULL;
  }
  return &ak_slot[id];
}

// The slot of a window X id on a display, or 0.
static u32 ak_window_of(Display* dpy, Window xid) {
  for (u32 i = 1; i < AK_SLOTS; i += 1) {
    if (ak_slot[i].kind == AK_WINDOW && ak_slot[i].dpy == dpy
      && ak_slot[i].xid == xid) {
      return i;
    }
  }
  return 0;
}

// Terms
// -----

#define AK_BAD(e, what) io_fail(e, 22, "Ankra: invalid " what)
#define AK_UNIT(e) io_done(e, term_pak(CID(Unit), 0))

static Term ak_list(Env e, const u32* w, u32 n) {
  Term xs = term_pak(CID(Nil), 0);
  for (u32 i = n; i > 0; i -= 1) {
    xs = io_node(e, CID(Con), (Term)w[i - 1], xs);
  }
  return xs;
}

static Term ak_slot_done(Env e, AkSlot s) {
  u32 id = ak_new(s);
  return id == 0 ? io_fail(e, 24, "Ankra: slot table full")
    : io_done(e, (Term)id);
}

// Connection
// ----------

#ifdef CID(x11_connect)

// XOpenDisplay($DISPLAY). Answers a display slot.
Term ak_x11_connect_run(Env e, Term* f, IoWork* w) {
  Display* dpy = XOpenDisplay(NULL);
  if (dpy == NULL) {
    return io_fail(e, 95, "Ankra: no X11 display (DISPLAY unset?)");
  }
  u32 id = ak_new((AkSlot){ AK_DISPLAY, 0, dpy, 0, 0 });
  if (id == 0) {
    XCloseDisplay(dpy);
    return io_fail(e, 24, "Ankra: slot table full");
  }
  return io_done(e, (Term)id);
}

static void __attribute__((constructor)) ak_x11_connect_use(void) {
  io_eff(CID(x11_connect), ak_x11_connect_run, 0);
}

#endif

#ifdef CID(x11_screen)

// The default screen's fields (Xlib macros; no request):
// [screen, width, height, widthMM, heightMM, depth].
Term ak_x11_screen_run(Env e, Term* f, IoWork* w) {
  AkSlot* d = ak_get((u32)f[0], AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  int s = DefaultScreen(d->dpy);
  u32 out[6] = { (u32)s, (u32)DisplayWidth(d->dpy, s),
    (u32)DisplayHeight(d->dpy, s), (u32)DisplayWidthMM(d->dpy, s),
    (u32)DisplayHeightMM(d->dpy, s), (u32)DefaultDepth(d->dpy, s) };
  return io_done(e, ak_list(e, out, 6));
}

static void __attribute__((constructor)) ak_x11_screen_use(void) {
  io_eff(CID(x11_screen), ak_x11_screen_run, 0);
}

#endif

// Windows
// -------

#ifdef CID(x11_create)

// XCreateWindow on the default screen's root: x, y, width, height, the
// event mask and the background chosen by Bend. Background 0xFFFFFFFF is
// None: the server never clears what a GPU swapchain presented (also on
// resize); any other value is a 0xRRGGBB pixel of the default TrueColor
// visual, painted by the server.
Term ak_x11_create_run(Env e, Term* f, IoWork* w) {
  AkSlot* d = ak_get((u32)f[0], AK_DISPLAY);
  u32 width = (u32)f[3];
  u32 height = (u32)f[4];
  u32 background = (u32)f[6];
  if (d == NULL || width < 1 || height < 1 || width > 16384
    || height > 16384) {
    return AK_BAD(e, "display or window size");
  }
  XSetWindowAttributes a = { 0 };
  a.background_pixmap = None;
  a.background_pixel = background;
  a.event_mask = (long)(u32)f[5];
  Window xid = XCreateWindow(d->dpy, DefaultRootWindow(d->dpy),
    (int)(int32_t)(u32)f[1], (int)(int32_t)(u32)f[2], width, height, 0,
    CopyFromParent, InputOutput, CopyFromParent, CWEventMask
    | (background == 0xFFFFFFFFu ? CWBackPixmap : CWBackPixel), &a);
  u32 id = ak_new((AkSlot){ AK_WINDOW, (u32)f[0], d->dpy, xid, 0 });
  if (id == 0) {
    XDestroyWindow(d->dpy, xid);
    return io_fail(e, 24, "Ankra: slot table full");
  }
  return io_done(e, (Term)id);
}

static void __attribute__((constructor)) ak_x11_create_use(void) {
  io_eff(CID(x11_create), ak_x11_create_run, 0);
}

#endif

#ifdef CID(x11_protocols)

// Registers WM_DELETE_WINDOW (XInternAtom + XSetWMProtocols), so a close
// request arrives as an event instead of killing the connection.
Term ak_x11_protocols_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL) {
    return AK_BAD(e, "window");
  }
  s->close = XInternAtom(s->dpy, "WM_DELETE_WINDOW", False);
  XSetWMProtocols(s->dpy, s->xid, &s->close, 1);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_protocols_use(void) {
  io_eff(CID(x11_protocols), ak_x11_protocols_run, 0);
}

#endif

#ifdef CID(x11_title)

// The title as WM_NAME (XStoreName) and as UTF-8 _NET_WM_NAME.
Term ak_x11_title_run(Env e, Term* f, IoWork* w) {
  u64 n = 0;
  char* title = io_cstr(e, f[1], &n);
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL || io_nul(title, n)) {
    free(title);
    return AK_BAD(e, "window or title");
  }
  XStoreName(s->dpy, s->xid, title);
  XChangeProperty(s->dpy, s->xid, XInternAtom(s->dpy, "_NET_WM_NAME", False),
    XInternAtom(s->dpy, "UTF8_STRING", False), 8, PropModeReplace,
    (unsigned char*)title, (int)n);
  XFlush(s->dpy);
  free(title);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_title_use(void) {
  io_eff(CID(x11_title), ak_x11_title_run, 0);
}

#endif

#ifdef CID(x11_class)

// WM_CLASS (XSetClassHint): instance name and class name.
Term ak_x11_class_run(Env e, Term* f, IoWork* w) {
  u64 n1 = 0, n2 = 0;
  char* name = io_cstr(e, f[1], &n1);
  char* cls = io_cstr(e, f[2], &n2);
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  Term r;
  if (s == NULL || io_nul(name, n1) || io_nul(cls, n2)) {
    r = AK_BAD(e, "window or class");
  } else {
    XClassHint h = { name, cls };
    XSetClassHint(s->dpy, s->xid, &h);
    r = AK_UNIT(e);
  }
  free(name);
  free(cls);
  return r;
}

static void __attribute__((constructor)) ak_x11_class_use(void) {
  io_eff(CID(x11_class), ak_x11_class_run, 0);
}

#endif

#ifdef CID(x11_size_hints)

// WM_NORMAL_HINTS (XSetWMNormalHints): minimum and maximum size; a pair of
// zeros leaves that bound unset. Equal bounds ask for a fixed size.
Term ak_x11_size_hints_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL) {
    return AK_BAD(e, "window");
  }
  XSizeHints h = { 0 };
  if ((u32)f[1] != 0 || (u32)f[2] != 0) {
    h.flags |= PMinSize;
    h.min_width = (int)(u32)f[1];
    h.min_height = (int)(u32)f[2];
  }
  if ((u32)f[3] != 0 || (u32)f[4] != 0) {
    h.flags |= PMaxSize;
    h.max_width = (int)(u32)f[3];
    h.max_height = (int)(u32)f[4];
  }
  XSetWMNormalHints(s->dpy, s->xid, &h);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_size_hints_use(void) {
  io_eff(CID(x11_size_hints), ak_x11_size_hints_run, 0);
}

#endif

#ifdef CID(x11_autorepeat)

// XkbSetDetectableAutoRepeat: while a key is held the server sends repeated
// presses without the synthetic releases between them. Answers 1 when the
// server supports it, 0 otherwise.
Term ak_x11_autorepeat_run(Env e, Term* f, IoWork* w) {
  AkSlot* d = ak_get((u32)f[0], AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  Bool supported = False;
  XkbSetDetectableAutoRepeat(d->dpy, term_aux(f[1]) == CID(True),
    &supported);
  return io_done(e, (Term)(u32)(supported ? 1 : 0));
}

static void __attribute__((constructor)) ak_x11_autorepeat_use(void) {
  io_eff(CID(x11_autorepeat), ak_x11_autorepeat_run, 0);
}

#endif

#ifdef CID(x11_map)

// XMapWindow, then XFlush so the request leaves now.
Term ak_x11_map_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL) {
    return AK_BAD(e, "window");
  }
  XMapWindow(s->dpy, s->xid);
  XFlush(s->dpy);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_map_use(void) {
  io_eff(CID(x11_map), ak_x11_map_run, 0);
}

#endif

#ifdef CID(x11_position)

// XTranslateCoordinates of the window's origin to its root window:
// [x, y], signed 32-bit values in U32 bits.
Term ak_x11_position_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL) {
    return AK_BAD(e, "window");
  }
  int x = 0, y = 0;
  Window child;
  XTranslateCoordinates(s->dpy, s->xid, DefaultRootWindow(s->dpy), 0, 0, &x,
    &y, &child);
  u32 out[2] = { (u32)(int32_t)x, (u32)(int32_t)y };
  return io_done(e, ak_list(e, out, 2));
}

static void __attribute__((constructor)) ak_x11_position_use(void) {
  io_eff(CID(x11_position), ak_x11_position_run, 0);
}

#endif

#ifdef CID(x11_native)

// The native handle a GPU layer needs for a presentation surface:
// [1 (Xlib), Display* high word, Display* low word, Window id, screen].
// The display stays owned by Ankra and must outlive every surface made
// from it.
Term ak_x11_native_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  if (s == NULL) {
    return AK_BAD(e, "window");
  }
  u64 p = (u64)(uintptr_t)s->dpy;
  u32 out[5] = { 1, (u32)(p >> 32), (u32)p, (u32)s->xid,
    (u32)DefaultScreen(s->dpy) };
  return io_done(e, ak_list(e, out, 5));
}

static void __attribute__((constructor)) ak_x11_native_use(void) {
  io_eff(CID(x11_native), ak_x11_native_run, 0);
}

#endif

// Events
// ------

#ifdef CID(x11_wait)

// Each event is eight words: kind, window slot, then a b c d e f.
//  1 close      (WM_DELETE_WINDOW)
//  2 configure  width height x y synthetic
//  3 expose     x y width height count
//  4 key        keysym keycode down state chars time
//  5 button     x y button down state time
//  6 motion     x y state time
//  7 focus      in mode detail
//  8 crossing   enter x y mode detail state
//  9 map        mapped
// Signed values travel as 32-bit two's complement. `keysym` and `chars`
// come from XLookupString with only Shift and Lock applied (Ctrl and Alt do
// not change the symbol); `chars` is count << 8 | first byte; `state` is
// the event's full modifier mask. MappingNotify refreshes Xlib's keymap
// cache (XRefreshKeyboardMapping), which XLookupString needs.
#define AK_EVENT_WORDS 8

static u32 ak_event(XEvent* ev, u32* k) {
  if (ev->type == ClientMessage) {
    u32 win = ak_window_of(ev->xany.display, ev->xclient.window);
    AkSlot* s = win != 0 ? &ak_slot[win] : NULL;
    if (s == NULL || s->close == 0 || ev->xclient.format != 32
      || (Atom)ev->xclient.data.l[0] != s->close) {
      return 0;
    }
    k[0] = 1;
  } else if (ev->type == ConfigureNotify) {
    k[0] = 2; k[2] = (u32)ev->xconfigure.width;
    k[3] = (u32)ev->xconfigure.height; k[4] = (u32)(int32_t)ev->xconfigure.x;
    k[5] = (u32)(int32_t)ev->xconfigure.y; k[6] = ev->xconfigure.send_event;
  } else if (ev->type == Expose) {
    k[0] = 3; k[2] = (u32)ev->xexpose.x; k[3] = (u32)ev->xexpose.y;
    k[4] = (u32)ev->xexpose.width; k[5] = (u32)ev->xexpose.height;
    k[6] = (u32)ev->xexpose.count;
  } else if (ev->type == KeyPress || ev->type == KeyRelease) {
    XKeyEvent key = ev->xkey;
    char c[8];
    KeySym sym = 0;
    key.state &= ShiftMask | LockMask;
    int n = XLookupString(&key, c, sizeof c, &sym, NULL);
    k[0] = 4; k[2] = (u32)sym; k[3] = ev->xkey.keycode;
    k[4] = ev->type == KeyPress; k[5] = ev->xkey.state;
    k[6] = ((u32)(n < 0 ? 0 : n) << 8) | (n > 0 ? (u8)c[0] : 0);
    k[7] = (u32)ev->xkey.time;
  } else if (ev->type == ButtonPress || ev->type == ButtonRelease) {
    k[0] = 5; k[2] = (u32)(int32_t)ev->xbutton.x;
    k[3] = (u32)(int32_t)ev->xbutton.y; k[4] = ev->xbutton.button;
    k[5] = ev->type == ButtonPress; k[6] = ev->xbutton.state;
    k[7] = (u32)ev->xbutton.time;
  } else if (ev->type == MotionNotify) {
    k[0] = 6; k[2] = (u32)(int32_t)ev->xmotion.x;
    k[3] = (u32)(int32_t)ev->xmotion.y; k[4] = ev->xmotion.state;
    k[5] = (u32)ev->xmotion.time;
  } else if (ev->type == FocusIn || ev->type == FocusOut) {
    k[0] = 7; k[2] = ev->type == FocusIn; k[3] = (u32)ev->xfocus.mode;
    k[4] = (u32)ev->xfocus.detail;
  } else if (ev->type == EnterNotify || ev->type == LeaveNotify) {
    k[0] = 8; k[2] = ev->type == EnterNotify;
    k[3] = (u32)(int32_t)ev->xcrossing.x; k[4] = (u32)(int32_t)ev->xcrossing.y;
    k[5] = (u32)ev->xcrossing.mode; k[6] = (u32)ev->xcrossing.detail;
    k[7] = ev->xcrossing.state;
  } else if (ev->type == MapNotify || ev->type == UnmapNotify) {
    k[0] = 9; k[2] = ev->type == MapNotify;
  } else if (ev->type == MappingNotify) {
    XRefreshKeyboardMapping(&ev->xmapping);
    return 0;
  } else {
    return 0;
  }
  k[1] = ak_window_of(ev->xany.display, ev->xany.window);
  return k[1] != 0;
}

// Drains the events already received (XPending reads what the socket holds
// without blocking) into one word list.
static Term ak_events(Env e, Display* dpy) {
  u32 cap = 0, n = 0;
  u32* evs = NULL;
  while (XPending(dpy) > 0) {
    XEvent ev;
    XNextEvent(dpy, &ev);
    u32 k[AK_EVENT_WORDS] = { 0 };
    if (!ak_event(&ev, k)) {
      continue;
    }
    if (n + AK_EVENT_WORDS > cap) {
      cap = cap == 0 ? 256 : cap * 2;
      evs = io_mem(realloc(evs, cap * sizeof(u32)));
    }
    memcpy(evs + n, k, sizeof k);
    n += AK_EVENT_WORDS;
  }
  Term list = ak_list(e, evs, n);
  free(evs);
  return list;
}

static Term ak_x11_wait_more(Env e, IoWork* w) {
  AkSlot* d = ak_get((u32)w->hand, AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  u64 due = w->size;
  if (XPending(d->dpy) == 0 && (due == 0 || io_tick() < due)) {
    // Woken by bytes that held no event (a reply, a partial read): park
    // again until an event arrives or the deadline passes.
    return io_wait_on(w, ConnectionNumber(d->dpy), POLLIN, due,
      ak_x11_wait_more);
  }
  return io_done(e, ak_events(e, d->dpy));
}

// Waits up to `ms` for events on a display: 0 polls, 4294967295 waits
// without a deadline. The wait parks on the X connection's socket in the
// runtime's event loop: no thread spins and no timer fires while idle.
Term ak_x11_wait_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  u32 ms = (u32)f[1];
  AkSlot* d = ak_get(id, AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  if (ms == 0 || XPending(d->dpy) > 0) {
    return io_done(e, ak_events(e, d->dpy));
  }
  w->hand = (intptr_t)id;
  w->size = ms == 0xFFFFFFFFu ? 0 : io_tick() + (u64)ms * 1000000ull;
  return io_wait_on(w, ConnectionNumber(d->dpy), POLLIN, w->size,
    ak_x11_wait_more);
}

static void __attribute__((constructor)) ak_x11_wait_use(void) {
  io_eff(CID(x11_wait), ak_x11_wait_run, 0);
}

#endif

// Lifetimes
// ---------

#ifdef CID(x11_destroy)

// XDestroyWindow for a window slot (then XFlush), XCloseDisplay for a
// display slot. Bend destroys windows before their display.
Term ak_x11_destroy_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  if (id == 0 || id >= AK_SLOTS || ak_slot[id].kind == AK_FREE) {
    return AK_BAD(e, "slot");
  }
  AkSlot* s = &ak_slot[id];
  if (s->kind == AK_WINDOW) {
    XDestroyWindow(s->dpy, s->xid);
    XFlush(s->dpy);
  } else {
    XCloseDisplay(s->dpy);
  }
  *s = (AkSlot){ 0 };
  ak_live -= 1;
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_destroy_use(void) {
  io_eff(CID(x11_destroy), ak_x11_destroy_run, 0);
}

#endif

#ifdef CID(x11_live)

// How many slots are alive (0 after a complete teardown).
Term ak_x11_live_run(Env e, Term* f, IoWork* w) {
  return io_done(e, (Term)ak_live);
}

static void __attribute__((constructor)) ak_x11_live_use(void) {
  io_eff(CID(x11_live), ak_x11_live_run, 0);
}

#endif

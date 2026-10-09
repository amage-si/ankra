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

#include <locale.h>
#include <poll.h>
#include <sys/epoll.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/XKBlib.h>

// Slots
// -----

enum { AK_FREE, AK_DISPLAY, AK_WINDOW };

// Atoms a display interns once, on first use (ak_atoms).
enum { AK_CLIPBOARD, AK_UTF8, AK_TARGETS, AK_STRING, AK_TEXT, AK_PASTE,
  AK_INCR, AK_ATOMS };

typedef struct {
  u32      kind;
  u32      display;  // a window's display slot
  Display* dpy;
  Window   xid;      // a window's X id
  Atom     close;    // WM_DELETE_WINDOW once x11_protocols ran
  XIM      im;       // a display's input method once x11_input ran
  XIC      ic;       // a window's input context once x11_input ran
  Atom     atom[AK_ATOMS];  // a display's atoms, None until ak_atoms
  int      set;      // a display's epoll set + 1 once x11_watch ran, else 0
  int      watched;  // the descriptor its waits also watch + 1, else 0
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

// The atoms of a display slot, interned with one request the first time.
static Atom* ak_atoms(AkSlot* d) {
  if (d->atom[0] == None) {
    static char* names[AK_ATOMS] = { "CLIPBOARD", "UTF8_STRING", "TARGETS",
      "STRING", "TEXT", "ANKRA_PASTE", "INCR" };
    XInternAtoms(d->dpy, names, AK_ATOMS, False, d->atom);
  }
  return d->atom;
}

// The display slot of a live window slot (Bend destroys windows first).
static AkSlot* ak_display_of(AkSlot* s) {
  return s == NULL ? NULL : ak_get(s->display, AK_DISPLAY);
}

// Strict UTF-8 to scalars: no overlong forms, surrogates or values past
// U+10FFFF. Answers the count, or -1 at the first invalid byte. `out` may
// be NULL to count only.
static int64_t ak_utf8(const u8* p, u64 n, u32* out) {
  int64_t m = 0;
  for (u64 i = 0; i < n; m += 1) {
    u32 b = p[i], c, k;
    if (b < 0x80) { c = b; k = 0; }
    else if (b >= 0xC2 && b <= 0xDF) { c = b & 0x1F; k = 1; }
    else if (b >= 0xE0 && b <= 0xEF) { c = b & 0x0F; k = 2; }
    else if (b >= 0xF0 && b <= 0xF4) { c = b & 0x07; k = 3; }
    else { return -1; }
    if (i + k >= n) { return -1; }
    for (u32 j = 1; j <= k; j += 1) {
      if ((p[i + j] & 0xC0) != 0x80) { return -1; }
      c = (c << 6) | (p[i + j] & 0x3F);
    }
    if ((k == 2 && (c < 0x800 || (c >= 0xD800 && c <= 0xDFFF)))
      || (k == 3 && (c < 0x10000 || c > 0x10FFFF))) {
      return -1;
    }
    if (out != NULL) { out[m] = c; }
    i += k + 1;
  }
  return m;
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

// The native handle a GPU layer needs for a presentation surface, on the
// display connection Bend chose for presenting (Ankra opens a dedicated
// one, so a driver reading it never consumes the readiness of the event
// connection): [1 (Xlib), Display* high word, Display* low word, window
// id, screen]. The display stays owned by Ankra and must outlive every
// surface made from it.
Term ak_x11_native_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_get((u32)f[1], AK_DISPLAY);
  if (s == NULL || d == NULL) {
    return AK_BAD(e, "window or display");
  }
  u64 p = (u64)(uintptr_t)d->dpy;
  u32 out[5] = { 1, (u32)(p >> 32), (u32)p, (u32)s->xid,
    (u32)DefaultScreen(d->dpy) };
  return io_done(e, ak_list(e, out, 5));
}

static void __attribute__((constructor)) ak_x11_native_use(void) {
  io_eff(CID(x11_native), ak_x11_native_run, 0);
}

#endif

// Events
// ------

#ifdef CID(x11_wait)

// Each record is eight words: kind, window slot, then a b c d e f. One X
// event gives one record, none, or (a key press with text) several.
//  1 close      (WM_DELETE_WINDOW)
//  2 configure  width height x y synthetic
//  3 expose     x y width height count
//  4 key        keysym keycode down state chars time
//  5 button     x y button down state time
//  6 motion     x y state time
//  7 focus      in mode detail
//  8 crossing   enter x y mode detail state
//  9 map        mapped
// 10 text       n|more<<8|keysym<<16 c1 c2 c3 c4 state
// 11 request    requestor property target_code time clipboard target
// 12 clear      clipboard time
// 13 notify     ok clipboard
// 14 watched    (window slot 0) the descriptor of x11_watch is readable
// Signed values travel as 32-bit two's complement. `keysym` and `chars`
// come from XLookupString with only Shift and Lock applied (Ctrl and Alt do
// not change the symbol); `chars` is count << 8 | first byte; `state` is
// the event's full modifier mask. MappingNotify refreshes Xlib's keymap
// cache (XRefreshKeyboardMapping), which XLookupString needs.
//
// Text follows its key record. With an input context (x11_input), events
// pass through XFilterEvent first (the input method takes dead keys and
// compose sequences, then puts back a press with keycode 0 that carries
// the result), and Xutf8LookupString's text crosses as scalars, four per
// record, `more` set on every record but the last. Without one, the record
// holds the keysym of XLookupString on the full state (keysym bit set) and
// Bend maps it. target_code: 1 TARGETS, 2 UTF8_STRING, 3 STRING, 4 TEXT,
// 0 anything else (the atom itself is the last word).
#define AK_EVENT_WORDS 8

typedef struct {
  u32* w;
  u32  n;
  u32  cap;
} AkOut;

static void ak_push(AkOut* o, const u32* k) {
  if (o->n + AK_EVENT_WORDS > o->cap) {
    o->cap = o->cap == 0 ? 256 : o->cap * 2;
    o->w = io_mem(realloc(o->w, o->cap * sizeof(u32)));
  }
  memcpy(o->w + o->n, k, AK_EVENT_WORDS * sizeof(u32));
  o->n += AK_EVENT_WORDS;
}

static void ak_text(AkSlot* s, u32 slot, XKeyEvent* key, AkOut* o) {
  u32 state = key->state;
  KeySym sym = NoSymbol;
  if (s->ic == NULL) {
    char c[8];
    XLookupString(key, c, sizeof c, &sym, NULL);
    if (sym != NoSymbol) {
      u32 k[AK_EVENT_WORDS] = { 10, slot, 1 | 1u << 16, (u32)sym, 0, 0, 0,
        state };
      ak_push(o, k);
    }
    return;
  }
  char buf[64];
  char* p = buf;
  Status st = XLookupNone;
  int n = Xutf8LookupString(s->ic, key, p, sizeof buf, &sym, &st);
  if (st == XBufferOverflow) {
    p = io_mem(malloc((size_t)n));
    n = Xutf8LookupString(s->ic, key, p, n, &sym, &st);
  }
  if ((st == XLookupChars || st == XLookupBoth) && n > 0) {
    u32* cs = io_mem(malloc((size_t)n * sizeof(u32)));
    int64_t m = ak_utf8((const u8*)p, (u64)n, cs);
    for (int64_t i = 0; i < m; i += 4) {
      u32 c = (u32)(m - i < 4 ? m - i : 4);
      u32 k[AK_EVENT_WORDS] = { 10, slot, c | (u32)(i + 4 < m) << 8, cs[i],
        c > 1 ? cs[i + 1] : 0, c > 2 ? cs[i + 2] : 0, c > 3 ? cs[i + 3] : 0,
        state };
      ak_push(o, k);
    }
    free(cs);
  }
  if (p != buf) {
    free(p);
  }
}

static u32 ak_target(Atom* a, Atom t) {
  return t == a[AK_TARGETS] ? 1 : t == a[AK_UTF8] ? 2 : t == a[AK_STRING] ? 3
    : t == a[AK_TEXT] ? 4 : 0;
}

static void ak_event(AkSlot* d, XEvent* ev, AkOut* o) {
  u32 k[AK_EVENT_WORDS] = { 0 };
  if (ev->type == ClientMessage) {
    u32 win = ak_window_of(ev->xany.display, ev->xclient.window);
    AkSlot* s = win != 0 ? &ak_slot[win] : NULL;
    if (s == NULL || s->close == 0 || ev->xclient.format != 32
      || (Atom)ev->xclient.data.l[0] != s->close) {
      return;
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
  } else if (ev->type == SelectionRequest) {
    XSelectionRequestEvent* r = &ev->xselectionrequest;
    Atom* a = ak_atoms(d);
    k[0] = 11; k[2] = (u32)r->requestor; k[3] = (u32)r->property;
    k[4] = ak_target(a, r->target); k[5] = (u32)r->time;
    k[6] = r->selection == a[AK_CLIPBOARD]; k[7] = (u32)r->target;
  } else if (ev->type == SelectionClear) {
    k[0] = 12; k[2] = ev->xselectionclear.selection == ak_atoms(d)[AK_CLIPBOARD];
    k[3] = (u32)ev->xselectionclear.time;
  } else if (ev->type == SelectionNotify) {
    k[0] = 13; k[2] = ev->xselection.property != None;
    k[3] = ev->xselection.selection == ak_atoms(d)[AK_CLIPBOARD];
  } else if (ev->type == MappingNotify) {
    XRefreshKeyboardMapping(&ev->xmapping);
    return;
  } else {
    return;
  }
  k[1] = ak_window_of(ev->xany.display, ev->xany.window);
  if (k[1] == 0) {
    return;
  }
  ak_push(o, k);
  if (ev->type == KeyPress) {
    ak_text(&ak_slot[k[1]], k[1], &ev->xkey, o);
  }
}

// Drains the events already received (XPending reads what the socket holds
// without blocking) into one word list. With an input method, an event it
// filters (part of a dead-key or compose sequence) gives no record. When
// the watched descriptor (x11_watch) is readable, a last record says so:
// kind 14, window slot 0.
static Term ak_events(Env e, AkSlot* d, int watched) {
  AkOut o = { 0 };
  while (XPending(d->dpy) > 0) {
    XEvent ev;
    XNextEvent(d->dpy, &ev);
    if (d->im != NULL && XFilterEvent(&ev, None)) {
      continue;
    }
    ak_event(d, &ev, &o);
  }
  if (watched) {
    u32 k[AK_EVENT_WORDS] = { 14 };
    ak_push(&o, k);
  }
  Term list = ak_list(e, o.w, o.n);
  free(o.w);
  return list;
}

// What a display's waits park on: its epoll set (the connection and the
// watched descriptor) once x11_watch ran, else the connection.
static int ak_wait_fd(AkSlot* d) {
  return d->set != 0 ? d->set - 1 : ConnectionNumber(d->dpy);
}

// Whether the watched descriptor is readable (or hung up), asked of the
// epoll set: a descriptor closed since x11_watch has left the set and
// never counts, even if its number is reused.
static int ak_watched(AkSlot* d) {
  if (d->set == 0 || d->watched == 0) {
    return 0;
  }
  struct epoll_event ev[2];
  int n = epoll_wait(d->set - 1, ev, 2, 0);
  for (int i = 0; i < n; i += 1) {
    if (ev[i].data.fd == d->watched - 1) {
      return 1;
    }
  }
  return 0;
}

static Term ak_x11_wait_more(Env e, IoWork* w) {
  AkSlot* d = ak_get((u32)w->hand, AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  u64 due = w->size;
  int watched = ak_watched(d);
  if (XPending(d->dpy) == 0 && !watched && (due == 0 || io_tick() < due)) {
    // Woken by bytes that held no event (a reply, a partial read): park
    // again until an event arrives or the deadline passes.
    return io_wait_on(w, ak_wait_fd(d), POLLIN, due, ak_x11_wait_more);
  }
  return io_done(e, ak_events(e, d, watched));
}

// Waits up to `ms` for events on a display: 0 polls, 4294967295 waits
// without a deadline. The wait parks on the X connection's socket (or the
// epoll set of x11_watch) in the runtime's event loop: no thread spins and
// no timer fires while idle.
Term ak_x11_wait_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  u32 ms = (u32)f[1];
  AkSlot* d = ak_get(id, AK_DISPLAY);
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  if (ms == 0 || XPending(d->dpy) > 0) {
    return io_done(e, ak_events(e, d, ak_watched(d)));
  }
  w->hand = (intptr_t)id;
  w->size = ms == 0xFFFFFFFFu ? 0 : io_tick() + (u64)ms * 1000000ull;
  return io_wait_on(w, ak_wait_fd(d), POLLIN, w->size, ak_x11_wait_more);
}

static void __attribute__((constructor)) ak_x11_wait_use(void) {
  io_eff(CID(x11_wait), ak_x11_wait_run, 0);
}

#endif

#ifdef CID(x11_watch)

// Makes a display's waits also end when `fd` is readable (a second event
// source, such as a bus socket); 0xFFFFFFFF stops watching. The first call
// makes an epoll set (epoll_create1 + epoll_ctl) holding the X connection;
// each call replaces the watched descriptor. A descriptor closed later
// leaves the set by itself.
Term ak_x11_watch_run(Env e, Term* f, IoWork* w) {
  AkSlot* d = ak_get((u32)f[0], AK_DISPLAY);
  u32 fd = (u32)f[1];
  if (d == NULL) {
    return AK_BAD(e, "display");
  }
  if (d->set == 0) {
    int set = epoll_create1(EPOLL_CLOEXEC);
    struct epoll_event ev = { .events = EPOLLIN };
    ev.data.fd = ConnectionNumber(d->dpy);
    if (set < 0 || epoll_ctl(set, EPOLL_CTL_ADD, ev.data.fd, &ev) != 0) {
      int code = errno;
      if (set >= 0) {
        close(set);
      }
      return io_fail(e, (u32)code, "Ankra: cannot make an epoll set");
    }
    d->set = set + 1;
  }
  if (d->watched != 0) {
    // Fails harmlessly when the descriptor was closed (already gone).
    epoll_ctl(d->set - 1, EPOLL_CTL_DEL, d->watched - 1, NULL);
    d->watched = 0;
  }
  if (fd != 0xFFFFFFFFu) {
    struct epoll_event ev = { .events = EPOLLIN };
    ev.data.fd = (int)fd;
    if (epoll_ctl(d->set - 1, EPOLL_CTL_ADD, (int)fd, &ev) != 0) {
      return io_fail(e, (u32)errno, "Ankra: cannot watch the descriptor");
    }
    d->watched = (int)fd + 1;
  }
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_watch_use(void) {
  io_eff(CID(x11_watch), ak_x11_watch_run, 0);
}

#endif

// Text input
// ----------

#ifdef CID(x11_input)

// Opens Xlib's built-in input method for the window's display (once) and
// an input context on the window: XSetLocaleModifiers("@im=none") selects
// the local method (dead keys, compose sequences, AltGr levels; no IME
// server), XOpenIM, XCreateIC (no preedit, no status), XSetICFocus. Xlib
// takes the locale's charset and compose table at XOpenIM, so LC_CTYPE is
// set from the environment for that call and put back afterwards: the
// rest of the program never runs under a changed locale. Answers 1 with
// an input context, 0 without one (text then crosses as keysyms).
Term ak_x11_input_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_display_of(s);
  if (s == NULL || d == NULL) {
    return AK_BAD(e, "window");
  }
  if (d->im == NULL) {
    const char* was = setlocale(LC_CTYPE, NULL);
    char* old = was != NULL ? strdup(was) : NULL;
    if (setlocale(LC_CTYPE, "") != NULL && XSupportsLocale()
      && XSetLocaleModifiers("@im=none") != NULL) {
      d->im = XOpenIM(d->dpy, NULL, NULL, NULL);
    }
    setlocale(LC_CTYPE, old != NULL ? old : "C");
    free(old);
  }
  if (d->im != NULL && s->ic == NULL) {
    s->ic = XCreateIC(d->im, XNInputStyle, XIMPreeditNothing
      | XIMStatusNothing, XNClientWindow, s->xid, XNFocusWindow, s->xid,
      NULL);
    if (s->ic != NULL) {
      XSetICFocus(s->ic);
    }
  }
  return io_done(e, (Term)(u32)(s->ic != NULL));
}

static void __attribute__((constructor)) ak_x11_input_use(void) {
  io_eff(CID(x11_input), ak_x11_input_run, 0);
}

#endif

// Clipboard
// ---------
//
// The CLIPBOARD selection, as ICCCM describes it. Ownership, what to answer
// a request and when to ask are decided in Bend (clipboard.bend). Transfers
// are whole properties: no INCR, so text is bounded by the server's maximum
// request size on the way out and by Bend's limit on the way in.

static int ak_ignore(Display* dpy, XErrorEvent* err) {
  return 0;
}

#ifdef CID(x11_clip_own)

// XSetSelectionOwner(CLIPBOARD, window, time), then XGetSelectionOwner to
// see whether the server took it (a time older than the current owner's
// is refused). Answers 1 when the window owns the clipboard.
Term ak_x11_clip_own_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_display_of(s);
  if (s == NULL || d == NULL) {
    return AK_BAD(e, "window");
  }
  Atom clip = ak_atoms(d)[AK_CLIPBOARD];
  XSetSelectionOwner(s->dpy, clip, s->xid, (Time)(u32)f[1]);
  return io_done(e, (Term)(u32)(XGetSelectionOwner(s->dpy, clip) == s->xid));
}

static void __attribute__((constructor)) ak_x11_clip_own_use(void) {
  io_eff(CID(x11_clip_own), ak_x11_clip_own_run, 0);
}

#endif

#ifdef CID(x11_clip_reply)

// Answers a SelectionRequest: XChangeProperty on the requestor in the
// format Bend chose, then XSendEvent(SelectionNotify) and XSync. format: 0
// refuse (property None), 1 TARGETS with STRING, 2 TARGETS without
// STRING, 3 the text as UTF8_STRING, 4 the text as STRING (Latin-1; a
// scalar past 255 is EINVAL). Text past the server's request size is
// refused (no INCR). A requestor gone meanwhile raises X errors that are
// ignored for this call instead of ending the program.
Term ak_x11_clip_reply_run(Env e, Term* f, IoWork* w) {
  u64 n = 0;
  char* text = io_cstr(e, f[6], &n);
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_display_of(s);
  u32 format = (u32)f[4];
  if (s == NULL || d == NULL || format > 4) {
    free(text);
    return AK_BAD(e, "window or clipboard format");
  }
  Atom* a = ak_atoms(d);
  Window requestor = (Window)(u32)f[1];
  Atom property = (Atom)(u32)f[2];
  u64 room = (u64)XExtendedMaxRequestSize(s->dpy);
  room = (room != 0 ? room : (u64)XMaxRequestSize(s->dpy)) * 4 - 64;
  XErrorHandler old = XSetErrorHandler(ak_ignore);
  Bool sent = True;
  if (format == 1 || format == 2) {
    Atom list[4] = { a[AK_TARGETS], a[AK_UTF8], a[AK_TEXT], a[AK_STRING] };
    XChangeProperty(s->dpy, requestor, property, XA_ATOM, 32,
      PropModeReplace, (unsigned char*)list, format == 1 ? 4 : 3);
  } else if (format == 3 && n <= room) {
    XChangeProperty(s->dpy, requestor, property, a[AK_UTF8], 8,
      PropModeReplace, (unsigned char*)text, (int)n);
  } else if (format == 4 && n <= room) {
    u32* cs = io_mem(malloc((n + 1) * sizeof(u32)));
    int64_t m = ak_utf8((const u8*)text, n, cs);
    for (int64_t i = 0; i < m; i += 1) {
      sent = sent && cs[i] <= 255;
      text[i] = (char)cs[i];
    }
    free(cs);
    if (m < 0 || !sent) {
      XSetErrorHandler(old);
      free(text);
      return AK_BAD(e, "Latin-1 text");
    }
    XChangeProperty(s->dpy, requestor, property, XA_STRING, 8,
      PropModeReplace, (unsigned char*)text, (int)m);
  } else {
    sent = False;
  }
  XSelectionEvent r = { 0 };
  r.type = SelectionNotify;
  r.display = s->dpy;
  r.requestor = requestor;
  r.selection = a[AK_CLIPBOARD];
  r.target = (Atom)(u32)f[3];
  r.property = sent && format != 0 ? property : None;
  r.time = (Time)(u32)f[5];
  XSendEvent(s->dpy, requestor, False, NoEventMask, (XEvent*)&r);
  XSync(s->dpy, False);
  XSetErrorHandler(old);
  free(text);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_clip_reply_use(void) {
  io_eff(CID(x11_clip_reply), ak_x11_clip_reply_run, 0);
}

#endif

#ifdef CID(x11_clip_ask)

// XConvertSelection(CLIPBOARD, UTF8_STRING) into the window's ANKRA_PASTE
// property, then XFlush. The owner's answer arrives as a notify record.
Term ak_x11_clip_ask_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_display_of(s);
  if (s == NULL || d == NULL) {
    return AK_BAD(e, "window");
  }
  Atom* a = ak_atoms(d);
  XConvertSelection(s->dpy, a[AK_CLIPBOARD], a[AK_UTF8], a[AK_PASTE], s->xid,
    (Time)(u32)f[1]);
  XFlush(s->dpy);
  return AK_UNIT(e);
}

static void __attribute__((constructor)) ak_x11_clip_ask_use(void) {
  io_eff(CID(x11_clip_ask), ak_x11_clip_ask_run, 0);
}

#endif

#ifdef CID(x11_clip_take)

// XGetWindowProperty(ANKRA_PASTE, delete) after a notify: UTF8_STRING as
// strict UTF-8, STRING as Latin-1, into a String of at most `limit`
// scalars. Fails with 61 (ENODATA) when the property is missing, 27
// (EFBIG) for INCR or text past the limit, 84 (EILSEQ) for invalid UTF-8,
// 95 (ENOTSUP) for another type.
Term ak_x11_clip_take_run(Env e, Term* f, IoWork* w) {
  AkSlot* s = ak_get((u32)f[0], AK_WINDOW);
  AkSlot* d = ak_display_of(s);
  u32 limit = (u32)f[1];
  if (s == NULL || d == NULL) {
    return AK_BAD(e, "window");
  }
  Atom* a = ak_atoms(d);
  Atom type = None;
  int format = 0;
  unsigned long count = 0, after = 0;
  unsigned char* data = NULL;
  // UTF-8 takes at most 4 bytes per scalar: 4 * limit bytes, one more
  // 32-bit unit to see whether the text goes past it.
  if (XGetWindowProperty(s->dpy, s->xid, a[AK_PASTE], 0, (long)limit + 1,
      True, AnyPropertyType, &type, &format, &count, &after, &data)
      != Success) {
    return io_fail(e, 61, "Ankra: no clipboard text");
  }
  if (after != 0) {
    XDeleteProperty(s->dpy, s->xid, a[AK_PASTE]);
  }
  Term r;
  int64_t m = 0;
  if (type == None) {
    r = io_fail(e, 61, "Ankra: no clipboard text");
  } else if (type == a[AK_INCR] || after != 0) {
    r = io_fail(e, 27, "Ankra: clipboard text too large");
  } else if (format != 8 || (type != a[AK_UTF8] && type != XA_STRING)) {
    r = io_fail(e, 95, "Ankra: clipboard text in an unsupported type");
  } else if (type == a[AK_UTF8]
      && (m = ak_utf8(data, count, NULL)) < 0) {
    r = io_fail(e, 84, "Ankra: clipboard text is not valid UTF-8");
  } else if ((type == a[AK_UTF8] ? (u64)m : (u64)count) > limit) {
    r = io_fail(e, 27, "Ankra: clipboard text too large");
  } else if (type == a[AK_UTF8]) {
    r = io_done(e, io_str(e, (const char*)data, count));
  } else {
    char* u = io_mem(malloc(count * 2 + 1));
    u64 k = 0;
    for (unsigned long i = 0; i < count; i += 1) {
      k += io_utf8(u + k, data[i]);
    }
    r = io_done(e, io_str(e, u, k));
    free(u);
  }
  if (data != NULL) {
    XFree(data);
  }
  return r;
}

static void __attribute__((constructor)) ak_x11_clip_take_use(void) {
  io_eff(CID(x11_clip_take), ak_x11_clip_take_run, 0);
}

#endif

// Lifetimes
// ---------

#ifdef CID(x11_destroy)

// XDestroyIC (if any) and XDestroyWindow for a window slot (then XFlush),
// XCloseIM (if any), the epoll set of x11_watch (if any) and XCloseDisplay
// for a display slot. Bend destroys windows before their display.
Term ak_x11_destroy_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  if (id == 0 || id >= AK_SLOTS || ak_slot[id].kind == AK_FREE) {
    return AK_BAD(e, "slot");
  }
  AkSlot* s = &ak_slot[id];
  if (s->kind == AK_WINDOW) {
    if (s->ic != NULL) {
      XDestroyIC(s->ic);
    }
    XDestroyWindow(s->dpy, s->xid);
    XFlush(s->dpy);
  } else {
    if (s->im != NULL) {
      XCloseIM(s->im);
    }
    if (s->set != 0) {
      close(s->set - 1);
    }
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

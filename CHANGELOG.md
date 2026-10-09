# Changelog

All notable changes to Ankra are recorded here. Ankra follows
[semantic versioning](https://semver.org) in its 0.x form: while the API is
experimental, a minor version (0.2.0) may change it in breaking ways and a
patch version (0.1.1) only fixes. Ankra is built from source together with its
sibling AMAGE libraries; the set of versions tested together is listed in
[eco-build's releases](https://github.com/amage-si/eco-build/tree/main/releases).

## [0.1.1] - 2026-10-09

### Changed

- Build with Bend 2.0.36: the native bridge registers its 19 effects as
  `io_eff(CID(name), run)`, the form 2.0.36 requires (upstream #1281 removed
  the third `need` argument; an effect that waits parks itself). `x11_wait`
  already parked itself with `io_wait_on` on the X connection or the epoll
  set of `x11_watch`, so waiting is unchanged: idle stays at 0 frames and 0
  main-thread wakeups. No API change.

## [0.1.0] - 2026-10-09

First tagged release, tested with Bend 2.0.35 on Linux (X11/XWayland) as part
of AMAGE Eco 0.1.0.

### Included

- Native X11 window through a thin Xlib bridge: size hints, background
  choice, title and class, ordered teardown with a leak report.
- Ordered input decoded in Bend: resize, move, window focus, expose, close,
  keys with repeat flags and modifiers, pointer, enter/leave and wheel.
- Text input through Xlib's input method: dead keys, compose and AltGr levels
  (`TextTyped`), with the text policy in Bend.
- CLIPBOARD copy and paste (`clipboard.bend`), interoperating with X and,
  through XWayland, Wayland clients.
- `wait` that sleeps on the X connection with no timer, and `watch` that also
  wakes on another descriptor (one epoll set), so two event sources stay idle.
- `app.run` loop that draws only when stale and returns the final state.
- 62 native checks.

[0.1.1]: https://github.com/amage-si/ankra/releases/tag/v0.1.1
[0.1.0]: https://github.com/amage-si/ankra/releases/tag/v0.1.0

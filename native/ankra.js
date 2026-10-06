// Ankra native bridge: JavaScript twin
// ====================================
//
// Bend requires a JS file beside every effect's C file; it serves
// `bend file.bend` (checked and run in JS) and `-o file.js`. Ankra's native
// backend talks to Xlib, which the JS lane cannot reach, so every effect
// answers Fail with ENOTSUP (95). Programs on the JS lane can use the
// official runtime window through main.bend instead.

function ankra_unsupported() {
  return io_fail(95);
}

for (const id of [
  CID(x11_connect), CID(x11_create),
  CID(x11_protocols), CID(x11_title), CID(x11_class),
  CID(x11_size_hints), CID(x11_autorepeat), CID(x11_map),
  CID(x11_position), CID(x11_native), CID(x11_wait),
  CID(x11_destroy), CID(x11_live),
]) {
  io_eff(id, ankra_unsupported);
}

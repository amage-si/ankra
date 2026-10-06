import Base

# Key codes and modifiers for the native X11 backend.
#
# Codes follow Base's `Key` convention, so code written for the official
# runtime window reads the same numbers here: a key's character in lower
# case (Escape 27, Tab 9, Return 13, Space 32), Backspace 127, the arrows
# from 63232, the function keys from 63236, Insert/Delete/Home/End/Page
# keys in the private-use area, modifiers as 65536 + their Mac key code,
# Shift+Tab (ISO_Left_Tab) as 25, and any other key as 65536 + its X
# keycode. The bridge hands over the keysym and the characters that
# XLookupString produced with only Shift and Lock applied; the mapping
# itself is decided here.

# (keysym, code) pairs, checked before the character.
def table() -> List<&2, U32>:
  [65288, 127,     # BackSpace
   65362, 63232,   # Up
   65364, 63233,   # Down
   65361, 63234,   # Left
   65363, 63235,   # Right
   65379, 63271,   # Insert
   65535, 63272,   # Delete
   65360, 63273,   # Home
   65367, 63275,   # End
   65365, 63276,   # Page_Up
   65366, 63277,   # Page_Down
   65516, 65590,   # Super_R
   65515, 65591,   # Super_L
   65505, 65592,   # Shift_L
   65509, 65593,   # Caps_Lock
   65513, 65594,   # Alt_L
   65507, 65595,   # Control_L
   65506, 65596,   # Shift_R
   65514, 65597,   # Alt_R
   65508, 65598,   # Control_R
   65056, 25]      # ISO_Left_Tab

def lookup(xs: List<&2, U32>, +sym: U32) -> Maybe<&2, U32>:
  match xs:
    case Con{k, Con{v, rest}}:
      Bool.pick(Maybe<&2, U32>, U32.is_eq(k, sym), Some{v}, lookup(rest, sym))
    case _:
      None{}

# A single character, in lower case for A..Z; otherwise 65536 + keycode.
def character(+chars: U32, +keycode: U32) -> U32:
  +c = (chars .&. 255 : U32)
  +lower = Bool.pick(U32, U32.is_ge(c, 65) && U32.is_le(c, 90), (c + 32 : U32), c)
  Bool.pick(U32, U32.is_eq((chars >> 8n : U32), 1), lower, (65536 + keycode : U32))

def function_key(+sym: U32, +chars: U32, +keycode: U32) -> U32:
  Bool.pick(U32, U32.is_ge(sym, 65470) && U32.is_le(sym, 65481),
    (63236 + sym - 65470 : U32), character(chars, keycode))

def code.found(m: Maybe<&2, U32>, +sym: U32, +chars: U32, +keycode: U32) -> U32:
  match m:
    case Some{v}:
      v
    case None{}:
      function_key(sym, chars, keycode)

# The Base-style code of a key event: keysym table, F1..F12, the single
# character, else 65536 + keycode.
def code(+sym: U32, +keycode: U32, +chars: U32) -> U32:
  code.found(lookup(table(), sym), sym, chars, keycode)

# Modifier bits delivered with key and pointer events.
def shift() -> U32:
  1

def control() -> U32:
  2

def alt() -> U32:
  4

def super() -> U32:
  8

def caps_lock() -> U32:
  16

def bit(+state: U32, +mask: U32, +out: U32) -> U32:
  Bool.pick(U32, U32.is_eq((state .&. mask : U32), 0), 0, out)

# X modifier state (Shift 1, Lock 2, Control 4, Mod1 8, Mod4 64) to the
# bits above.
def mods(+state: U32) -> U32:
  (bit(state, 1, shift()) .|. bit(state, 4, control()) .|. bit(state, 8, alt()) .|.
    bit(state, 64, super()) .|. bit(state, 2, caps_lock()) : U32)

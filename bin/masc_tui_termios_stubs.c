#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/* VLNEXT and _POSIX_VDISABLE sit behind the BSD extensions on Apple
   platforms, which _POSIX_C_SOURCE alone hides. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <termios.h>
#include <unistd.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>

#ifndef VLNEXT
#error "disabling the literal-next key requires VLNEXT"
#endif

#ifndef _POSIX_VDISABLE
#error "disabling a special character requires _POSIX_VDISABLE"
#endif

/* Read the terminal's literal-next character.

   Returns the byte as 0..255, or -1 when the descriptor is not a terminal.
   The caller needs this before turning the key off: [Unix.tcsetattr] restores
   only the fields [Unix.terminal_io] names, and c_cc is not one of them, so
   handing the terminal back at exit does not put this character back. A
   session that ended without restoring it would leave the operator's shell
   with no literal-next key. */
CAMLprim value masc_tui_termios_literal_next(value v_fd)
{
  CAMLparam1(v_fd);
  struct termios attrs;

  if (tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_int(-1));

  CAMLreturn(Val_int((int)(unsigned char)attrs.c_cc[VLNEXT]));
}

/* Put the literal-next character back to [v_byte]. Pairs with
   {!masc_tui_termios_literal_next} at session end. */
CAMLprim value masc_tui_termios_set_literal_next(value v_fd, value v_byte)
{
  CAMLparam2(v_fd, v_byte);
  struct termios attrs;

  if (tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_false);

  attrs.c_cc[VLNEXT] = (cc_t)(unsigned char)Int_val(v_byte);

  if (tcsetattr(Int_val(v_fd), TCSANOW, &attrs) != 0)
    CAMLreturn(Val_false);

  CAMLreturn(Val_true);
}

/* Turn off the terminal's literal-next key so Ctrl-V reaches the process.

   Ctrl-V is VLNEXT's default character. While IEXTEN is set, the tty layer
   consumes it and passes the *following* byte through uninterpreted, so a
   reader sees "A" where the operator typed Ctrl-V then A. Measured on a pty
   with this program's raw mode (c_icanon, c_echo, c_icrnl off, ISIG kept):
   the reader got "A" before this call and "\x16A" after it.

   [Unix.terminal_io] carries neither IEXTEN nor c_cc[VLNEXT], which is why
   this is a stub rather than a field on the record the caller already sets --
   the same gap [masc_tui.ml] records for Ctrl-O, whose character is VDISCARD.

   VLNEXT alone is disabled rather than clearing IEXTEN, which would take
   VDISCARD and VSTATUS with it: one key is being reclaimed, so one special
   character is turned off.

   Returns false when the descriptor is not a terminal or the kernel refused
   the change. The caller keeps its own terminal either way -- the key stays
   swallowed and nothing else about the session changes. */
CAMLprim value masc_tui_termios_disable_literal_next(value v_fd)
{
  CAMLparam1(v_fd);
  struct termios attrs;

  if (tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_false);

  attrs.c_cc[VLNEXT] = _POSIX_VDISABLE;

  /* TCSANOW: bytes already queued were typed under the old meaning of the
     key, and draining them (TCSADRAIN/TCSAFLUSH) would make this call wait on
     terminal output while a frame is mid-flight. */
  if (tcsetattr(Int_val(v_fd), TCSANOW, &attrs) != 0)
    CAMLreturn(Val_false);

  CAMLreturn(Val_true);
}

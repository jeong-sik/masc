#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/* VLNEXT, VDSUSP and _POSIX_VDISABLE sit behind the BSD extensions on Apple
   platforms, which _POSIX_C_SOURCE alone hides. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <termios.h>
#include <unistd.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>

#ifndef VLNEXT
#error "reclaiming the literal-next key requires VLNEXT"
#endif

#ifndef _POSIX_VDISABLE
#error "disabling a special character requires _POSIX_VDISABLE"
#endif

/* The c_cc slot for a [Masc_tui_termios.reclaimed_key], or -1 where this
   platform's tty has no such key. The constructor is passed as its constant
   representation, so the cases follow the order the type declares them in.

   - Literal_next (VLNEXT, Ctrl-V). While IEXTEN is set, the tty layer
     consumes it and passes the *following* byte through uninterpreted, so a
     reader sees "A" where the operator typed Ctrl-V then A. Measured on a pty
     with this program's raw mode (c_icanon, c_echo, c_icrnl off, ISIG kept):
     the reader got "A" before disabling it and "\x16A" after.
   - Discard_output (VDISCARD, Ctrl-O). BSD line disciplines consume it even
     with ICANON off.
   - Delayed_suspend (VDSUSP, Ctrl-Y). BSD only. With ISIG and IEXTEN set --
     which this program's raw mode keeps -- reading the byte sends SIGTSTP
     instead of delivering it. Measured 2026-09-13 on macOS 26 with a pty:
     VDSUSP was 0x19, and one Ctrl-Y ended the TUI with exit 2 on
     Unix_error(EAGAIN, "read"); with VDSUSP disabled from outside, the same
     binary received the byte.

   Each key is disabled on its own rather than by clearing IEXTEN, which would
   take VSTATUS with it. */
static int reclaimed_key_index(value v_key)
{
  switch (Int_val(v_key)) {
  case 0:
    return VLNEXT;
  case 1:
#ifdef VDISCARD
    return VDISCARD;
#else
    return -1;
#endif
  case 2:
#ifdef VDSUSP
    return VDSUSP;
#else
    return -1;
#endif
  default:
    return -1;
  }
}

/* The key's current character as 0..255, or -1 when the descriptor is not a
   terminal or the platform has no such key. The caller needs this before
   turning the key off: [Unix.tcsetattr] restores only the fields
   [Unix.terminal_io] names, and c_cc is not one of them, so handing the
   terminal back at exit does not put this character back. */
CAMLprim value masc_tui_termios_key_char(value v_fd, value v_key)
{
  CAMLparam2(v_fd, v_key);
  struct termios attrs;
  int index = reclaimed_key_index(v_key);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_int(-1));

  CAMLreturn(Val_int((int)(unsigned char)attrs.c_cc[index]));
}

/* Put the key's character back to [v_byte]. */
CAMLprim value masc_tui_termios_set_key_char(value v_fd, value v_key, value v_byte)
{
  CAMLparam3(v_fd, v_key, v_byte);
  struct termios attrs;
  int index = reclaimed_key_index(v_key);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_false);

  attrs.c_cc[index] = (cc_t)(unsigned char)Int_val(v_byte);

  if (tcsetattr(Int_val(v_fd), TCSANOW, &attrs) != 0)
    CAMLreturn(Val_false);

  CAMLreturn(Val_true);
}

/* Turn the key off so its byte reaches the process.

   Returns false when the descriptor is not a terminal, the platform has no
   such key, or the kernel refused the change. The caller keeps its own
   terminal either way. */
CAMLprim value masc_tui_termios_disable_key(value v_fd, value v_key)
{
  CAMLparam2(v_fd, v_key);
  struct termios attrs;
  int index = reclaimed_key_index(v_key);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_false);

  attrs.c_cc[index] = _POSIX_VDISABLE;

  /* TCSANOW: bytes already queued were typed under the old meaning of the
     key, and draining them (TCSADRAIN/TCSAFLUSH) would make this call wait on
     terminal output while a frame is mid-flight. */
  if (tcsetattr(Int_val(v_fd), TCSANOW, &attrs) != 0)
    CAMLreturn(Val_false);

  CAMLreturn(Val_true);
}

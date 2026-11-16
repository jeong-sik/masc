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

/* Each [Masc_tui_termios.reclaimed_key]'s c_cc slot, or -1 where this
   platform's tty has no such key. One stub per key: OCaml matches on the key
   and calls its stub, so nothing here reads the order the type declares the
   constructors in.

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
   - Quit (VQUIT, Ctrl-backslash). POSIX, so every platform has it. With ISIG
     set -- which this program's raw mode keeps for Ctrl-C and Ctrl-Z -- the
     byte becomes SIGQUIT, and SIGQUIT ends the session unconfirmed. Measured
     in #49845 on TUI 0.68.0 in tmux: one Ctrl-backslash ended the process,
     and its log's last line was "exit: normal (signal SIGQUIT)".

   Each key is disabled on its own rather than by clearing IEXTEN, which would
   take VSTATUS with it, or ISIG, which would take Ctrl-C and Ctrl-Z. */
CAMLprim value masc_tui_termios_literal_next_slot(value unit)
{
  return Val_int(VLNEXT);
}

CAMLprim value masc_tui_termios_discard_output_slot(value unit)
{
#ifdef VDISCARD
  return Val_int(VDISCARD);
#else
  return Val_int(-1);
#endif
}

CAMLprim value masc_tui_termios_delayed_suspend_slot(value unit)
{
#ifdef VDSUSP
  return Val_int(VDSUSP);
#else
  return Val_int(-1);
#endif
}

CAMLprim value masc_tui_termios_quit_slot(value unit)
{
  return Val_int(VQUIT);
}

/* [v_slot] as an index into c_cc, or -1 when it is not one: the -1 a slot
   stub returns for a key this platform lacks. */
static int slot_index(value v_slot)
{
  int slot = Int_val(v_slot);

  if (slot < 0 || slot >= NCCS)
    return -1;
  return slot;
}

/* The slot's current character as 0..255, or -1 when the descriptor is not a
   terminal or the platform has no such key. The caller needs this before
   turning the key off: handing the terminal back with [Unix.tcsetattr] puts
   back only the c_cc characters [Unix.terminal_io] names, and VLNEXT,
   VDISCARD and VDSUSP are not among them. */
CAMLprim value masc_tui_termios_slot_char(value v_fd, value v_slot)
{
  CAMLparam2(v_fd, v_slot);
  struct termios attrs;
  int index = slot_index(v_slot);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_int(-1));

  CAMLreturn(Val_int((int)(unsigned char)attrs.c_cc[index]));
}

/* Put the slot's character back to [v_byte]. */
CAMLprim value masc_tui_termios_set_slot_char(value v_fd, value v_slot, value v_byte)
{
  CAMLparam3(v_fd, v_slot, v_byte);
  struct termios attrs;
  int index = slot_index(v_slot);

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
CAMLprim value masc_tui_termios_disable_slot(value v_fd, value v_slot)
{
  CAMLparam2(v_fd, v_slot);
  struct termios attrs;
  int index = slot_index(v_slot);

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

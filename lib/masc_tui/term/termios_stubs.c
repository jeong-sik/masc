#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

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

CAMLprim value masc_tui_v2_termios_literal_next_slot(value unit)
{
  (void)unit;
  return Val_int(VLNEXT);
}

CAMLprim value masc_tui_v2_termios_discard_output_slot(value unit)
{
  (void)unit;
#ifdef VDISCARD
  return Val_int(VDISCARD);
#else
  return Val_int(-1);
#endif
}

CAMLprim value masc_tui_v2_termios_delayed_suspend_slot(value unit)
{
  (void)unit;
#ifdef VDSUSP
  return Val_int(VDSUSP);
#else
  return Val_int(-1);
#endif
}

CAMLprim value masc_tui_v2_termios_suspend_slot(value unit)
{
  (void)unit;
#ifdef VSUSP
  return Val_int(VSUSP);
#else
  return Val_int(-1);
#endif
}

CAMLprim value masc_tui_v2_termios_quit_slot(value unit)
{
  (void)unit;
  return Val_int(VQUIT);
}

static int slot_index(value v_slot)
{
  int slot = Int_val(v_slot);
  if (slot < 0 || slot >= NCCS)
    return -1;
  return slot;
}

CAMLprim value masc_tui_v2_termios_slot_char(value v_fd, value v_slot)
{
  CAMLparam2(v_fd, v_slot);
  struct termios attrs;
  int index = slot_index(v_slot);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_int(-1));

  CAMLreturn(Val_int((int)(unsigned char)attrs.c_cc[index]));
}

CAMLprim value masc_tui_v2_termios_set_slot_char(value v_fd, value v_slot, value v_byte)
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

CAMLprim value masc_tui_v2_termios_disable_slot(value v_fd, value v_slot)
{
  CAMLparam2(v_fd, v_slot);
  struct termios attrs;
  int index = slot_index(v_slot);

  if (index < 0 || tcgetattr(Int_val(v_fd), &attrs) != 0)
    CAMLreturn(Val_false);

  attrs.c_cc[index] = _POSIX_VDISABLE;

  if (tcsetattr(Int_val(v_fd), TCSANOW, &attrs) != 0)
    CAMLreturn(Val_false);

  CAMLreturn(Val_true);
}

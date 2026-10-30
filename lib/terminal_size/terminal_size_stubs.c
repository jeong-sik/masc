#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/* TIOCGWINSZ lives behind the BSD extensions on Apple platforms, which
   _POSIX_C_SOURCE alone hides; glibc re-exposes them through _GNU_SOURCE. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <sys/ioctl.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#ifndef TIOCGWINSZ
#error "terminal size requires TIOCGWINSZ"
#endif

/* Returns [Some (rows, columns)] or [None].

   A zero row or column count is the kernel saying it does not know -- a pty
   whose size was never set answers that way -- and it is not a size anything
   can draw into, so it is reported as absent rather than passed on as a real
   measurement. */
CAMLprim value masc_terminal_size_of_fd(value v_fd)
{
  CAMLparam1(v_fd);
  CAMLlocal2(pair, some);
  struct winsize ws;

  if (ioctl(Int_val(v_fd), TIOCGWINSZ, &ws) != 0)
    CAMLreturn(Val_int(0));
  if (ws.ws_row == 0 || ws.ws_col == 0)
    CAMLreturn(Val_int(0));

  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, Val_int((int)ws.ws_row));
  Store_field(pair, 1, Val_int((int)ws.ws_col));
  some = caml_alloc(1, 0);
  Store_field(some, 0, pair);
  CAMLreturn(some);
}

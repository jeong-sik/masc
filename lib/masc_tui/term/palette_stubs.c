#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <stdint.h>
#include <unistd.h>

/* ncurses documents this include order for the terminfo API. */
#include <curses.h>
#include <term.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>

/* Returns (rgb, colors): rgb=1 if terminfo advertises RGB, 0 if absent,
   -1 if setupterm failed; colors=tigetnum("colors") normalized to -1 when absent. */
CAMLprim value
masc_tui_v2_palette_terminfo_capabilities(value v_term)
{
  CAMLparam1(v_term);
  CAMLlocal1(result);
  char *term = caml_stat_strdup(String_val(v_term));
  int rgb = -1;
  int colors = -1;
  int error = 0;
  int previous_extended_names;

  caml_enter_blocking_section();
  previous_extended_names = use_extended_names(TRUE);
  if (setupterm(term, STDOUT_FILENO, &error) == OK && error == 1) {
    int rgb_flag = tigetflag("RGB");
    int rgb_number = tigetnum("RGB");
    char *rgb_string = tigetstr("RGB");
    char *invalid_string = (char *)(intptr_t)-1;

    rgb =
      rgb_flag > 0 || rgb_number >= 0
      || (rgb_string != NULL && rgb_string != invalid_string);
    colors = tigetnum("colors");
    if (colors < 0)
      colors = -1;
  }
  use_extended_names(previous_extended_names);
  caml_leave_blocking_section();

  caml_stat_free(term);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(rgb));
  Store_field(result, 1, Val_int(colors));
  CAMLreturn(result);
}

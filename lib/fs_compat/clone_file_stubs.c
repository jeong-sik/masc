#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#include <sys/clonefile.h>
#endif
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* Clone [src] to the new path [dst] with clonefile(2). Unlike cp -c, a
   filesystem that cannot clone is an error, never a data copy. Other
   platforms have no clonefile and report ENOSYS. */
CAMLprim value caml_masc_clone_file(value v_src, value v_dst)
{
  CAMLparam2(v_src, v_dst);
  char *src = caml_stat_strdup(String_val(v_src));
  char *dst = caml_stat_strdup(String_val(v_dst));
  int result, saved_errno;
  caml_enter_blocking_section();
#if defined(__APPLE__)
  result = clonefile(src, dst, CLONE_NOFOLLOW);
#else
  errno = ENOSYS;
  result = -1;
#endif
  saved_errno = errno;
  caml_leave_blocking_section();
  caml_stat_free(src);
  caml_stat_free(dst);
  if (result == -1) {
    errno = saved_errno;
    uerror("clone_file", v_src);
  }
  CAMLreturn(Val_unit);
}

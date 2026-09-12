#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#endif
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

CAMLprim value caml_masc_publish_paths(value v_exchange, value v_left, value v_right)
{
  CAMLparam3(v_exchange, v_left, v_right);
  char *left = caml_stat_strdup(String_val(v_left));
  char *right = caml_stat_strdup(String_val(v_right));
  int exchange = Bool_val(v_exchange);
  int result, saved_errno;
  caml_enter_blocking_section();
#if defined(__linux__) && defined(SYS_renameat2)
  /* syscall avoids raising the release's glibc symbol floor to 2.28. */
  result = syscall(SYS_renameat2, AT_FDCWD, left, AT_FDCWD, right,
                   exchange ? RENAME_EXCHANGE : RENAME_NOREPLACE);
#elif defined(__APPLE__)
  result = renamex_np(left, right, exchange ? RENAME_SWAP : RENAME_EXCL);
#else
  errno = ENOSYS;
  result = -1;
#endif
  saved_errno = errno;
  caml_leave_blocking_section();
  caml_stat_free(left);
  caml_stat_free(right);
  if (result == -1) {
    errno = saved_errno;
    uerror(exchange ? "exchange_paths" : "rename_noreplace", v_left);
  }
  CAMLreturn(Val_unit);
}

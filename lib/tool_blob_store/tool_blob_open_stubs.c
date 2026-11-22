#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* Open an existing regular file atomically without following symlinks and
   without blocking on FIFOs. Rejects symlinks with ELOOP. */
CAMLprim value caml_masc_tool_blob_open_readonly_nofollow_nonblock(value v_path)
{
  CAMLparam1(v_path);
  caml_unix_check_path(v_path, "open");
  char *path = caml_stat_strdup(String_val(v_path));
  int fd, saved_errno;
  caml_enter_blocking_section();
  do {
    fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  } while (fd < 0 && errno == EINTR);
  saved_errno = errno;
  caml_leave_blocking_section();
  caml_stat_free(path);
  if (fd < 0) {
    errno = saved_errno;
    uerror("open", v_path);
  }
  CAMLreturn(Val_int(fd));
}

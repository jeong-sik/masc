#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/* Darwin gates O_NOFOLLOW, O_NOCTTY and O_CLOEXEC behind __DARWIN_C_LEVEL, and
   defining _POSIX_C_SOURCE alone lowers that level below the point where the
   headers declare them. The guard further down then fires and the build stops
   with "capability exact read requires ...". glibc never showed it because
   _GNU_SOURCE exposes everything, so CI stayed green while every macOS checkout
   could not compile this stub — and therefore could not build any test target
   that links fs_compat. Raise the Darwin level explicitly, before <fcntl.h>. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#if !defined(O_NONBLOCK) || !defined(O_CLOEXEC) || !defined(O_NOFOLLOW) || \
    !defined(O_NOCTTY)
#error "capability exact read requires O_NONBLOCK, O_CLOEXEC, O_NOFOLLOW, and O_NOCTTY"
#endif

CAMLprim value
caml_masc_fs_compat_openat_nofollow_ro_nonblock(value v_dirfd, value v_leaf)
{
  CAMLparam2(v_dirfd, v_leaf);
  char *leaf = caml_stat_strdup(String_val(v_leaf));
  int descriptor;
  int saved_errno;

  caml_enter_blocking_section();
  descriptor =
    openat(
      Int_val(v_dirfd),
      leaf,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY);
  saved_errno = errno;
  caml_leave_blocking_section();

  caml_stat_free(leaf);

  if (descriptor == -1) {
    errno = saved_errno;
    uerror("openat", v_leaf);
  }

  CAMLreturn(Val_int(descriptor));
}

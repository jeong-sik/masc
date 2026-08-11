#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#if !defined(O_CLOEXEC) || !defined(O_DIRECTORY) || !defined(O_NOFOLLOW)
#error "shared audit append requires O_CLOEXEC, O_DIRECTORY, and O_NOFOLLOW"
#endif

static int
open_directory(int directory_fd, const char *path, int *saved_errno)
{
  int descriptor;

  caml_enter_blocking_section();
  if (directory_fd == AT_FDCWD) {
    descriptor = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  } else {
    descriptor =
      openat(
        directory_fd,
        path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  }
  *saved_errno = errno;
  caml_leave_blocking_section();
  return descriptor;
}

CAMLprim value
caml_masc_shared_audit_open_directory(value v_path)
{
  CAMLparam1(v_path);
  char *path = caml_stat_strdup(String_val(v_path));
  int saved_errno;
  int descriptor = open_directory(AT_FDCWD, path, &saved_errno);
  caml_stat_free(path);

  if (descriptor == -1) {
    errno = saved_errno;
    uerror("open", v_path);
  }

  CAMLreturn(Val_int(descriptor));
}

CAMLprim value
caml_masc_shared_audit_mkdirat_if_missing(value v_dirfd, value v_leaf)
{
  CAMLparam2(v_dirfd, v_leaf);
  char *leaf = caml_stat_strdup(String_val(v_leaf));
  int result;
  int saved_errno;

  caml_enter_blocking_section();
  result = mkdirat(Int_val(v_dirfd), leaf, 0755);
  saved_errno = errno;
  caml_leave_blocking_section();

  caml_stat_free(leaf);

  if (result == -1 && saved_errno != EEXIST) {
    errno = saved_errno;
    uerror("mkdirat", v_leaf);
  }

  CAMLreturn(Val_unit);
}

CAMLprim value
caml_masc_shared_audit_openat_directory(value v_dirfd, value v_leaf)
{
  CAMLparam2(v_dirfd, v_leaf);
  char *leaf = caml_stat_strdup(String_val(v_leaf));
  int saved_errno;
  int descriptor = open_directory(Int_val(v_dirfd), leaf, &saved_errno);
  caml_stat_free(leaf);

  if (descriptor == -1) {
    errno = saved_errno;
    uerror("openat", v_leaf);
  }

  CAMLreturn(Val_int(descriptor));
}

CAMLprim value
caml_masc_shared_audit_openat_append_file(value v_dirfd, value v_leaf)
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
      O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
      0644);
  saved_errno = errno;
  caml_leave_blocking_section();

  caml_stat_free(leaf);

  if (descriptor == -1) {
    errno = saved_errno;
    uerror("openat", v_leaf);
  }

  CAMLreturn(Val_int(descriptor));
}

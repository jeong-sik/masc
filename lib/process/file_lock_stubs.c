#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* flock(2) is tied to the open-file description. An independent inspection
 * open/close cannot release the live producer's lock, even in one process.
 * https://man7.org/linux/man-pages/man2/flock.2.html */
static value try_open_private_lock(value path_value, int lock_mode) {
  CAMLparam1(path_value);
  CAMLlocal1(result);
  char *path = caml_stat_strdup(String_val(path_value));
  int fd = -1, failure = 0, held = 0;
  struct stat opened, named;
  caml_enter_blocking_section();
  do { fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK); }
  while (fd < 0 && errno == EINTR);
  if (fd < 0) failure = errno;
  else if (fstat(fd, &opened) < 0 || lstat(path, &named) < 0) failure = errno;
  else if (!S_ISREG(opened.st_mode) || !S_ISREG(named.st_mode) ||
           opened.st_uid != geteuid() || opened.st_nlink != 1 ||
           (opened.st_mode & 0777) != 0600 ||
           opened.st_dev != named.st_dev || opened.st_ino != named.st_ino)
    failure = EINVAL;
  else {
    int locked;
    do { locked = flock(fd, lock_mode | LOCK_NB); }
    while (locked < 0 && errno == EINTR);
    if (locked < 0) {
      if (errno == EWOULDBLOCK || errno == EAGAIN) held = 1;
      else failure = errno;
    } else if (lstat(path, &named) < 0) failure = errno;
    else if (!S_ISREG(named.st_mode) || named.st_nlink != 1 ||
             named.st_uid != geteuid() || (named.st_mode & 0777) != 0600 ||
             opened.st_dev != named.st_dev || opened.st_ino != named.st_ino)
      failure = EINVAL;
  }
  if ((failure || held) && fd >= 0) { close(fd); fd = -1; }
  caml_leave_blocking_section();
  caml_stat_free(path);
  if (failure) { errno = failure; uerror("liveness_flock", path_value); }
  if (held) CAMLreturn(Val_none);
  result = caml_alloc_some(Val_int(fd));
  CAMLreturn(result);
}

CAMLprim value masc_try_open_liveness_lock(value path_value) {
  return try_open_private_lock(path_value, LOCK_EX);
}

CAMLprim value masc_try_open_shared_liveness_lock(value path_value) {
  return try_open_private_lock(path_value, LOCK_SH);
}

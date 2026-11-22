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

/* Acquire an exclusive non-blocking OS lock that excludes BOTH BSD flock(2)
 * holders (e.g. liveness/stage locks) AND POSIX fcntl/lockf(3) holders.
 *
 * - On macOS/BSD kernels (Darwin/FreeBSD/OpenBSD/NetBSD), flock(2) and
 *   fcntl/lockf(3) share the kernel vnode lock list (vn_advlock), so
 *   flock(LOCK_EX | LOCK_NB) alone atomically conflicts with both flock(2) and
 *   fcntl/lockf(3) holders (and issuing fcntl(F_SETLK) afterward on the same
 *   fd would self-conflict with EAGAIN).
 * - On Linux and other POSIX systems where flock(2) and fcntl(F_SETLK) are
 *   independent kernel lock tables, acquire BOTH flock(LOCK_EX | LOCK_NB) and
 *   F_SETLK(F_WRLCK) simultaneously on fd, rolling back flock if F_SETLK fails. */
CAMLprim value masc_try_lock_fd_exclusive_all(value fd_value) {
  CAMLparam1(fd_value);
  int fd = Int_val(fd_value);
  int rc, failure = 0, held = 0;
  caml_enter_blocking_section();
  do { rc = flock(fd, LOCK_EX | LOCK_NB); }
  while (rc < 0 && errno == EINTR);
  if (rc < 0) {
    if (errno == EWOULDBLOCK || errno == EAGAIN) held = 1;
    else failure = errno;
  }
#if !defined(__APPLE__) && !defined(__FreeBSD__) && !defined(__OpenBSD__) && !defined(__NetBSD__)
  else {
    struct flock fl = {0};
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;
    do { rc = fcntl(fd, F_SETLK, &fl); }
    while (rc < 0 && errno == EINTR);
    if (rc < 0) {
      int saved_errno = errno;
      int urc;
      do { urc = flock(fd, LOCK_UN); }
      while (urc < 0 && errno == EINTR);
      (void)urc;
      if (saved_errno == EACCES || saved_errno == EAGAIN) held = 1;
      else failure = saved_errno;
    }
  }
#endif
  caml_leave_blocking_section();
  if (failure) { errno = failure; uerror("flock", Nothing); }
  CAMLreturn(held ? Val_false : Val_true);
}

CAMLprim value masc_unlock_fd_all(value fd_value) {
  CAMLparam1(fd_value);
  int fd = Int_val(fd_value);
  int rc, failure = 0;
  caml_enter_blocking_section();
#if !defined(__APPLE__) && !defined(__FreeBSD__) && !defined(__OpenBSD__) && !defined(__NetBSD__)
  {
    struct flock fl = {0};
    fl.l_type = F_UNLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;
    do { rc = fcntl(fd, F_SETLK, &fl); }
    while (rc < 0 && errno == EINTR);
    if (rc < 0) failure = errno;
  }
#endif
  do { rc = flock(fd, LOCK_UN); }
  while (rc < 0 && errno == EINTR);
  if (rc < 0 && !failure) failure = errno;
  caml_leave_blocking_section();
  if (failure) { errno = failure; uerror("flock", Nothing); }
  CAMLreturn(Val_unit);
}

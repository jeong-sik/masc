#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
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

/* flock(2) is tied to the open-file description, never the process inode table,
   so probing from a fresh descriptor cannot drop a live writer's stage lock. */
CAMLprim value caml_masc_stage_flock_try_lock_ex(value v_fd)
{
  CAMLparam1(v_fd);
  int fd = Int_val(v_fd);
  int rc;
  do {
    rc = flock(fd, LOCK_EX | LOCK_NB);
  } while (rc < 0 && errno == EINTR);
  CAMLreturn(Val_bool(rc == 0));
}

/* Says whether a stage file is held, and when it cannot be told apart from a
   dead one. A caller that reclaims on "not held" must not also reclaim on
   "cannot be told": a filesystem without flock(2), an unreadable path and a
   non-regular file all mean the probe learned nothing, not that the writer is
   gone. Returns a reason code so the caller can say which it was.

     0  Not_held          the probe took LOCK_EX and released it
     1  Held              the holder's lock answered EWOULDBLOCK/EAGAIN
     2  Open_failed       open(2) refused the path
     3  Not_regular_file  the path is not a regular file
     4  Flock_refused     flock(2) failed for a reason other than contention
                          (ENOLCK, EOPNOTSUPP, ...) */
CAMLprim value caml_masc_stage_flock_probe_path(value v_path)
{
  CAMLparam1(v_path);
  char *path = caml_stat_strdup(String_val(v_path));
  int fd = -1, code = 2;
  struct stat st;
  caml_enter_blocking_section();
  do {
    fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  } while (fd < 0 && errno == EINTR);
  if (fd >= 0) {
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
      int rc;
      do {
        rc = flock(fd, LOCK_EX | LOCK_NB);
      } while (rc < 0 && errno == EINTR);
      if (rc < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) {
        code = 1;
      } else if (rc == 0) {
        (void)flock(fd, LOCK_UN);
        code = 0;
      } else {
        code = 4;
      }
    } else {
      code = 3;
    }
    (void)close(fd);
  }
  caml_leave_blocking_section();
  caml_stat_free(path);
  CAMLreturn(Val_int(code));
}

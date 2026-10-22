#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* Clone the regular file [src] to the new path [dst]. Unlike cp -c, a
   filesystem that cannot clone is an error, never a data copy. The source is
   opened without following a symlink and checked to be a regular file, so a
   clone of a link is never mistaken for a copy of its target. Other
   platforms have no clonefile and report ENOSYS. */
CAMLprim value caml_masc_clone_file(value v_src, value v_dst)
{
  CAMLparam2(v_src, v_dst);
  char *src = caml_stat_strdup(String_val(v_src));
  char *dst = caml_stat_strdup(String_val(v_dst));
  int result, saved_errno;
  caml_enter_blocking_section();
#if defined(__APPLE__)
  {
    int fd = open(src, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd == -1) {
      result = -1;
    } else {
      struct stat st;
      if (fstat(fd, &st) == -1) {
        result = -1;
      } else if (!S_ISREG(st.st_mode)) {
        errno = EINVAL;
        result = -1;
      } else {
        result = fclonefileat(fd, AT_FDCWD, dst, CLONE_NOFOLLOW);
      }
      saved_errno = errno;
      close(fd);
      errno = saved_errno;
    }
  }
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

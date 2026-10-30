#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

CAMLprim value caml_masc_retention_remove_regular(value v_fd, value v_name, value v_cutoff)
{
  CAMLparam3(v_fd, v_name, v_cutoff);
  int fd = Int_val(v_fd), removed = 0, saved = 0;
  int has_cutoff = Is_block(v_cutoff);
  double cutoff = has_cutoff ? Double_val(Field(v_cutoff, 0)) : 0;
  char *name = caml_stat_strdup(String_val(v_name));
  caml_enter_blocking_section();
  struct stat entry;
  if (fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == -1) {
    if (errno != ENOENT) saved = errno;
  } else {
#if defined(__APPLE__)
    double mtime = entry.st_mtimespec.tv_sec + entry.st_mtimespec.tv_nsec / 1e9;
#else
    double mtime = entry.st_mtim.tv_sec + entry.st_mtim.tv_nsec / 1e9;
#endif
    if (S_ISREG(entry.st_mode) && (!has_cutoff || mtime < cutoff)) {
      if (unlinkat(fd, name, 0) == 0) removed = 1;
      else if (errno != ENOENT) saved = errno;
    }
  }
  caml_leave_blocking_section();
  caml_stat_free(name);
  if (saved) { errno = saved; uerror("retention_unlinkat", v_name); }
  CAMLreturn(Val_bool(removed));
}

CAMLprim value caml_masc_retention_remove_empty(value v_fd, value v_name)
{
  CAMLparam2(v_fd, v_name);
  int fd = Int_val(v_fd);
  char *name = caml_stat_strdup(String_val(v_name));
  caml_enter_blocking_section();
  /* Retention does not require empty-directory removal to succeed. In
     particular AT_REMOVEDIR refuses a replacement symbolic link. */
  (void)unlinkat(fd, name, AT_REMOVEDIR);
  caml_leave_blocking_section();
  caml_stat_free(name);
  CAMLreturn(Val_unit);
}

/* Checked unlink acknowledgements for owners that must count partial effects.
   Neither operation follows a final symbolic link; the held parent owns it. */
static value retention_unlink_checked(value v_fd, value v_name, int flags)
{
  CAMLparam2(v_fd, v_name);
  int fd = Int_val(v_fd), removed = 0, saved = 0;
  char *name = caml_stat_strdup(String_val(v_name));
  caml_enter_blocking_section();
  if (unlinkat(fd, name, flags) == 0) removed = 1;
  else if (errno != ENOENT) saved = errno;
  caml_leave_blocking_section();
  caml_stat_free(name);
  if (saved) { errno = saved; uerror("retention_unlinkat", v_name); }
  CAMLreturn(Val_bool(removed));
}

CAMLprim value caml_masc_retention_unlink_entry(value v_fd, value v_name)
{
  return retention_unlink_checked(v_fd, v_name, 0);
}

CAMLprim value caml_masc_retention_remove_empty_checked(value v_fd, value v_name)
{
  return retention_unlink_checked(v_fd, v_name, AT_REMOVEDIR);
}

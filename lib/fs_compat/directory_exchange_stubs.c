#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
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

/* Open and enumerate one directory descriptor without following a final
 * symlink. The caller receives names read from that descriptor, so a pathname
 * replacement after open cannot redirect the enumeration to another tree. */
CAMLprim value caml_masc_readdir_nofollow(value v_path, value v_device, value v_inode)
{
  CAMLparam3(v_path, v_device, v_inode);
  CAMLlocal3(result, cell, name);
  char *path = caml_stat_strdup(String_val(v_path));
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  DIR *directory;
  struct dirent *entry;
  struct stat opened;
  int saved_errno;

  if (fd == -1) {
    caml_stat_free(path);
    uerror("open_directory", v_path);
  }
  if (fstat(fd, &opened) == -1) {
    saved_errno = errno;
    close(fd);
    caml_stat_free(path);
    errno = saved_errno;
    uerror("fstat_directory", v_path);
  }
  if ((uintnat)opened.st_dev != (uintnat)Long_val(v_device)
      || (uintnat)opened.st_ino != (uintnat)Long_val(v_inode)) {
    close(fd);
    caml_stat_free(path);
    errno = EXDEV;
    uerror("directory_identity", v_path);
  }
  directory = fdopendir(fd);
  if (directory == NULL) {
    saved_errno = errno;
    close(fd);
    caml_stat_free(path);
    errno = saved_errno;
    uerror("fdopendir", v_path);
  }

  result = Val_emptylist;
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    name = caml_copy_string(entry->d_name);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, name);
    Store_field(cell, 1, result);
    result = cell;
  }
  saved_errno = errno;
  if (closedir(directory) == -1 && saved_errno == 0)
    saved_errno = errno;
  caml_stat_free(path);
  if (saved_errno != 0) {
    errno = saved_errno;
    uerror("readdir", v_path);
  }
  CAMLreturn(result);
}

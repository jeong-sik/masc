#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* Like the shared-audit directory boundary: canonical root, then no-follow
   descriptor-relative components. Never resolve a replacement symlink. */
CAMLprim value caml_masc_owned_directory_open(value v_parent, value v_path)
{
  CAMLparam2(v_parent, v_path);
  char *path = caml_stat_strdup(String_val(v_path));
  int parent = Int_val(v_parent), result, saved_errno;
  caml_enter_blocking_section();
  result = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  saved_errno = errno;
  caml_leave_blocking_section();
  caml_stat_free(path);
  if (result == -1) { errno = saved_errno; uerror("openat", v_path); }
  CAMLreturn(Val_int(result));
}

CAMLprim value caml_masc_owned_directory_root(value v_path)
{
  CAMLparam1(v_path);
  CAMLreturn(caml_masc_owned_directory_open(Val_int(AT_FDCWD), v_path));
}

struct inventory_name { char *name; struct inventory_name *next; };

/* A duplicated descriptor owns the DIR stream, so closedir cannot close the
   caller's descriptor used for fstat and chain validation. */
CAMLprim value caml_masc_owned_directory_names(value v_fd)
{
  CAMLparam1(v_fd);
  CAMLlocal3(result, cell, name);
  struct inventory_name *names = NULL;
  int saved_errno = 0;
  caml_enter_blocking_section();
  int duplicate = fcntl(Int_val(v_fd), F_DUPFD_CLOEXEC, 0);
  DIR *directory = duplicate == -1 ? NULL : fdopendir(duplicate);
  if (directory == NULL) {
    saved_errno = errno;
    if (duplicate != -1) close(duplicate);
  } else {
    for (;;) {
      errno = 0;
      struct dirent *entry = readdir(directory);
      if (entry == NULL) { saved_errno = errno; break; }
      struct inventory_name *item = malloc(sizeof *item);
      if (item == NULL) { saved_errno = ENOMEM; break; }
      item->name = strdup(entry->d_name);
      if (item->name == NULL) { free(item); saved_errno = ENOMEM; break; }
      item->next = names;
      names = item;
    }
    if (closedir(directory) == -1 && saved_errno == 0) saved_errno = errno;
  }
  caml_leave_blocking_section();
  if (saved_errno != 0) {
    while (names != NULL) {
      struct inventory_name *next = names->next;
      free(names->name); free(names); names = next;
    }
    errno = saved_errno; uerror("readdir", Nothing);
  }
  result = Val_emptylist;
  while (names != NULL) {
    struct inventory_name *next = names->next;
    name = caml_copy_string(names->name);
    free(names->name); free(names); names = next;
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, name); Store_field(cell, 1, result);
    result = cell;
  }
  CAMLreturn(result);
}

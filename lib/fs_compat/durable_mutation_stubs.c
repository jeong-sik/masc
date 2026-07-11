#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(O_CLOEXEC) || !defined(O_DIRECTORY) || !defined(O_NOFOLLOW)
#error "durable mutation requires O_CLOEXEC, O_DIRECTORY, and O_NOFOLLOW"
#endif

static int parent_fd(value descriptor)
{
  return Int_val(descriptor);
}

static void free_preserving_errno(void *pointer)
{
  int saved_errno = errno;
  caml_stat_free(pointer);
  errno = saved_errno;
}

CAMLprim value masc_durable_mutation_open_parent(value path)
{
  CAMLparam1(path);
  char *copied_path;
  int descriptor;

  caml_unix_check_path(path, "durable_mutation_open_parent");
  copied_path = caml_stat_strdup(String_val(path));
  caml_enter_blocking_section();
  descriptor = open(copied_path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  caml_leave_blocking_section();
  free_preserving_errno(copied_path);
  if (descriptor == -1) uerror("durable_mutation_open_parent", path);
  CAMLreturn(Val_int(descriptor));
}

CAMLprim value masc_durable_mutation_create_exclusive(value parent,
                                                       value name,
                                                       value mode)
{
  CAMLparam3(parent, name, mode);
  char *copied_name;
  int parent_descriptor;
  int file_mode;
  int descriptor;

  caml_unix_check_path(name, "durable_mutation_create_exclusive");
  copied_name = caml_stat_strdup(String_val(name));
  parent_descriptor = parent_fd(parent);
  file_mode = Int_val(mode);
  caml_enter_blocking_section();
  descriptor = openat(parent_descriptor, copied_name,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      file_mode);
  caml_leave_blocking_section();
  free_preserving_errno(copied_name);
  if (descriptor == -1) uerror("durable_mutation_create_exclusive", name);
  CAMLreturn(Val_int(descriptor));
}

CAMLprim value masc_durable_mutation_rename(value parent,
                                            value old_name,
                                            value new_name)
{
  CAMLparam3(parent, old_name, new_name);
  size_t old_length;
  size_t new_length;
  char *allocation;
  char *old_copy;
  char *new_copy;
  int parent_descriptor;
  int result;

  caml_unix_check_path(old_name, "durable_mutation_rename_old");
  caml_unix_check_path(new_name, "durable_mutation_rename_new");
  old_length = caml_string_length(old_name);
  new_length = caml_string_length(new_name);
  allocation = caml_stat_alloc(old_length + new_length + 2);
  old_copy = allocation;
  new_copy = allocation + old_length + 1;
  memcpy(old_copy, String_val(old_name), old_length);
  old_copy[old_length] = '\0';
  memcpy(new_copy, String_val(new_name), new_length);
  new_copy[new_length] = '\0';
  parent_descriptor = parent_fd(parent);
  caml_enter_blocking_section();
  result = renameat(parent_descriptor, old_copy,
                    parent_descriptor, new_copy);
  caml_leave_blocking_section();
  free_preserving_errno(allocation);
  if (result == -1) uerror("durable_mutation_rename", old_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_durable_mutation_unlink(value parent, value name)
{
  CAMLparam2(parent, name);
  char *copied_name;
  int parent_descriptor;
  int result;

  caml_unix_check_path(name, "durable_mutation_unlink");
  copied_name = caml_stat_strdup(String_val(name));
  parent_descriptor = parent_fd(parent);
  caml_enter_blocking_section();
  result = unlinkat(parent_descriptor, copied_name, 0);
  caml_leave_blocking_section();
  free_preserving_errno(copied_name);
  if (result == -1) uerror("durable_mutation_unlink", name);
  CAMLreturn(Val_unit);
}

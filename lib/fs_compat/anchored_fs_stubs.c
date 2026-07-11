#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(O_CLOEXEC) || !defined(O_DIRECTORY) || !defined(O_NOFOLLOW)
#error "descriptor-anchored filesystem requires O_CLOEXEC, O_DIRECTORY, and O_NOFOLLOW"
#endif

#if !defined(AT_SYMLINK_NOFOLLOW)
#error "descriptor-anchored filesystem requires AT_SYMLINK_NOFOLLOW"
#endif

static int anchored_fd(value descriptor)
{
  return Int_val(descriptor);
}

static void stat_free_preserving_errno(void *pointer)
{
  int saved_errno = errno;
  caml_stat_free(pointer);
  errno = saved_errno;
}

CAMLprim value masc_anchored_open_root(value path)
{
  CAMLparam1(path);
  char *copied_path;
  int fd;

  caml_unix_check_path(path, "anchored_open_root");
  copied_path = caml_stat_strdup(String_val(path));
  caml_enter_blocking_section();
  fd = open(copied_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_path);
  if (fd == -1) uerror("anchored_open_root", path);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_open_dir(value directory, value name)
{
  CAMLparam1(name);
  char *copied_name;
  int fd;

  caml_unix_check_path(name, "anchored_open_dir");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  fd = openat(anchored_fd(directory), copied_name,
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (fd == -1) uerror("anchored_open_dir", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_open_read(value directory, value name)
{
  CAMLparam1(name);
  char *copied_name;
  int fd;

  caml_unix_check_path(name, "anchored_open_read");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  fd = openat(anchored_fd(directory), copied_name,
              O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (fd == -1) uerror("anchored_open_read", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_create_exclusive(value directory, value name, value mode)
{
  CAMLparam1(name);
  char *copied_name;
  int fd;

  caml_unix_check_path(name, "anchored_create_exclusive");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  fd = openat(anchored_fd(directory), copied_name,
              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              Int_val(mode));
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (fd == -1) uerror("anchored_create_exclusive", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_mkdir(value directory, value name, value mode)
{
  CAMLparam1(name);
  char *copied_name;
  int result;

  caml_unix_check_path(name, "anchored_mkdir");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  result = mkdirat(anchored_fd(directory), copied_name, Int_val(mode));
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (result == -1) uerror("anchored_mkdir", name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_unlink(value directory, value name)
{
  CAMLparam1(name);
  char *copied_name;
  int result;

  caml_unix_check_path(name, "anchored_unlink");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  result = unlinkat(anchored_fd(directory), copied_name, 0);
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (result == -1) uerror("anchored_unlink", name);
  CAMLreturn(Val_unit);
}

static char *copy_two_paths(value first, value second, char **second_copy)
{
  size_t first_length = caml_string_length(first);
  size_t second_length = caml_string_length(second);
  char *allocation = caml_stat_alloc(first_length + second_length + 2);
  *second_copy = allocation + first_length + 1;
  memcpy(allocation, String_val(first), first_length + 1);
  memcpy(*second_copy, String_val(second), second_length + 1);
  return allocation;
}

CAMLprim value masc_anchored_rename(value old_directory, value old_name,
                                    value new_directory, value new_name)
{
  CAMLparam2(old_name, new_name);
  char *old_copy;
  char *new_copy;
  int result;

  caml_unix_check_path(old_name, "anchored_rename_old");
  caml_unix_check_path(new_name, "anchored_rename_new");
  old_copy = copy_two_paths(old_name, new_name, &new_copy);
  caml_enter_blocking_section();
  result = renameat(anchored_fd(old_directory), old_copy,
                    anchored_fd(new_directory), new_copy);
  caml_leave_blocking_section();
  stat_free_preserving_errno(old_copy);
  if (result == -1) uerror("anchored_rename", old_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_link(value old_directory, value old_name,
                                  value new_directory, value new_name)
{
  CAMLparam2(old_name, new_name);
  char *old_copy;
  char *new_copy;
  int result;

  caml_unix_check_path(old_name, "anchored_link_old");
  caml_unix_check_path(new_name, "anchored_link_new");
  old_copy = copy_two_paths(old_name, new_name, &new_copy);
  caml_enter_blocking_section();
  result = linkat(anchored_fd(old_directory), old_copy,
                  anchored_fd(new_directory), new_copy, 0);
  caml_leave_blocking_section();
  stat_free_preserving_errno(old_copy);
  if (result == -1) uerror("anchored_link", old_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_stat(value directory, value name)
{
  CAMLparam1(name);
  CAMLlocal3(result, tuple, number);
  char *copied_name;
  struct stat metadata;
  int stat_result;

  caml_unix_check_path(name, "anchored_stat");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  stat_result = fstatat(anchored_fd(directory), copied_name, &metadata,
                        AT_SYMLINK_NOFOLLOW);
  caml_leave_blocking_section();
  stat_free_preserving_errno(copied_name);
  if (stat_result == -1) {
    if (errno == ENOENT) CAMLreturn(Val_int(0));
    uerror("anchored_stat", name);
  }

  int kind = 3;
  if (S_ISREG(metadata.st_mode)) kind = 0;
  else if (S_ISDIR(metadata.st_mode)) kind = 1;
  else if (S_ISLNK(metadata.st_mode)) kind = 2;

  tuple = caml_alloc(5, 0);
  Store_field(tuple, 0, Val_int(kind));
  number = caml_copy_int64((int64_t) metadata.st_size);
  Store_field(tuple, 1, number);
  number = caml_copy_int64((int64_t) metadata.st_dev);
  Store_field(tuple, 2, number);
  number = caml_copy_int64((int64_t) metadata.st_ino);
  Store_field(tuple, 3, number);
  number = caml_copy_int64((int64_t) metadata.st_nlink);
  Store_field(tuple, 4, number);

  result = caml_alloc(1, 0);
  Store_field(result, 0, tuple);
  CAMLreturn(result);
}

CAMLprim value masc_anchored_fdopendir(value descriptor)
{
  CAMLparam0();
  CAMLlocal1(result);
  DIR *directory;

  result = caml_alloc_small(1, Abstract_tag);
  DIR_Val(result) = NULL;
  directory = fdopendir(anchored_fd(descriptor));
  if (directory == NULL) uerror("anchored_fdopendir", Nothing);
  DIR_Val(result) = directory;
  CAMLreturn(result);
}

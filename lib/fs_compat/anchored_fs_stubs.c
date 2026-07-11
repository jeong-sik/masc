#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
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

CAMLprim value masc_anchored_open_root(value path)
{
  CAMLparam1(path);
  int fd = open(String_val(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) uerror("anchored_open_root", path);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_open_dir(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(anchored_fd(directory), String_val(name),
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) uerror("anchored_open_dir", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_open_read(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(anchored_fd(directory), String_val(name),
                  O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) uerror("anchored_open_read", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_create_exclusive(value directory, value name, value mode)
{
  CAMLparam3(directory, name, mode);
  int fd = openat(anchored_fd(directory), String_val(name),
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                  Int_val(mode));
  if (fd == -1) uerror("anchored_create_exclusive", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value masc_anchored_mkdir(value directory, value name, value mode)
{
  CAMLparam3(directory, name, mode);
  if (mkdirat(anchored_fd(directory), String_val(name), Int_val(mode)) == -1)
    uerror("anchored_mkdir", name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_unlink(value directory, value name)
{
  CAMLparam2(directory, name);
  if (unlinkat(anchored_fd(directory), String_val(name), 0) == -1)
    uerror("anchored_unlink", name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_rename(value old_directory, value old_name,
                                    value new_directory, value new_name)
{
  CAMLparam4(old_directory, old_name, new_directory, new_name);
  if (renameat(anchored_fd(old_directory), String_val(old_name),
               anchored_fd(new_directory), String_val(new_name)) == -1)
    uerror("anchored_rename", old_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_link(value old_directory, value old_name,
                                  value new_directory, value new_name)
{
  CAMLparam4(old_directory, old_name, new_directory, new_name);
  if (linkat(anchored_fd(old_directory), String_val(old_name),
             anchored_fd(new_directory), String_val(new_name), 0) == -1)
    uerror("anchored_link", old_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_anchored_stat(value directory, value name)
{
  CAMLparam2(directory, name);
  CAMLlocal3(result, tuple, number);
  struct stat metadata;

  if (fstatat(anchored_fd(directory), String_val(name), &metadata,
              AT_SYMLINK_NOFOLLOW) == -1) {
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

CAMLprim value masc_anchored_readdir(value directory)
{
  CAMLparam1(directory);
  CAMLlocal3(entries, cell, name);

  int duplicate = dup(anchored_fd(directory));
  if (duplicate == -1) uerror("anchored_readdir_dup", Nothing);

  DIR *handle = fdopendir(duplicate);
  if (handle == NULL) {
    int saved_errno = errno;
    int close_result = close(duplicate);
    int close_errno = errno;
    if (close_result == -1) {
      char detail[160];
      snprintf(detail, sizeof(detail),
               "anchored_readdir_open errno=%d; duplicate close errno=%d",
               saved_errno, close_errno);
      caml_failwith(detail);
    }
    errno = saved_errno;
    uerror("anchored_readdir_open", Nothing);
  }

  entries = Val_emptylist;
  errno = 0;
  for (;;) {
    struct dirent *entry = readdir(handle);
    if (entry == NULL) break;
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
      continue;
    name = caml_copy_string(entry->d_name);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, name);
    Store_field(cell, 1, entries);
    entries = cell;
    errno = 0;
  }

  int read_errno = errno;
  int close_result = closedir(handle);
  int close_errno = errno;
  if (read_errno != 0 && close_result == -1) {
    char detail[160];
    snprintf(detail, sizeof(detail),
             "anchored_readdir errno=%d; closedir errno=%d",
             read_errno, close_errno);
    caml_failwith(detail);
  }
  if (close_result == -1) read_errno = close_errno;
  if (read_errno != 0) {
    errno = read_errno;
    uerror("anchored_readdir", Nothing);
  }

  CAMLreturn(entries);
}

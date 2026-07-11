#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(O_CLOEXEC) || !defined(O_DIRECTORY) || !defined(O_NOFOLLOW) || \
    !defined(AT_SYMLINK_NOFOLLOW)
#error "atomic orphan recovery requires descriptor-relative no-follow APIs"
#endif

static int descriptor(value fd)
{
  return Int_val(fd);
}

static void free_preserving_errno(void *pointer)
{
  int saved_errno = errno;
  caml_stat_free(pointer);
  errno = saved_errno;
}

CAMLprim value masc_atomic_orphan_open_child(value parent, value name)
{
  CAMLparam2(parent, name);
  char *copied_name;
  int result;

  caml_unix_check_path(name, "atomic_orphan_open_child");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  result = openat(descriptor(parent), copied_name,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  caml_leave_blocking_section();
  free_preserving_errno(copied_name);
  if (result == -1) uerror("atomic_orphan_open_child", name);
  CAMLreturn(Val_int(result));
}

CAMLprim value masc_atomic_orphan_mkdir_child(value parent,
                                               value name,
                                               value mode)
{
  CAMLparam3(parent, name, mode);
  char *copied_name;
  int result;

  caml_unix_check_path(name, "atomic_orphan_mkdir_child");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  result = mkdirat(descriptor(parent), copied_name, Int_val(mode));
  caml_leave_blocking_section();
  free_preserving_errno(copied_name);
  if (result == -1) uerror("atomic_orphan_mkdir_child", name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_atomic_orphan_lstat_entry(value parent, value name)
{
  CAMLparam2(parent, name);
  CAMLlocal4(result, size, device, inode);
  char *copied_name;
  struct stat statbuf;
  int syscall_result;
  int kind;

  caml_unix_check_path(name, "atomic_orphan_lstat_entry");
  copied_name = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  syscall_result = fstatat(descriptor(parent), copied_name, &statbuf,
                           AT_SYMLINK_NOFOLLOW);
  caml_leave_blocking_section();
  free_preserving_errno(copied_name);
  if (syscall_result == -1) uerror("atomic_orphan_lstat_entry", name);

  if (S_ISREG(statbuf.st_mode)) kind = 0;
  else if (S_ISDIR(statbuf.st_mode)) kind = 1;
  else if (S_ISLNK(statbuf.st_mode)) kind = 2;
  else kind = 3;

  size = caml_copy_int64((int64_t)statbuf.st_size);
  device = caml_copy_int64((int64_t)statbuf.st_dev);
  inode = caml_copy_int64((int64_t)statbuf.st_ino);
  result = caml_alloc_tuple(4);
  Store_field(result, 0, Val_int(kind));
  Store_field(result, 1, size);
  Store_field(result, 2, device);
  Store_field(result, 3, inode);
  CAMLreturn(result);
}

CAMLprim value masc_atomic_orphan_link_entry(value source_parent,
                                              value source_name,
                                              value target_parent,
                                              value target_name)
{
  CAMLparam4(source_parent, source_name, target_parent, target_name);
  size_t source_length = caml_string_length(source_name);
  size_t target_length = caml_string_length(target_name);
  char *allocation;
  char *source_copy;
  char *target_copy;
  int result;

  caml_unix_check_path(source_name, "atomic_orphan_link_source");
  caml_unix_check_path(target_name, "atomic_orphan_link_target");
  allocation = caml_stat_alloc(source_length + target_length + 2);
  source_copy = allocation;
  target_copy = allocation + source_length + 1;
  memcpy(source_copy, String_val(source_name), source_length);
  source_copy[source_length] = '\0';
  memcpy(target_copy, String_val(target_name), target_length);
  target_copy[target_length] = '\0';

  caml_enter_blocking_section();
  result = linkat(descriptor(source_parent), source_copy,
                  descriptor(target_parent), target_copy, 0);
  caml_leave_blocking_section();
  free_preserving_errno(allocation);
  if (result == -1) uerror("atomic_orphan_link_entry", source_name);
  CAMLreturn(Val_unit);
}

CAMLprim value masc_atomic_orphan_read_entries(value directory)
{
  CAMLparam1(directory);
  CAMLlocal2(result, entry_value);
  DIR *stream;
  struct dirent *entry;
  char **names = NULL;
  size_t count = 0;
  size_t capacity = 0;
  int copied_fd;
  int read_errno = 0;
  size_t index;

  caml_enter_blocking_section();
  copied_fd = dup(descriptor(directory));
  if (copied_fd == -1) {
    read_errno = errno;
  } else {
    stream = fdopendir(copied_fd);
    if (stream == NULL) {
      read_errno = errno;
      close(copied_fd);
    } else {
      errno = 0;
      while ((entry = readdir(stream)) != NULL) {
        char *copy;
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) continue;
        if (count == capacity) {
          size_t next_capacity = capacity == 0 ? 16 : capacity * 2;
          char **next = realloc(names, next_capacity * sizeof(char *));
          if (next == NULL) {
            read_errno = ENOMEM;
            break;
          }
          names = next;
          capacity = next_capacity;
        }
        copy = strdup(entry->d_name);
        if (copy == NULL) {
          read_errno = ENOMEM;
          break;
        }
        names[count++] = copy;
      }
      if (read_errno == 0 && errno != 0) read_errno = errno;
      if (closedir(stream) == -1 && read_errno == 0) read_errno = errno;
    }
  }
  caml_leave_blocking_section();

  if (read_errno != 0) {
    for (index = 0; index < count; index++) free(names[index]);
    free(names);
    errno = read_errno;
    uerror("atomic_orphan_read_entries", Nothing);
  }

  result = caml_alloc_tuple(count);
  for (index = 0; index < count; index++) {
    entry_value = caml_copy_string(names[index]);
    Store_field(result, index, entry_value);
    free(names[index]);
  }
  free(names);
  CAMLreturn(result);
}

#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int private_owned(int fd, int directory) {
  struct stat st;
  if (fstat(fd, &st) < 0) return 0;
  if (st.st_uid != geteuid() || (st.st_mode & 0077) != 0 ||
      (directory ? !S_ISDIR(st.st_mode) : (!S_ISREG(st.st_mode) || st.st_nlink != 1))) {
    errno = EACCES; return 0;
  }
  return 1;
}
CAMLprim value masc_native_lease_directory(value path) {
  CAMLparam1(path);
  int fd = open(String_val(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) caml_uerror("native lease directory", path);
  if (!private_owned(fd, 1)) {
    int saved = errno; close(fd); errno = saved; caml_uerror("private native lease directory", path);
  }
  CAMLreturn(Val_int(fd));
}
CAMLprim value masc_native_lease_file(value directory, value name, value create) {
  CAMLparam3(directory, name, create);
  const char *text = String_val(name);
  if (caml_string_length(name) != strlen(text) || strchr(text, '/') ||
      !strcmp(text, ".") || !strcmp(text, "..") || !*text) {
    errno = EINVAL; caml_uerror("native lease filename", name);
  }
  int flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC;
  if (Bool_val(create)) flags |= O_CREAT;
  int fd = openat(Int_val(directory), text, flags, 0600);
  if (fd < 0) caml_uerror("native lease openat", name);
  if (!private_owned(fd, 0)) {
    int saved = errno; close(fd); errno = saved; caml_uerror("private native lease file", name);
  }
  CAMLreturn(Val_int(fd));
}
CAMLprim value masc_native_lease_holder(value descriptor) {
  CAMLparam1(descriptor);
  struct flock lock;
  memset(&lock, 0, sizeof(lock));
  lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
  if (fcntl(Int_val(descriptor), F_GETLK, &lock) < 0)
    caml_uerror("native lease F_GETLK", Nothing);
  CAMLreturn(Val_int(lock.l_type == F_UNLCK ? 0 : lock.l_pid));
}
CAMLprim value masc_native_lease_replace(value directory, value name, value bytes) {
  CAMLparam3(directory, name, bytes);
  static _Atomic unsigned long sequence = 0;
  char temporary[96];
  int root = Int_val(directory), fd;
  do {
    unsigned long next = atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed) + 1;
    snprintf(temporary, sizeof(temporary), ".pending-%ld-%lu", (long)getpid(), next);
    fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  } while (fd < 0 && errno == EEXIST);
  if (fd < 0) caml_uerror("native metadata temporary", name);
  mlsize_t offset = 0, length = caml_string_length(bytes);
  while (offset < length) {
    ssize_t written = write(fd, String_val(bytes) + offset, length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) {
      int saved = written == 0 ? EIO : errno;
      close(fd); unlinkat(root, temporary, 0); errno = saved;
      caml_uerror("native metadata write", name);
    }
    offset += written;
  }
  if (fsync(fd) < 0) {
    int saved = errno; close(fd); unlinkat(root, temporary, 0); errno = saved;
    caml_uerror("native metadata fsync", name);
  }
  if (close(fd) < 0) {
    int saved = errno; unlinkat(root, temporary, 0); errno = saved;
    caml_uerror("native metadata close", name);
  }
  if (renameat(root, temporary, root, String_val(name)) < 0) {
    int saved = errno; unlinkat(root, temporary, 0); errno = saved;
    caml_uerror("native metadata publish", name);
  }
  if (fsync(root) < 0) caml_uerror("native metadata directory fsync", name);
  CAMLreturn(Val_unit);
}
CAMLprim value masc_native_lease_group_leader(value unit) {
  (void)unit;
  return Val_bool(getpid() > 1 && getpid() == getpgrp());
}

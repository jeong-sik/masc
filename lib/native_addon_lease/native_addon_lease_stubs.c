#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
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
CAMLprim value masc_native_lease_group_leader(value unit) {
  (void)unit;
  return Val_bool(getpid() > 1 && getpid() == getpgrp());
}

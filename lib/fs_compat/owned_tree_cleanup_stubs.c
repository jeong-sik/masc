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
#include <sys/stat.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

struct cleanup_directory {
  char *path;
  dev_t device;
  ino_t inode;
  uid_t uid;
  mode_t permissions;
  int fd;
};

static int matches(const struct cleanup_directory *expected, const struct stat *actual)
{
  return S_ISDIR(actual->st_mode) && actual->st_dev == expected->device
    && actual->st_ino == expected->inode && actual->st_uid == expected->uid
    && (actual->st_mode & 07777) == expected->permissions;
}

/* Keep the retained spelling as well as every held descriptor bound. The
   caller excludes writers; POSIX has no atomic inode-conditional unlink. */
static int validate_chain(struct cleanup_directory *chain, size_t count, int absent)
{
  struct stat actual;
  if (fstatat(AT_FDCWD, chain[0].path, &actual, AT_SYMLINK_NOFOLLOW) == -1) return -1;
  if (!matches(&chain[0], &actual)) { errno = ESTALE; return -1; }
  for (size_t i = 0; i < count; ++i) {
    if (i == count - 1 && absent) break;
    if (fstat(chain[i].fd, &actual) == -1) return -1;
    if (!matches(&chain[i], &actual)) { errno = ESTALE; return -1; }
    if (i > 0) {
      const char *name = strrchr(chain[i].path, '/') + 1;
      if (fstatat(chain[i-1].fd, name, &actual, AT_SYMLINK_NOFOLLOW) == -1) return -1;
      if (!matches(&chain[i], &actual)) { errno = ESTALE; return -1; }
    }
  }
  if (absent) {
    const char *name = strrchr(chain[count-1].path, '/') + 1;
    if (fstatat(chain[count-2].fd, name, &actual, AT_SYMLINK_NOFOLLOW) == 0) {
      errno = ESTALE; return -1;
    }
    if (errno != ENOENT) return -1;
  }
  return 0;
}

static int clear_directory(int fd, struct cleanup_directory *chain, size_t count)
{
  int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (duplicate == -1) return -1;
  DIR *directory = fdopendir(duplicate);
  if (directory == NULL) { int saved = errno; close(duplicate); errno = saved; return -1; }
  rewinddir(directory);
  int saved = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (entry == NULL) { saved = errno; break; }
    const char *name = entry->d_name;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    if (validate_chain(chain, count, 0) == -1) { saved = errno; break; }
    struct stat before, held, after;
    if (fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == -1) { saved = errno; break; }
    if (S_ISDIR(before.st_mode)) {
      if (before.st_dev != chain[count-1].device || before.st_uid != chain[count-1].uid) {
        saved = EXDEV; break;
      }
      int child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child == -1) { saved = errno; break; }
      int outcome = fstat(child, &held);
      if (outcome == 0 && (held.st_dev != before.st_dev || held.st_ino != before.st_ino)) {
        errno = ESTALE; outcome = -1;
      }
      if (outcome == 0) outcome = clear_directory(child, chain, count);
      if (outcome == 0) outcome = fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW);
      if (outcome == 0 && (!S_ISDIR(after.st_mode)
          || after.st_dev != held.st_dev || after.st_ino != held.st_ino)) {
        errno = ESTALE; outcome = -1;
      }
      if (outcome == 0) outcome = unlinkat(fd, name, AT_REMOVEDIR);
      int child_error = outcome == -1 ? errno : 0;
      if (close(child) == -1 && child_error == 0) child_error = errno;
      if (child_error) { saved = child_error; break; }
    } else {
      /* A symlink/FIFO/socket/device is only an entry to unlink. Never open it. */
      if (unlinkat(fd, name, 0) == -1) { saved = errno; break; }
    }
    if (fsync(fd) == -1) { saved = errno; break; }
  }
  if (closedir(directory) == -1 && saved == 0) saved = errno;
  if (saved) { errno = saved; return -1; }
  return fsync(fd);
}

CAMLprim value caml_masc_owned_tree_remove(value v_chain)
{
  CAMLparam1(v_chain);
  size_t count = Wosize_val(v_chain);
  struct cleanup_directory *chain = calloc(count, sizeof *chain);
  int saved = count < 2 ? EINVAL : (chain == NULL ? ENOMEM : 0);
  if (chain != NULL) {
    for (size_t i = 0; i < count; ++i) chain[i].fd = -1;
    for (size_t i = 0; i < count; ++i) {
      value expected = Field(v_chain, i);
      chain[i].path = strdup(String_val(Field(expected, 0)));
      if (chain[i].path == NULL) { saved = ENOMEM; break; }
      chain[i].device = Long_val(Field(expected, 1));
      chain[i].inode = Long_val(Field(expected, 2));
      chain[i].uid = Long_val(Field(expected, 3));
      chain[i].permissions = Long_val(Field(expected, 4));
    }
  }
  caml_enter_blocking_section();
  if (!saved) {
    int absent = 0;
    for (size_t i = 0; i < count; ++i) {
      chain[i].fd = i == 0
        ? open(chain[i].path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        : openat(chain[i-1].fd, strrchr(chain[i].path, '/') + 1,
                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (chain[i].fd == -1) {
        if (i == count - 1 && errno == ENOENT) absent = 1;
        else saved = errno;
        break;
      }
      struct stat held;
      if (fstat(chain[i].fd, &held) == -1) { saved = errno; break; }
      if (!matches(&chain[i], &held)) { saved = ESTALE; break; }
    }
    if (!saved && validate_chain(chain, count, absent) == -1) saved = errno;
    if (!saved && !absent && clear_directory(chain[count-1].fd, chain, count) == -1) saved = errno;
    if (!saved && !absent && validate_chain(chain, count, 0) == -1) saved = errno;
    if (!saved && !absent && unlinkat(chain[count-2].fd,
        strrchr(chain[count-1].path, '/') + 1, AT_REMOVEDIR) == -1) saved = errno;
    if (!saved && fsync(chain[count-2].fd) == -1) saved = errno;
    if (!saved && validate_chain(chain, count, 1) == -1) saved = errno;
  }
  if (chain != NULL) {
    for (size_t i = count; i > 0; --i) {
      if (chain[i-1].fd != -1 && close(chain[i-1].fd) == -1 && saved == 0) saved = errno;
      free(chain[i-1].path);
    }
    free(chain);
  }
  caml_leave_blocking_section();
  if (saved) { errno = saved; uerror("owned_tree_cleanup", Nothing); }
  CAMLreturn(Val_unit);
}

#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
#include <sys/stat.h>
#elif defined(__linux__)
#include <sys/inotify.h>
#endif

struct watch_entry { int identity; size_t target; int descriptor; };
struct watch_set { int queue; size_t count; struct watch_entry *entries; };

static void release_set(struct watch_set *set) {
  if (set->queue >= 0) close(set->queue);
  set->queue = -1;
  for (size_t i = 0; i < set->count; ++i)
    if (set->entries[i].descriptor >= 0) close(set->entries[i].descriptor);
  free(set->entries);
  set->entries = NULL; set->count = 0;
}

static void finalize(value raw) { release_set(Data_custom_val(raw)); }
static struct custom_operations operations = {
  .identifier = "masc.native_file_change.v1",
  .finalize = finalize,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default
};

static void failed(value raw, const char *operation, value path) {
  int saved = errno;
  release_set(Data_custom_val(raw));
  errno = saved;
  uerror(operation, path);
}

CAMLprim value masc_file_change_supported(value unit) {
  (void)unit;
#if defined(__APPLE__) || defined(__linux__)
  return Val_true;
#else
  return Val_false;
#endif
}

#if defined(__linux__)
static int compare_entry(const void *left, const void *right) {
  int a = ((const struct watch_entry *)left)->identity;
  int b = ((const struct watch_entry *)right)->identity;
  return (a > b) - (a < b);
}
static struct watch_entry *find_entry(struct watch_set *set, int identity) {
  size_t lo = 0, hi = set->count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (set->entries[mid].identity == identity) return &set->entries[mid];
    if (set->entries[mid].identity < identity) lo = mid + 1; else hi = mid;
  }
  return NULL;
}
#endif

CAMLprim value masc_file_change_create(value paths, value directories, value devices, value inodes) {
  CAMLparam4(paths, directories, devices, inodes);
  CAMLlocal1(raw);
  raw = caml_alloc_custom(&operations, sizeof(struct watch_set), 0, 1);
  struct watch_set *set = Data_custom_val(raw);
  set->queue = -1; set->count = 0; set->entries = NULL;
  size_t count = Wosize_val(paths);
  if (count != Wosize_val(directories) || count != Wosize_val(devices)
      || count != Wosize_val(inodes) || count > SIZE_MAX / sizeof(struct watch_entry)) {
    errno = EINVAL; failed(raw, "file_change_create", Nothing);
  }
#if defined(__APPLE__)
  set->queue = kqueue();
  if (set->queue >= 0 && fcntl(set->queue, F_SETFD, FD_CLOEXEC) < 0)
    failed(raw, "file_change_create", Nothing);
#elif defined(__linux__)
  set->queue = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#else
  errno = ENOSYS; failed(raw, "file_change_create", Nothing);
#endif
  if (set->queue < 0) failed(raw, "file_change_create", Nothing);
  set->entries = calloc(count ? count : 1, sizeof(struct watch_entry));
  if (!set->entries) { errno = ENOMEM; failed(raw, "file_change_create", Nothing); }
  for (size_t i = 0; i < count; ++i) {
    struct watch_entry *entry = &set->entries[i];
    entry->target = i; entry->descriptor = -1;
    set->count = i + 1;
#if defined(__APPLE__)
    entry->descriptor = open(String_val(Field(paths, i)), O_EVTONLY | O_CLOEXEC);
#elif defined(__linux__)
    entry->descriptor = open(String_val(Field(paths, i)), O_PATH | O_CLOEXEC);
#endif
#if defined(__APPLE__) || defined(__linux__)
    if (entry->descriptor < 0) failed(raw, "file_change_register", Field(paths, i));
    struct stat status;
    if (fstat(entry->descriptor, &status) < 0)
      failed(raw, "file_change_register", Field(paths, i));
    if (Val_long(status.st_dev) != Field(devices, i) || Val_long(status.st_ino) != Field(inodes, i)) {
      errno = ESTALE; failed(raw, "file_change_target_changed", Field(paths, i));
    }
    if (Bool_val(Field(directories, i))) {
      if (!S_ISDIR(status.st_mode)) {
        errno = ENOTDIR; failed(raw, "file_change_register", Field(paths, i));
      }
    }
#endif
#if defined(__APPLE__)
    struct kevent change;
    EV_SET(&change, entry->descriptor, EVFILT_VNODE, EV_ADD | EV_CLEAR,
      NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE,
      0, (void *)(uintptr_t)(i + 1));
    const struct timespec immediate = {0, 0};
    int registered;
    do { registered = kevent(set->queue, &change, 1, NULL, 0, &immediate); }
    while (registered < 0 && errno == EINTR);
    if (registered < 0) failed(raw, "file_change_register", Field(paths, i));
#elif defined(__linux__)
    uint32_t mask = Bool_val(Field(directories, i))
      ? IN_ONLYDIR | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO
        | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT
      : IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT;
    /* This proc link identifies the opened inode, even if the caller's
       pathname is exchanged while registration is in progress. */
    char opened_path[64];
    int length = snprintf(opened_path, sizeof(opened_path), "/proc/self/fd/%d", entry->descriptor);
    if (length < 0 || (size_t)length >= sizeof(opened_path)) {
      errno = EOVERFLOW; failed(raw, "file_change_register", Field(paths, i));
    }
    entry->identity = inotify_add_watch(set->queue, opened_path, mask);
    if (entry->identity < 0) failed(raw, "file_change_register", Field(paths, i));
    close(entry->descriptor); entry->descriptor = -1;
#endif
  }
#if defined(__linux__)
  qsort(set->entries, count, sizeof(struct watch_entry), compare_entry);
  for (size_t i = 1; i < count; ++i) {
    if (set->entries[i-1].identity == set->entries[i].identity) {
      /* No caller ever adds/rebinds a watch in a live set. Even during setup,
         reject a reused/alias descriptor before interpreting its queued data. */
      errno = EEXIST; failed(raw, "file_change_ambiguous", Nothing);
    }
  }
#endif
  CAMLreturn(raw);
}

CAMLprim value masc_file_change_descriptor(value raw) {
  CAMLparam1(raw);
  CAMLreturn(Val_int(((struct watch_set *)Data_custom_val(raw))->queue));
}

CAMLprim value masc_file_change_close(value raw) {
  CAMLparam1(raw);
  release_set(Data_custom_val(raw));
  CAMLreturn(Val_unit);
}

CAMLprim value masc_file_change_drain(value raw) {
  CAMLparam1(raw);
  CAMLlocal3(indices, cell, result);
  indices = Val_emptylist;
  int loss = 0;
  /* Cons allocation may move the OCaml custom block. Its rooted owner keeps
     the malloc array alive; copy these scalar/pointer fields to the C stack. */
  struct watch_set snapshot = *(struct watch_set *)Data_custom_val(raw);
  struct watch_set *set = &snapshot;
  if (set->queue < 0) { errno = EBADF; uerror("file_change_drain", Nothing); }
#if defined(__APPLE__)
  struct kevent events[64];
  const struct timespec immediate = {0, 0};
  int count;
  do { count = kevent(set->queue, NULL, 0, events, 64, &immediate); }
  while (count < 0 && errno == EINTR);
  if (count < 0) uerror("file_change_drain", Nothing);
  for (int i = 0; i < count; ++i) {
    struct kevent *event = &events[i];
    if (event->flags & EV_ERROR) { errno = (int)event->data; uerror("file_change_drain", Nothing); }
    uintptr_t token = (uintptr_t)event->udata;
    if (!token || token > set->count || event->filter != EVFILT_VNODE) { loss = 3; continue; }
    if (event->fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) { loss = 2; continue; }
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, Val_long(token - 1)); Store_field(cell, 1, indices); indices = cell;
  }
#elif defined(__linux__)
  /* A bounded syscall batch, not a source cadence or correctness limit. */
  union { struct inotify_event alignment; char bytes[65536]; } buffer;
  ssize_t count;
  do { count = read(set->queue, buffer.bytes, sizeof(buffer.bytes)); }
  while (count < 0 && errno == EINTR);
  if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) count = 0;
  if (count < 0) uerror("file_change_drain", Nothing);
  size_t cursor = 0;
  while (cursor < (size_t)count) {
    if ((size_t)count - cursor < sizeof(struct inotify_event)) { loss = 3; break; }
    struct inotify_event *event = (struct inotify_event *)(buffer.bytes + cursor);
    size_t length = sizeof(*event) + event->len;
    if (length > (size_t)count - cursor) { loss = 3; break; }
    cursor += length;
    if (event->mask & IN_Q_OVERFLOW) { loss = 1; continue; }
    if (event->mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT)) {
      if (loss != 1) loss = 2;
      continue;
    }
    struct watch_entry *entry = find_entry(set, event->wd);
    if (!entry) { if (!loss) loss = 3; continue; }
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, Val_long(entry->target)); Store_field(cell, 1, indices); indices = cell;
  }
#else
  errno = ENOSYS; uerror("file_change_drain", Nothing);
#endif
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(loss)); Store_field(result, 1, indices);
  CAMLreturn(result);
}

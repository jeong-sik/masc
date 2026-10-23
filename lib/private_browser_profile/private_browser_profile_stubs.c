#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <libproc.h>
#elif defined(__linux__)
#include <limits.h>
#include <sys/syscall.h>
#endif

/* The captured holder of a lock on a masc-private profile lock file. It never
   keeps a descriptor for that lock file: closing any descriptor for a file
   drops every POSIX record lock this process holds on it, so the lock file's
   one descriptor stays with the OCaml caller. */
struct holder {
  pid_t pid;
#ifdef __APPLE__
  audit_token_t token;
#elif defined(__linux__)
  int pidfd;
#endif
};
static void release_holder(struct holder *h) {
#if defined(__linux__)
  if (h->pidfd >= 0) close(h->pidfd);
  h->pidfd = -1;
#else
  (void)h;
#endif
}
static void finalize_holder(value v) { release_holder(Data_custom_val(v)); }
static struct custom_operations operations = {
  .identifier = "masc.private_browser_profile.holder.v1",
  .finalize = finalize_holder,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default
};

#define OWNER_FREE 0
#define OWNER_FAILED (-1)
/* Held, but the kernel reports no PID this process can see, as for a holder
   in another PID namespace. */
#define OWNER_HIDDEN (-2)
/* Asks for a whole-file write lock, so any conflicting lock is reported. */
static pid_t lock_owner(int fd) {
  struct flock lock;
  memset(&lock, 0, sizeof(lock));
  lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
  if (fcntl(fd, F_GETLK, &lock) < 0) return OWNER_FAILED;
  if (lock.l_type == F_UNLCK) return OWNER_FREE;
  return lock.l_pid > 0 ? lock.l_pid : OWNER_HIDDEN;
}

/* These open without following a final symbolic link. The caller decides the
   returned descriptor's kind, owner and link count with fstat and closes it on
   refusal, so the refusal can name what it found. */
CAMLprim value masc_private_profile_open_directory(value path) {
  CAMLparam1(path);
  caml_unix_check_path(path, "private profile directory");
  int fd = open(String_val(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) caml_uerror("private profile directory", path);
  CAMLreturn(Val_int(fd));
}
static void check_child_name(value name) {
  const char *text = String_val(name);
  if (caml_string_length(name) != strlen(text) || strchr(text, '/') ||
      !strcmp(text, ".") || !strcmp(text, "..") || !*text) {
    errno = EINVAL; caml_uerror("private profile lock name", name);
  }
}
/* (device, inode) of a direct child, without following a symbolic link, or
   None when it does not exist. */
CAMLprim value masc_private_profile_stat_child(value directory, value name) {
  CAMLparam2(directory, name); CAMLlocal1(identity);
  check_child_name(name);
  struct stat info;
  if (fstatat(Int_val(directory), String_val(name), &info, AT_SYMLINK_NOFOLLOW) < 0) {
    if (errno == ENOENT) CAMLreturn(Val_none);
    caml_uerror("private profile lock fstatat", name);
  }
  identity = caml_alloc_tuple(2);
  Store_field(identity, 0, Val_long(info.st_dev));
  Store_field(identity, 1, Val_long(info.st_ino));
  CAMLreturn(caml_alloc_some(identity));
}
/* Opens or creates (mode 0600) a direct child read-write. */
CAMLprim value masc_private_profile_open_child(value directory, value name) {
  CAMLparam2(directory, name);
  check_child_name(name);
  int fd = openat(Int_val(directory), String_val(name),
    O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) caml_uerror("private profile lock openat", name);
  CAMLreturn(Val_int(fd));
}

/* Returns (code, holder): 0 captured, 1 no holder, 2 the holder ended or
   changed during capture, 3 unsupported platform, 4 unavailable, 5 held by a
   process this one cannot see. */
CAMLprim value masc_private_profile_capture(value lock) {
  CAMLparam1(lock); CAMLlocal2(raw, result);
  struct holder captured;
  memset(&captured, 0, sizeof(captured));
#ifdef __linux__
  captured.pidfd = -1;
#endif
  raw = caml_alloc_custom_mem(&operations, sizeof(struct holder), sizeof(struct holder));
  memcpy(Data_custom_val(raw), &captured, sizeof(captured));
  int fd = Int_val(lock), outcome = 4;
  caml_enter_blocking_section();
  pid_t pid = lock_owner(fd);
  if (pid == OWNER_FREE) outcome = 1;
  else if (pid == OWNER_HIDDEN) outcome = 5;
  else if (pid > 1 && pid != getpid()) {
#ifdef __APPLE__
    mach_port_t task = MACH_PORT_NULL;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_name_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS) {
      kern_return_t kr = task_info(task, TASK_AUDIT_TOKEN,
        (task_info_t)&captured.token, &count);
      mach_port_deallocate(mach_task_self(), task);
      if (kr == KERN_SUCCESS && count == TASK_AUDIT_TOKEN_COUNT) outcome = 0;
    }
#elif defined(__linux__) && defined(SYS_pidfd_open)
    captured.pidfd = syscall(SYS_pidfd_open, pid, 0);
    if (captured.pidfd >= 0) outcome = 0;
    else if (errno == ENOSYS) outcome = 3;
#else
    outcome = 3;
#endif
    /* A lock released or taken over during capture must not authorize a
       later signal, even if the numeric PID is reused; a holder that ended
       before its identity was read is the same case. */
    if ((outcome == 0 || outcome == 4) && lock_owner(fd) != pid) outcome = 2;
    if (outcome == 0) captured.pid = pid;
  }
  if (outcome != 0) release_holder(&captured);
  caml_leave_blocking_section();
  memcpy(Data_custom_val(raw), &captured, sizeof(captured));
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(outcome)); Store_field(result, 1, raw);
  CAMLreturn(result);
}

/* Checks through the caller's lock file descriptor that the captured process
   still holds the lock, then signals that process incarnation only.
   Returns 0 sent, 2 the holder changed, 3 unsupported platform, 4 failed. */
CAMLprim value masc_private_profile_signal(value raw, value lock, value kill) {
  CAMLparam3(raw, lock, kill);
  struct holder h;
  memcpy(&h, Data_custom_val(raw), sizeof(h));
  int fd = Int_val(lock), outcome = 4;
  int signal_number = Bool_val(kill) ? SIGKILL : SIGTERM;
  caml_enter_blocking_section();
  if (h.pid <= 1 || lock_owner(fd) != h.pid) outcome = 2;
  else {
#ifdef __APPLE__
    int err = proc_signal_with_audittoken(&h.token, signal_number);
    outcome = err == 0 ? 0 : (err == ESRCH ? 2 : 4);
#elif defined(__linux__) && defined(SYS_pidfd_send_signal)
    if (h.pidfd >= 0) {
      int rc = syscall(SYS_pidfd_send_signal, h.pidfd, signal_number, NULL, 0);
      outcome = rc == 0 ? 0 : (errno == ESRCH ? 2 : (errno == ENOSYS ? 3 : 4));
    }
#else
    outcome = 3;
#endif
  }
  caml_leave_blocking_section();
  CAMLreturn(Val_int(outcome));
}

/* True when two unreleased captures name the same process incarnation. */
CAMLprim value masc_private_profile_same(value left, value right) {
  CAMLparam2(left, right);
  struct holder a, b;
  memcpy(&a, Data_custom_val(left), sizeof(a));
  memcpy(&b, Data_custom_val(right), sizeof(b));
  int same = a.pid > 1 && a.pid == b.pid;
#ifdef __APPLE__
  same = same && memcmp(&a.token, &b.token, sizeof(a.token)) == 0;
#elif defined(__linux__) && defined(SYS_pidfd_send_signal)
  /* Two live processes never share a PID, and a pidfd answers ESRCH once its
     process has ended, so two live pidfds for one PID name one process. */
  same = same && a.pidfd >= 0 && b.pidfd >= 0
    && syscall(SYS_pidfd_send_signal, a.pidfd, 0, NULL, 0) == 0
    && syscall(SYS_pidfd_send_signal, b.pidfd, 0, NULL, 0) == 0;
#else
  same = 0;
#endif
  CAMLreturn(Val_bool(same));
}

CAMLprim value masc_private_profile_pid(value raw) {
  CAMLparam1(raw);
  struct holder h;
  memcpy(&h, Data_custom_val(raw), sizeof(h));
  CAMLreturn(Val_int(h.pid));
}

/* The executable path the kernel reports for the captured PID. It is read by
   PID after capture, so it is a record for people, not an identity. */
CAMLprim value masc_private_profile_executable(value raw) {
  CAMLparam1(raw); CAMLlocal1(path);
  struct holder h;
  memcpy(&h, Data_custom_val(raw), sizeof(h));
#ifdef __APPLE__
  char buffer[PROC_PIDPATHINFO_MAXSIZE];
  int length = h.pid > 1 ? proc_pidpath(h.pid, buffer, sizeof(buffer)) : 0;
  if (length <= 0) CAMLreturn(Val_none);
  path = caml_alloc_initialized_string(length, buffer);
  CAMLreturn(caml_alloc_some(path));
#elif defined(__linux__)
  char link[64], buffer[PATH_MAX];
  if (h.pid <= 1) CAMLreturn(Val_none);
  snprintf(link, sizeof(link), "/proc/%ld/exe", (long)h.pid);
  ssize_t length = readlink(link, buffer, sizeof(buffer));
  if (length <= 0) CAMLreturn(Val_none);
  path = caml_alloc_initialized_string(length, buffer);
  CAMLreturn(caml_alloc_some(path));
#else
  CAMLreturn(Val_none);
#endif
}

CAMLprim value masc_private_profile_release(value raw) {
  CAMLparam1(raw);
  release_holder(Data_custom_val(raw));
  CAMLreturn(Val_unit);
}

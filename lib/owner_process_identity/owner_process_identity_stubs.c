#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <libproc.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#endif
struct identity {
  int valid;
  int fd;
  int lease_fd;
  pid_t pid;
#ifdef __APPLE__
  audit_token_t token;
#endif
};
static void close_identity(value v) {
  struct identity *id = Data_custom_val(v);
  if (id->fd >= 0) close(id->fd);
  if (id->lease_fd >= 0) close(id->lease_fd);
  id->fd = -1; id->lease_fd = -1; id->valid = 0;
}
static struct custom_operations operations = {
  .identifier = "masc.owner_process_identity.v1",
  .finalize = close_identity,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default
};
static pid_t lease_owner(int fd) {
  struct flock lock;
  memset(&lock, 0, sizeof(lock));
  lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
  if (fcntl(fd, F_GETLK, &lock) < 0) return -1;
  return lock.l_type == F_UNLCK ? 0 : lock.l_pid;
}
CAMLprim value masc_owner_identity_capture(value lease) {
  CAMLparam1(lease); CAMLlocal2(raw, result);
  raw = caml_alloc_custom(&operations, sizeof(struct identity), 0, 1);
  struct identity initial;
  memset(&initial, 0, sizeof(initial)); initial.fd = -1; initial.lease_fd = -1;
  memcpy(Data_custom_val(raw), &initial, sizeof(initial));
  int fd = Int_val(lease), outcome = 4;
  struct identity captured = initial;
  caml_enter_blocking_section();
  pid_t pid = lease_owner(fd);
  if (pid == 0) outcome = 1;
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
    captured.fd = syscall(SYS_pidfd_open, pid, 0);
    if (captured.fd >= 0) outcome = 0;
    else if (errno == ENOSYS) outcome = 3;
#else
    outcome = 3;
#endif
    /* If the kernel lease was released/reassigned during capture, this handle
       must not authorize a later signal, even if the numeric PID was reused. */
    if (outcome == 0 && lease_owner(fd) != pid) outcome = 2;
  }
  if (outcome == 0) {
    captured.lease_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    captured.pid = pid;
    if (captured.lease_fd < 0) outcome = 4;
  }
  captured.valid = outcome == 0;
  if (!captured.valid && captured.fd >= 0) { close(captured.fd); captured.fd = -1; }
  caml_leave_blocking_section();
  memcpy(Data_custom_val(raw), &captured, sizeof(captured));
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(outcome)); Store_field(result, 1, raw);
  CAMLreturn(result);
}
CAMLprim value masc_owner_identity_terminate(value raw) {
  CAMLparam1(raw);
  struct identity id; memcpy(&id, Data_custom_val(raw), sizeof(id));
  int outcome = 4;
  if (id.valid) {
    caml_enter_blocking_section();
    if (lease_owner(id.lease_fd) != id.pid) outcome = 2;
    else {
#ifdef __APPLE__
    int err = proc_signal_with_audittoken(&id.token, SIGTERM);
    outcome = err == 0 ? 0 : (err == ESRCH ? 2 : 4);
#elif defined(__linux__) && defined(SYS_pidfd_send_signal)
    int rc = syscall(SYS_pidfd_send_signal, id.fd, SIGTERM, NULL, 0);
    outcome = rc == 0 ? 0 : (errno == ESRCH ? 2 : (errno == ENOSYS ? 3 : 4));
#else
    outcome = 3;
#endif
    }
    caml_leave_blocking_section();
  }
  CAMLreturn(Val_int(outcome));
}
CAMLprim value masc_owner_identity_close(value raw) {
  CAMLparam1(raw); close_identity(raw); CAMLreturn(Val_unit);
}

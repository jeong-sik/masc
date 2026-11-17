/* Test-only launcher: leave the real shim's pipe/fork/probe syscalls usable,
 * but make its Observe listener-transfer socketpair fail in the kernel.
 * No production implementation or error-injection hook is substituted. */
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__x86_64__)
#define FIXTURE_AUDIT_ARCH AUDIT_ARCH_X86_64
#else
#define FIXTURE_AUDIT_ARCH AUDIT_ARCH_AARCH64
#endif
#endif

CAMLprim value ocaml_test_deny_socketpair(value unsupported_family)
{
  CAMLparam1(unsupported_family);
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
  const unsigned int fault_errno = Bool_val(unsupported_family) ? EAFNOSUPPORT : EPERM;
  struct sock_filter instructions[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, FIXTURE_AUDIT_ARCH, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_socketpair, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | fault_errno),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
  };
  struct sock_fprog program = {
    .len = sizeof(instructions) / sizeof(instructions[0]),
    .filter = instructions
  };
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    caml_failwith("socketpair fixture: no_new_privs failed");
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0)
    caml_failwith("socketpair fixture: filter installation failed");

  /* Check the actual denial before exec rather than trusting installation. */
  int descriptors[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    caml_failwith("socketpair fixture: filter did not deny socketpair");
  }
  if (errno != (int)fault_errno)
    caml_failwith("socketpair fixture: wrong socketpair errno");
#else
  caml_failwith("socketpair fixture requires Linux x86_64 or aarch64");
#endif
  CAMLreturn(Val_unit);
}

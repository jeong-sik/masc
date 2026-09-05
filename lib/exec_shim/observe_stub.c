/* observe_stub.c — the box masc-exec-shim puts a payload in (RFC-0422).
 *
 * ocaml_shim_observe_support : unit -> int
 *   The Landlock ABI version this kernel enforces (>= 1), or 0 when the
 *   shim cannot box a payload here: no Landlock, no seccomp, or not Linux.
 *   Read-only: LANDLOCK_CREATE_RULESET_VERSION creates nothing.
 *
 * ocaml_shim_restrict_self : string -> bool -> bool -> unit
 *   restrict_self scratch deny_fs deny_net, called in the child between
 *   chdir and execvpe. Every step is a raw syscall the kernel enforces on
 *   this process and everything it execs; none needs privilege beyond
 *   no_new_privs, which is set first.
 *
 *   deny_fs: a Landlock ruleset handling every filesystem access right the
 *   running ABI knows. "/" is allowed EXECUTE | READ_FILE | READ_DIR only;
 *   [scratch] (when non-empty) is allowed everything the ruleset handles.
 *   So a write anywhere but the scratch fails with EACCES, and there is no
 *   path the payload can take to a write the ruleset does not see.
 *
 *   deny_net: a seccomp filter that answers socket(2) with EPERM for every
 *   address family. Landlock ABI 4 restricts TCP only and leaves UDP (DNS)
 *   open until ABI 10; refusing the socket itself closes both on any
 *   kernel with seccomp filtering. Foreign-architecture syscalls are
 *   killed, as every seccomp filter must.
 *
 *   Raises Unix.Unix_error naming the failing call. Non-Linux: raises
 *   ENOSYS, and the shim never gets here because support reads 0.
 *
 * Constants are spelled here rather than taken from <linux/landlock.h> and
 * <linux/seccomp.h>: the static musl build (scripts/build-shim-static.sh)
 * has no linux-headers, and these are stable kernel ABI values.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#ifdef __linux__
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#endif
#ifndef SYS_landlock_add_rule
#define SYS_landlock_add_rule 445
#endif
#ifndef SYS_landlock_restrict_self
#define SYS_landlock_restrict_self 446
#endif

#define LL_CREATE_RULESET_VERSION (1U << 0)
#define LL_RULE_PATH_BENEATH 1

#define LL_FS_EXECUTE     (1ULL << 0)
#define LL_FS_WRITE_FILE  (1ULL << 1)
#define LL_FS_READ_FILE   (1ULL << 2)
#define LL_FS_READ_DIR    (1ULL << 3)
#define LL_FS_REMOVE_DIR  (1ULL << 4)
#define LL_FS_REMOVE_FILE (1ULL << 5)
#define LL_FS_MAKE_CHAR   (1ULL << 6)
#define LL_FS_MAKE_DIR    (1ULL << 7)
#define LL_FS_MAKE_REG    (1ULL << 8)
#define LL_FS_MAKE_SOCK   (1ULL << 9)
#define LL_FS_MAKE_FIFO   (1ULL << 10)
#define LL_FS_MAKE_BLOCK  (1ULL << 11)
#define LL_FS_MAKE_SYM    (1ULL << 12)
#define LL_FS_REFER       (1ULL << 13)  /* ABI 2 */
#define LL_FS_TRUNCATE    (1ULL << 14)  /* ABI 3 */
#define LL_FS_IOCTL_DEV   (1ULL << 15)  /* ABI 5 */

struct ll_ruleset_attr_v1 {
  uint64_t handled_access_fs;
};

struct ll_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

/* seccomp: classic BPF over struct seccomp_data { int nr; __u32 arch; ... } */
struct shim_sock_filter {
  uint16_t code;
  uint8_t jt;
  uint8_t jf;
  uint32_t k;
};
struct shim_sock_fprog {
  unsigned short len;
  struct shim_sock_filter *filter;
};
#define BPF_LD_W_ABS 0x20
#define BPF_JMP_JEQ_K 0x15
#define BPF_RET_K 0x06
#define SECCOMP_RET_KILL_PROCESS 0x80000000U
#define SECCOMP_RET_ERRNO 0x00050000U
#define SECCOMP_RET_ALLOW 0x7fff0000U
#ifndef PR_SET_SECCOMP
#define PR_SET_SECCOMP 22
#endif
#ifndef PR_GET_SECCOMP
#define PR_GET_SECCOMP 21
#endif
#ifndef SECCOMP_MODE_FILTER
#define SECCOMP_MODE_FILTER 2
#endif
#if defined(__aarch64__)
#define SHIM_AUDIT_ARCH 0xC00000B7U
#elif defined(__x86_64__)
#define SHIM_AUDIT_ARCH 0xC000003EU
#else
#error "observe_stub: no AUDIT_ARCH for this architecture"
#endif

static long landlock_abi(void)
{
  return syscall(SYS_landlock_create_ruleset, NULL, 0, LL_CREATE_RULESET_VERSION);
}

static uint64_t handled_fs_for_abi(long abi)
{
  uint64_t handled =
    LL_FS_EXECUTE | LL_FS_WRITE_FILE | LL_FS_READ_FILE | LL_FS_READ_DIR
    | LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE | LL_FS_MAKE_CHAR | LL_FS_MAKE_DIR
    | LL_FS_MAKE_REG | LL_FS_MAKE_SOCK | LL_FS_MAKE_FIFO | LL_FS_MAKE_BLOCK
    | LL_FS_MAKE_SYM;
  if (abi >= 2) handled |= LL_FS_REFER;
  if (abi >= 3) handled |= LL_FS_TRUNCATE;
  if (abi >= 5) handled |= LL_FS_IOCTL_DEV;
  return handled;
}

static int add_path_rule(int ruleset_fd, const char *path, uint64_t allowed)
{
  struct ll_path_beneath_attr attr;
  int parent_fd = open(path, O_PATH | O_CLOEXEC);
  int rc;
  if (parent_fd < 0) return -1;
  attr.allowed_access = allowed;
  attr.parent_fd = parent_fd;
  rc = (int) syscall(SYS_landlock_add_rule, ruleset_fd, LL_RULE_PATH_BENEATH, &attr, 0);
  close(parent_fd);
  return rc;
}

static int deny_filesystem_writes(const char *scratch)
{
  long abi = landlock_abi();
  struct ll_ruleset_attr_v1 attr;
  int ruleset_fd;
  uint64_t handled;
  if (abi < 1) { errno = EOPNOTSUPP; return -1; }
  handled = handled_fs_for_abi(abi);
  attr.handled_access_fs = handled;
  ruleset_fd = (int) syscall(SYS_landlock_create_ruleset, &attr, sizeof attr, 0);
  if (ruleset_fd < 0) return -1;
  if (add_path_rule(ruleset_fd, "/", LL_FS_EXECUTE | LL_FS_READ_FILE | LL_FS_READ_DIR) != 0)
    goto fail;
  if (scratch[0] != '\0' && add_path_rule(ruleset_fd, scratch, handled) != 0)
    goto fail;
  if (syscall(SYS_landlock_restrict_self, ruleset_fd, 0) != 0)
    goto fail;
  close(ruleset_fd);
  return 0;
fail:
  { int saved = errno; close(ruleset_fd); errno = saved; }
  return -1;
}

static int deny_sockets(void)
{
  struct shim_sock_filter filter[] = {
    /* arch check first: a foreign ABI's syscall numbers mean nothing here */
    { BPF_LD_W_ABS, 0, 0, 4 },  /* seccomp_data.arch; nr is at 0 */
    { BPF_JMP_JEQ_K, 1, 0, SHIM_AUDIT_ARCH },
    { BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS },
    { BPF_LD_W_ABS, 0, 0, 0 },
    { BPF_JMP_JEQ_K, 0, 1, (uint32_t) SYS_socket },
    { BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO | (EPERM & 0xffff) },
    { BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW },
  };
  struct shim_sock_fprog prog = { sizeof filter / sizeof filter[0], filter };
  return (int) prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0);
}
#endif /* __linux__ */

CAMLprim value ocaml_shim_observe_support(value vunit)
{
  CAMLparam1(vunit);
#ifdef __linux__
  {
    long abi = landlock_abi();
    if (abi < 1) CAMLreturn(Val_int(0));
    if (prctl(PR_GET_SECCOMP, 0, 0, 0, 0) < 0) CAMLreturn(Val_int(0));
    CAMLreturn(Val_int((int) abi));
  }
#else
  CAMLreturn(Val_int(0));
#endif
}

CAMLprim value ocaml_shim_restrict_self(value vscratch, value vdeny_fs, value vdeny_net)
{
  CAMLparam3(vscratch, vdeny_fs, vdeny_net);
#ifdef __linux__
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    uerror("prctl(PR_SET_NO_NEW_PRIVS)", Nothing);
  if (Bool_val(vdeny_fs) && deny_filesystem_writes(String_val(vscratch)) != 0)
    uerror("landlock", Nothing);
  if (Bool_val(vdeny_net) && deny_sockets() != 0)
    uerror("prctl(PR_SET_SECCOMP)", Nothing);
  CAMLreturn(Val_unit);
#else
  (void) vdeny_fs; (void) vdeny_net;
  unix_error(ENOSYS, "restrict_self", Nothing);
  CAMLreturn(Val_unit);
#endif
}

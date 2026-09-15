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
 *   The verified /dev/null character device also permits read/write, so
 *   ordinary discard redirections work without granting persistent writes.
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
 * ocaml_shim_user_notif_supported : unit -> bool
 *   Whether this kernel accepts SECCOMP_FILTER_FLAG_NEW_LISTENER (Linux
 *   >= 5.0): the flag [deny_sockets] would need to hand the supervisor a
 *   listener fd instead of answering socket(2) with EPERM straight out of
 *   the filter, so a refused observe can carry evidence of the attempt
 *   itself rather than only "the box applied" (task-1568, PR #36032
 *   review 5192723206). A capability probe only: it forks a throwaway
 *   child that tries to install an allow-all listener filter and reports
 *   whether the kernel accepted it, then exits without running a payload.
 *   The calling thread's own seccomp state is untouched either way — a
 *   filter, once installed on a thread, can only add restrictions, so this
 *   can never be probed in-process without side effects that outlive the
 *   probe. Nothing in this PR wires the fd this reports back to the
 *   parent yet: doing that needs SCM_RIGHTS across the existing boundary
 *   pipe (a plain pipe cannot carry a file descriptor), which is deferred
 *   to the PR that also adds the supervisor's read/decode/respond loop.
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
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <sys/wait.h>

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
#ifndef SYS_seccomp
#if defined(__aarch64__)
#define SYS_seccomp 277
#elif defined(__x86_64__)
#define SYS_seccomp 317
#else
#error "observe_stub: no SYS_seccomp for this architecture"
#endif
#endif
#define SECCOMP_SET_MODE_FILTER 1U
#define SECCOMP_FILTER_FLAG_NEW_LISTENER (1U << 3)
#define SECCOMP_RET_USER_NOTIF 0x7fc00000U
#define SECCOMP_USER_NOTIF_FLAG_CONTINUE (1UL << 0)

/* seccomp user-notif ABI, mirrored from include/uapi/linux/seccomp.h:
   native-endian structs at natural alignment (notif 80 bytes, notif_resp 24
   on both supported architectures). */
struct shim_seccomp_data {
  int32_t nr;
  uint32_t arch;
  uint64_t instruction_pointer;
  uint64_t args[6];
};
struct shim_seccomp_notif {
  uint64_t id;
  uint32_t pid;
  uint32_t flags;
  struct shim_seccomp_data data;
};
struct shim_seccomp_notif_resp {
  uint64_t id;
  int64_t val;
  int32_t error;
  uint32_t flags;
};

/* _IOWR from <asm-generic/ioctl.h>, spelled out because the static musl
   build has no linux-headers: dir<<30 | size<<16 | type<<8 | nr. */
#define SHIM_IOC_DIRSHIFT 30
#define SHIM_IOC_SIZESHIFT 16
#define SHIM_IOC_TYPESHIFT 8
#define SHIM_IOC_NRSHIFT 0
#define SHIM_IOC_READ 2U
#define SHIM_IOC_WRITE 1U
#define SHIM_IOWR(type, nr, size)                                          \
  ((((uint32_t) SHIM_IOC_READ | SHIM_IOC_WRITE) << SHIM_IOC_DIRSHIFT)       \
   | ((uint32_t) (size) << SHIM_IOC_SIZESHIFT)                             \
   | ((uint32_t) (type) << SHIM_IOC_TYPESHIFT)                             \
   | ((uint32_t) (nr) << SHIM_IOC_NRSHIFT))
#define SECCOMP_IOCTL_NOTIF_RECV SHIM_IOWR('!', 0, sizeof(struct shim_seccomp_notif))
#define SECCOMP_IOCTL_NOTIF_SEND SHIM_IOWR('!', 1, sizeof(struct shim_seccomp_notif_resp))
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

static int add_discard_device_rule(int ruleset_fd)
{
  struct stat status;
  struct ll_path_beneath_attr attr;
  int device_fd = open("/dev/null", O_PATH | O_NOFOLLOW | O_CLOEXEC);
  int rc, saved;
  if (device_fd < 0) return -1;
  if (fstat(device_fd, &status) != 0) goto fail;
  /* Linux's device registry defines /dev/null as character major 1, minor 3:
   * Documentation/admin-guide/devices.txt. O_PATH|O_NOFOLLOW plus fstat
   * rejects symlinks, regular-file replacements and other character devices.
   * Bind the rule to this same fd, never a second path lookup. */
  if (!S_ISCHR(status.st_mode) || status.st_rdev != makedev(1, 3)) {
    errno = ENODEV;
    goto fail;
  }
  attr.allowed_access = LL_FS_READ_FILE | LL_FS_WRITE_FILE;
  attr.parent_fd = device_fd;
  rc = (int) syscall(SYS_landlock_add_rule, ruleset_fd, LL_RULE_PATH_BENEATH, &attr, 0);
  saved = errno;
  close(device_fd);
  errno = saved;
  return rc;
fail:
  saved = errno;
  close(device_fd);
  errno = saved;
  return -1;
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
  if (add_discard_device_rule(ruleset_fd) != 0)
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

/* Runs only in the throwaway child forked by user_notif_supported below.
   An allow-all filter: the probe cares whether the kernel accepts the
   NEW_LISTENER flag at all, not about filtering anything, and the child
   never runs a payload past this point. Exits 0 when the kernel handed
   back a listener fd, 1 otherwise (old kernel, or a seccomp policy that
   refuses the syscall outright).  no_new_privs is set first: without it
   SECCOMP_SET_MODE_FILTER reads EACCES on an unprivileged kernel that
   would otherwise accept the listener. */
static int probe_user_notif_child(void)
{
  struct shim_sock_filter filter[] = {
    { BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW },
  };
  struct shim_sock_fprog prog = { sizeof filter / sizeof filter[0], filter };
  long fd;
  /* SECCOMP_SET_MODE_FILTER is allowed with CAP_SYS_ADMIN *or* the
     no_new_privs bit; the unprivileged case is the one that matters, and
     without this the probe reads EACCES on a kernel that would accept the
     listener. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return 1;
  fd = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
               (unsigned long) SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog);
  if (fd < 0) return 1;
  close((int) fd);
  return 0;
}

static int user_notif_supported(void)
{
  pid_t pid = fork();
  if (pid < 0) return 0;
  if (pid == 0) _exit(probe_user_notif_child());
  {
    int status;
    pid_t waited;
    do { waited = waitpid(pid, &status, 0); }
    while (waited < 0 && errno == EINTR);
    if (waited != pid) return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
  }
}

/* SCM_RIGHTS send usable from the forked exec child, where no OCaml
   runtime call is safe between fork and execvpe. Mirrors the OCaml-side
   primitive in fdpass_stub.c (shim_fdpass), which stays the parent-side
   receive path; the ten duplicated lines buy a child that only ever runs
   raw syscalls (task-1571). */
static int send_fd_raw(int sock, int fd)
{
  char payload = 'F';
  struct iovec iov;
  struct msghdr msg;
  char control[CMSG_SPACE(sizeof(int))];
  struct cmsghdr *cmsg;
  ssize_t sent;
  iov.iov_base = &payload;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  memset(control, 0, sizeof(control));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = control;
  msg.msg_controllen = sizeof(control);
  cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
  do { sent = sendmsg(sock, &msg, 0); } while (sent < 0 && errno == EINTR);
  return sent < 0 ? -1 : 0;
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

CAMLprim value ocaml_shim_user_notif_supported(value vunit)
{
  CAMLparam1(vunit);
#ifdef __linux__
  CAMLreturn(Val_bool(user_notif_supported()));
#else
  CAMLreturn(Val_bool(0));
#endif
}

/* --- task-1571: the observation filter and the supervisor drain --------- */

/* The observe variant of deny_sockets: socket(2) is answered by the
   supervisor (SECCOMP_RET_USER_NOTIF) instead of the filter itself, so
   the supervisor can record the attempt and then answer EPERM.  The
   child calls this through install_user_notif below, which hands the
   listener fd back across [sock] before execvpe. */
static int install_observe_sockets(int sock)
{
  struct shim_sock_filter filter[] = {
    { BPF_LD_W_ABS, 0, 0, 4 },
    { BPF_JMP_JEQ_K, 1, 0, SHIM_AUDIT_ARCH },
    { BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS },
    { BPF_LD_W_ABS, 0, 0, 0 },
    { BPF_JMP_JEQ_K, 0, 1, (uint32_t) SYS_socket },
    { BPF_RET_K, 0, 0, SECCOMP_RET_USER_NOTIF },
    { BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW },
  };
  struct shim_sock_fprog prog = { sizeof filter / sizeof filter[0], filter };
  long fd;
  int rc;

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
  fd = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
               (unsigned long) SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog);
  if (fd < 0) return -1;
  rc = send_fd_raw(sock, (int) fd);
  {
    int saved = errno;
    close((int) fd);
    errno = saved;
  }
  return rc;
}

/* Child-side entry: install the observe filter and hand the listener fd to
   the shim over [sock].  Returns true when the filter applied and the fd
   was sent.  Runs in the forked exec child, so it touches no OCaml runtime
   state beyond the argument. */
CAMLprim value ocaml_shim_observe_install(value vsock)
{
  CAMLparam1(vsock);
#ifdef __linux__
  CAMLreturn(Val_bool(install_observe_sockets(Int_val(vsock)) == 0));
#else
  CAMLreturn(Val_bool(0));
#endif
}

/* The shim's drain loop: one RECV per recorded attempt, answer EPERM,
   return how many were seen.  Poll-free for now: the payload makes at
   most a handful of socket attempts and this is called after it exits —
   a blocking select gate comes with the live-payload wiring. */
CAMLprim value ocaml_shim_user_notif_drain(value vlistener)
{
  CAMLparam1(vlistener);
  int fd = Int_val(vlistener);
  int seen = 0;
  for (;;) {
    struct shim_seccomp_notif req;
    struct shim_seccomp_notif_resp resp;
    memset(&req, 0, sizeof(req));
    if (ioctl(fd, SECCOMP_IOCTL_NOTIF_RECV, &req) != 0) break;
    memset(&resp, 0, sizeof(resp));
    resp.id = req.id;
    resp.error = -EPERM;
    resp.flags = 0;
    if (ioctl(fd, SECCOMP_IOCTL_NOTIF_SEND, &resp) != 0) break;
    seen++;
    /* No magic ceiling: RECV returning EAGAIN (non-blocking listener) or
       ENOTCONN (child gone) ends the loop. */
  }
  CAMLreturn(Val_int(seen));
}

/* Applies the box and reports which rule refused the setup, so the refusal
   can travel typed instead of being guessed back out of stderr. Returns 0
   when every requested rule applied, or -1 with *rule set to the refusing
   rule's tag ("socket" for the seccomp filter, "write" for the Landlock
   ruleset, "" when no rule was reached). */
CAMLprim value ocaml_shim_restrict_self(value vscratch, value vdeny_fs,
                                        value vdeny_net, value vrule_out)
{
  CAMLparam4(vscratch, vdeny_fs, vdeny_net, vrule_out);
  const char *refusing_rule = "";
#ifdef __linux__
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    refusing_rule = "";
    goto report;
  }
  if (Bool_val(vdeny_fs) && deny_filesystem_writes(String_val(vscratch)) != 0) {
    refusing_rule = "write";
    goto report;
  }
  if (Bool_val(vdeny_net) && deny_sockets() != 0) {
    refusing_rule = "socket";
    goto report;
  }
  CAMLreturn(Val_int(0));
report:
  {
    size_t len = strlen(refusing_rule);
    memcpy((char *)String_val(vrule_out), refusing_rule, len);
    memset((char *)String_val(vrule_out) + len, 0, 1);
  }
  CAMLreturn(Val_int(-1));
#else
  /* No goto reaches [report] here, so the label and the string calls it
     makes live with the branch that jumps to it: outside the guard they
     needed <string.h>, which is included for Linux only, and the label was
     one clang reads as unused. */
  (void) refusing_rule; (void) vdeny_fs; (void) vdeny_net;
  unix_error(ENOSYS, "restrict_self", Nothing);
  CAMLreturn(Val_unit);
#endif
}

/* One iteration of the supervisor drain (task-1575 phase 3 wiring).
   Returns the syscall number from the next pending notification, replies
   EPERM, and reports the send status to the caller through [vno_send]:
   0 when the reply was delivered, errno when ioctl failed.  Single-call
   drain so the cap on outstanding notifications moves to the OCaml loop
   (reviewer concern: drain until EAGAIN, not a magic ceiling). */
CAMLprim value ocaml_shim_user_notif_drain_one(value vlistener, value vno_send)
{
  CAMLparam2(vlistener, vno_send);
#ifdef __linux__
  int fd = Int_val(vlistener);
  struct shim_seccomp_notif req;
  struct shim_seccomp_notif_resp resp;
  memset(&req, 0, sizeof(req));
  if (ioctl(fd, SECCOMP_IOCTL_NOTIF_RECV, &req) != 0)
  {
    int e = errno;
    Store_field(vno_send, 0, Val_int(e));
    /* -2: queue empty (EAGAIN) — the caller keeps observing. -1: the
       child is gone (ENOTCONN/EBADF) — the caller stops. */
    CAMLreturn(Val_int((e == EAGAIN || e == EWOULDBLOCK) ? -2 : -1));
  }
  memset(&resp, 0, sizeof(resp));
  resp.id = req.id;
  resp.error = -EPERM;
  resp.flags = 0;
  if (ioctl(fd, SECCOMP_IOCTL_NOTIF_SEND, &resp) != 0)
  {
    Store_field(vno_send, 0, Val_int(errno));
    CAMLreturn(Val_int(-1));
  }
  Store_field(vno_send, 0, Val_int(0));
  CAMLreturn(Val_int((int) req.data.nr));
#else
  Store_field(vno_send, 0, Val_int(ENOSYS));
  CAMLreturn(Val_int(-1));
#endif
}

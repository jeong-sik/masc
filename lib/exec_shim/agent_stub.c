/* agent_stub.c -- the privileged start of the masc-exec-shim guest agent
 * (RFC microvm-guest-agent-over-socket, section 3.2) and the facts its hello
 * reports.
 *
 * ocaml_shim_agent_remount_root_read_only : unit -> unit
 *   mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY | kept, NULL), where kept
 *   are the nosuid/nodev/noexec/atime flags "/" already has. A remount sets
 *   the mount's flags to the ones passed, so passing them keeps them.
 *   Raises Unix_error.
 *
 * ocaml_shim_agent_drop_privileges : int -> int -> unit
 *   setgroups(0, NULL), setgid(gid), setuid(uid); reads the real, effective
 *   and saved ids back and checks every one is the target; checks setuid(0)
 *   now fails; sets no_new_privs and clears dumpable. Raises Unix_error or
 *   Failure naming the step that did not hold. The order is the one CERT
 *   POS36-C gives: groups before the uid, because a process that has given
 *   up root can no longer change its groups.
 *
 * ocaml_shim_agent_root_read_only : unit -> bool
 *   statvfs("/") reports ST_RDONLY. Raises Unix_error.
 *
 * ocaml_shim_agent_no_new_privs : unit -> bool
 *   prctl(PR_GET_NO_NEW_PRIVS) is 1. Raises Unix_error.
 *
 * ocaml_shim_agent_cloexec_inherited : unit -> unit
 *   Marks every descriptor above 2 close-on-exec: close_range(3, ~0U,
 *   CLOSE_RANGE_CLOEXEC) where the kernel has it (Linux 5.11), otherwise
 *   fcntl on each descriptor below the open-files limit. A descriptor the VM
 *   runtime left open in the first process then never reaches a relay's
 *   shim or its payload. Raises Unix_error.
 *
 * Off Linux the two actions raise Unix_error(ENOSYS) and no_new_privs is
 * false: the agent runs only as a Linux guest's first process, and the same
 * source has to build on macOS for development.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <sys/statvfs.h>

#include <fcntl.h>
#include <unistd.h>

#ifdef __linux__
#include <grp.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>

/* The same number on every architecture (the unified syscall table), as the
   io_uring numbers in observe_stub.c; a C library too old to name it still
   reaches it. */
#ifndef SYS_close_range
#define SYS_close_range 436
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif
#endif

#ifdef __linux__
/* statvfs reports the flags as ST_*; mount takes them as MS_*. Mapped one
   by one rather than relying on the two sets sharing bit values. */
static unsigned long kept_mount_flags(unsigned long st_flags)
{
  unsigned long flags = 0;
  if (st_flags & ST_NOSUID) flags |= MS_NOSUID;
  if (st_flags & ST_NODEV) flags |= MS_NODEV;
  if (st_flags & ST_NOEXEC) flags |= MS_NOEXEC;
  if (st_flags & ST_NOATIME) flags |= MS_NOATIME;
  if (st_flags & ST_NODIRATIME) flags |= MS_NODIRATIME;
  if (st_flags & ST_RELATIME) flags |= MS_RELATIME;
  return flags;
}
#endif

CAMLprim value ocaml_shim_agent_remount_root_read_only(value vunit)
{
  CAMLparam1(vunit);
#ifdef __linux__
  struct statvfs root;
  if (statvfs("/", &root) != 0) caml_uerror("statvfs", Nothing);
  if (mount(NULL, "/", NULL,
            MS_REMOUNT | MS_RDONLY | kept_mount_flags(root.f_flag), NULL) != 0)
    caml_uerror("mount(MS_REMOUNT | MS_RDONLY)", Nothing);
#else
  caml_unix_error(ENOSYS, "mount(MS_REMOUNT | MS_RDONLY)", Nothing);
#endif
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_shim_agent_drop_privileges(value vuid, value vgid)
{
  CAMLparam2(vuid, vgid);
#ifdef __linux__
  uid_t uid = (uid_t)Long_val(vuid);
  gid_t gid = (gid_t)Long_val(vgid);
  uid_t ruid, euid, suid;
  gid_t rgid, egid, sgid;
  if (setgroups(0, NULL) != 0) caml_uerror("setgroups", Nothing);
  if (setgid(gid) != 0) caml_uerror("setgid", Nothing);
  if (setuid(uid) != 0) caml_uerror("setuid", Nothing);
  if (getresuid(&ruid, &euid, &suid) != 0) caml_uerror("getresuid", Nothing);
  if (getresgid(&rgid, &egid, &sgid) != 0) caml_uerror("getresgid", Nothing);
  if (ruid != uid || euid != uid || suid != uid)
    caml_failwith("drop_privileges: a real, effective or saved uid is not the target");
  if (rgid != gid || egid != gid || sgid != gid)
    caml_failwith("drop_privileges: a real, effective or saved gid is not the target");
  if (setuid(0) == 0)
    caml_failwith("drop_privileges: setuid(0) succeeded after the drop");
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    caml_uerror("prctl(PR_SET_NO_NEW_PRIVS)", Nothing);
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0)
    caml_uerror("prctl(PR_SET_DUMPABLE)", Nothing);
#else
  (void)vuid;
  (void)vgid;
  caml_unix_error(ENOSYS, "drop_privileges", Nothing);
#endif
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_shim_agent_root_read_only(value vunit)
{
  CAMLparam1(vunit);
  struct statvfs root;
  if (statvfs("/", &root) != 0) caml_uerror("statvfs", Nothing);
  CAMLreturn(Val_bool((root.f_flag & ST_RDONLY) != 0));
}

CAMLprim value ocaml_shim_agent_no_new_privs(value vunit)
{
  CAMLparam1(vunit);
#ifdef __linux__
  int state = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
  if (state < 0) caml_uerror("prctl(PR_GET_NO_NEW_PRIVS)", Nothing);
  CAMLreturn(Val_bool(state == 1));
#else
  CAMLreturn(Val_false);
#endif
}

CAMLprim value ocaml_shim_agent_cloexec_inherited(value vunit)
{
  CAMLparam1(vunit);
  long limit;
  int fd;
#ifdef __linux__
  if (syscall(SYS_close_range, 3U, ~0U, CLOSE_RANGE_CLOEXEC) == 0) CAMLreturn(Val_unit);
  /* ENOSYS: a kernel before close_range; EINVAL: one before its CLOEXEC flag. */
  if (errno != ENOSYS && errno != EINVAL) caml_uerror("close_range", Nothing);
#endif
  limit = sysconf(_SC_OPEN_MAX);
  if (limit < 0) limit = getdtablesize();
  for (fd = 3; fd < limit; fd++) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) continue; /* EBADF: not open */
    if ((flags & FD_CLOEXEC) == 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0)
      caml_uerror("fcntl(F_SETFD, FD_CLOEXEC)", Nothing);
  }
  CAMLreturn(Val_unit);
}

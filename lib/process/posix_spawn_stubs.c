/* posix_spawn(2) for masc's process manager.

   eio_posix spawns children with fork(): the parent runs every atfork
   handler, and on macOS libmalloc's handler locks each malloc zone
   (_malloc_fork_parent -> _xzm_foreach_lock). In a process with a 1-2 GB
   heap that lock held the main domain for about 141 ms per spawn
   (2026-09-05 stack samples, RFC main-domain-scheduler-latency §8.8).
   posix_spawn is a system call on macOS and a clone-based path in glibc;
   neither runs atfork handlers.

   The stub takes everything as plain C data before releasing the runtime
   lock, so no OCaml value is touched while other domains run. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* posix_spawn_file_actions_addclosefrom_np landed in glibc 2.34. It is the
   only descriptor-closing mechanism on the platforms that lack
   POSIX_SPAWN_CLOEXEC_DEFAULT and that this stub is built for: CI and the
   deployed server are glibc Linux, development is macOS. The musl target in
   this repo is the exec shim, which links exec_ssh_protocol and unix and
   never compiles this file. */
#if defined(__GLIBC__) \
  && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 34))
#define MASC_HAVE_ADDCLOSEFROM 1
#else
#define MASC_HAVE_ADDCLOSEFROM 0
#endif

extern char **environ;

/* posix_spawn_file_actions_addchdir_np is the portable spelling: glibc >= 2.29
   and macOS >= 10.15 both have it; macOS 14 marks it deprecated in favour of
   the POSIX name, which glibc lacks. */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif

static char **strings_of_array(value v_array)
{
  mlsize_t n = Wosize_val(v_array);
  char **out = caml_stat_alloc((n + 1) * sizeof(char *));
  for (mlsize_t i = 0; i < n; i++) {
    out[i] = caml_stat_strdup(String_val(Field(v_array, i)));
  }
  out[n] = NULL;
  return out;
}

static void free_strings(char **strings)
{
  for (char **p = strings; *p != NULL; p++) caml_stat_free(*p);
  caml_stat_free(strings);
}

/* masc_posix_spawn executable argv env cwd_opt fds
   fds: (child_fd, parent_fd) list. Equal fds are inherited in place;
   others are dup2'd. Every other descriptor is closed in the child.

   exec closes only what is marked close-on-exec, so neither fork+exec nor
   posix_spawn closes a stray descriptor on its own -- measured 2026-09-07,
   eio_posix's own fork-based manager hands its child a raw Unix.pipe () and
   this one does not. What makes the difference is asked for explicitly, one
   mechanism per platform:

     macOS  POSIX_SPAWN_CLOEXEC_DEFAULT -- the kernel closes everything not
            named by an addinherit_np.
     glibc  posix_spawn_file_actions_addclosefrom_np (2.34+) plus an
            explicit close of anything below it that is not a dup2 target.

   The glibc line used to read "masc opens its descriptors close-on-exec",
   which made the guarantee a whole-process invariant that nothing enforces
   and any new Unix.pipe () silently breaks -- OCaml's ?cloexec defaults to
   false, and lib/exec_shim and bin/main_eio each open pipes that way.

   Measured 2026-09-07 on glibc 2.39: with a second child spawned while an
   unrelated pipe was open, that child inherited the pipe's write end, and
   the pipe's reader never saw EOF after its own child exited. With
   addclosefrom_np the EOF arrived. That is the shape the nightly lane hangs
   in -- four suites past the 90-minute deadline, each holding a defunct
   child (run 34049510985, issue #33782).

   macOS never showed it because its mechanism is enforced by the kernel,
   which is also why development does not see what CI does. This is not a
   parity fix: it makes the glibc branch as strict as the macOS one, and
   both stricter than the eio manager they otherwise match.

   Returns the child's pid or raises Unix.Unix_error with the errno
   posix_spawn reported. */
CAMLprim value masc_posix_spawn(value v_executable, value v_argv, value v_env,
                                value v_cwd, value v_fds)
{
  CAMLparam5(v_executable, v_argv, v_env, v_cwd, v_fds);
  char *executable = caml_stat_strdup(String_val(v_executable));
  char **argv = strings_of_array(v_argv);
  char **env = strings_of_array(v_env);
  char *cwd = Is_some(v_cwd) ? caml_stat_strdup(String_val(Some_val(v_cwd))) : NULL;

  int fd_count = 0;
  for (value l = v_fds; l != Val_emptylist; l = Field(l, 1)) fd_count++;
  int *child_fds = caml_stat_alloc((fd_count + 1) * sizeof(int));
  int *parent_fds = caml_stat_alloc((fd_count + 1) * sizeof(int));
  int i = 0;
  for (value l = v_fds; l != Val_emptylist; l = Field(l, 1), i++) {
    value pair = Field(l, 0);
    child_fds[i] = Int_val(Field(pair, 0));
    parent_fds[i] = Int_val(Field(pair, 1));
  }

  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  int rc = posix_spawn_file_actions_init(&actions);
  if (rc == 0) rc = posix_spawnattr_init(&attr);
  if (rc == 0) {
    short flags = POSIX_SPAWN_SETSIGMASK;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    sigset_t empty;
    sigemptyset(&empty);
    rc = posix_spawnattr_setsigmask(&attr, &empty);
    if (rc == 0) rc = posix_spawnattr_setflags(&attr, flags);
  }
  if (rc == 0 && cwd != NULL) rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
  for (int j = 0; rc == 0 && j < fd_count; j++) {
    if (child_fds[j] == parent_fds[j]) {
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
      rc = posix_spawn_file_actions_addinherit_np(&actions, child_fds[j]);
#else
      rc = posix_spawn_file_actions_adddup2(&actions, parent_fds[j], child_fds[j]);
#endif
    } else {
      rc = posix_spawn_file_actions_adddup2(&actions, parent_fds[j], child_fds[j]);
    }
  }

#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#if MASC_HAVE_ADDCLOSEFROM
  /* After every dup2, never before: a parent descriptor can be the source of
     a dup2 that has not run yet, and closing it early would break it. Once
     they have run the child holds its own copies, so closing the originals
     is both safe and the point.

     addclosefrom_np closes from lowfd up, so lowfd has to clear the highest
     target. Anything below that which is not itself a target is closed one
     by one; glibc does not fail the spawn when such a descriptor was not
     open (measured 2026-09-07), so this needs no test for that. Today every
     caller passes 0/1/2 and the loop finds nothing, but a caller that
     passes a sparse set gets the same guarantee instead of a quiet gap. */
  if (rc == 0) {
    int lowfd = 0;
    for (int j = 0; j < fd_count; j++) {
      if (child_fds[j] >= lowfd) lowfd = child_fds[j] + 1;
    }
    for (int fd = 0; rc == 0 && fd < lowfd; fd++) {
      int is_target = 0;
      for (int j = 0; j < fd_count; j++) {
        if (child_fds[j] == fd) { is_target = 1; break; }
      }
      if (!is_target) rc = posix_spawn_file_actions_addclose(&actions, fd);
    }
    if (rc == 0) rc = posix_spawn_file_actions_addclosefrom_np(&actions, lowfd);
  }
#else
#warning "no posix_spawn descriptor-closing mechanism: children inherit every non-CLOEXEC descriptor"
#endif
#endif

  pid_t pid = 0;
  if (rc == 0) {
    caml_enter_blocking_section();
    rc = posix_spawn(&pid, executable, &actions, &attr, argv, env);
    caml_leave_blocking_section();
  }
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  free_strings(argv);
  free_strings(env);
  caml_stat_free(child_fds);
  caml_stat_free(parent_fds);
  if (cwd != NULL) caml_stat_free(cwd);

  if (rc != 0) {
    caml_stat_free(executable);
    errno = rc;
    uerror("posix_spawn", v_executable);
  }
  caml_stat_free(executable);
  CAMLreturn(Val_int(pid));
}

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/* _POSIX_C_SOURCE alone hides the BSD extensions on Apple platforms, so
   POSIX_SPAWN_SETSID and posix_spawn_file_actions_addchdir_np disappear from
   <spawn.h> and the guards below fire.  glibc re-exposes them through
   _GNU_SOURCE, which is why Linux CI never saw this. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#if !defined(POSIX_SPAWN_SETPGROUP)
#error "posix_spawn detached requires POSIX_SPAWN_SETPGROUP"
#endif

/* Spawn a detached child via posix_spawn with POSIX_SPAWN_SETPGROUP so the
   process group is established atomically during spawn — before the child
   runs any user code.  This removes the fork/setpgrp signal-race window that
   the previous fork()+setsid() implementation left open.

   Note: POSIX_SPAWN_SETSID is deliberately NOT used.  macOS's posix_spawn
   does not support it and returns EPERM when it is set; the task's core
   requirement is a signal-race-free process group, which POSIX_SPAWN_SETPGROUP
   alone provides.  The child becomes a process-group leader in its own group
   (pgroup 0 => pgid = pid), which is sufficient for tree-kill semantics.

   argv and env are OCaml string arrays; cwd is a string (empty means "do not
   chdir").  fds is a 3-element array of parent-side descriptors
   [stdin; stdout; stderr] that are dup2'd onto 0/1/2 in the child via file
   actions.

   Returns the child pid, or raises Unix_error on failure (no child is left
   running on failure). */
CAMLprim value
caml_masc_process_posix_spawn_detached(
    value v_argv, value v_env, value v_cwd, value v_fds)
{
  CAMLparam4(v_argv, v_env, v_cwd, v_fds);
  CAMLlocal1(v_s);

  mlsize_t argc = Wosize_val(v_argv);
  mlsize_t envc = Wosize_val(v_env);

  char **argv = caml_stat_alloc((argc + 1) * sizeof(char *));
  char **envp = caml_stat_alloc((envc + 1) * sizeof(char *));
  char *cwd = caml_stat_strdup(String_val(v_cwd));

  int stdin_fd = Int_val(Field(v_fds, 0));
  int stdout_fd = Int_val(Field(v_fds, 1));
  int stderr_fd = Int_val(Field(v_fds, 2));

  mlsize_t i;
  for (i = 0; i < argc; i++) {
    v_s = Field(v_argv, i);
    argv[i] = caml_stat_strdup(String_val(v_s));
  }
  argv[argc] = NULL;

  for (i = 0; i < envc; i++) {
    v_s = Field(v_env, i);
    envp[i] = caml_stat_strdup(String_val(v_s));
  }
  envp[envc] = NULL;

  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  pid_t pid;
  int err = 0;

  err = posix_spawn_file_actions_init(&actions);
  if (err == 0) {
    err = posix_spawnattr_init(&attr);
  }
  if (err == 0) {
    err = posix_spawn_file_actions_adddup2(&actions, stdin_fd, 0);
  }
  if (err == 0) {
    err = posix_spawn_file_actions_adddup2(&actions, stdout_fd, 1);
  }
  if (err == 0) {
    err = posix_spawn_file_actions_adddup2(&actions, stderr_fd, 2);
  }
  if (err == 0 && cwd[0] != '\0') {
#if defined(__APPLE__)
    /* macOS 26 deprecates the _np variant in favour of the standard
       posix_spawn_file_actions_addchdir (available since macOS 10.15).
       Use the non-deprecated name on Apple platforms. */
    err = posix_spawn_file_actions_addchdir(&actions, cwd);
#else
    err = posix_spawn_file_actions_addchdir_np(&actions, cwd);
#endif
  }
  if (err == 0) {
    short flags = POSIX_SPAWN_SETPGROUP;
    err = posix_spawnattr_setflags(&attr, flags);
  }
  if (err == 0) {
    /* pgroup 0 => child's process group is its own pid. */
    err = posix_spawnattr_setpgroup(&attr, 0);
  }

  if (err == 0) {
    caml_enter_blocking_section();
    err = posix_spawn(&pid, argv[0], &actions, &attr, argv, envp);
    caml_leave_blocking_section();
  }

  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);

  for (i = 0; i < argc; i++) {
    caml_stat_free(argv[i]);
  }
  for (i = 0; i < envc; i++) {
    caml_stat_free(envp[i]);
  }
  caml_stat_free(argv);
  caml_stat_free(envp);
  caml_stat_free(cwd);

  if (err != 0) {
    /* posix_spawn reports errors via its return value, not errno. */
    errno = err;
    uerror("posix_spawn", v_argv);
  }

  CAMLreturn(Val_int(pid));
}

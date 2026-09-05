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
   others are dup2'd. Every other descriptor is closed in the child
   (POSIX_SPAWN_CLOEXEC_DEFAULT on macOS; elsewhere masc opens its
   descriptors close-on-exec). Returns the child's pid or raises
   Unix.Unix_error with the errno posix_spawn reported. */
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

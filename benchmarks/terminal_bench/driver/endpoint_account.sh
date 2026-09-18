# shellcheck shell=bash
# The account a keeper's commands run as: the task image's own user.
#
# harbor's agents run their commands through exec_as_agent, which passes no
# user to `docker exec` when the task names none. No 4.0.0 task.toml names one,
# so they run as the image's USER: agent in terminal-bench/rs-archive-clone,
# nobody in risk-scorer-replay, root in most. PID 1 runs as that same user.
#
# The keeper's remote_ssh endpoint still logs in as root, since an account such
# as nobody has no login shell. The command it runs, masc-exec-shim, is a
# wrapper that starts the release binary through setpriv with PID 1's uid and
# gid, so the shim and every payload run as the image's user. setpriv grants
# nothing here; it only gives up root's uid and gid.
#
# The keeper's directory, <remote_root>/<name>, belongs to that user, because
# /root is closed to any other account.

# Where keepers work: the endpoint's remote_root (configs/render_configs.py
# REMOTE_ROOT, compared in tests/test_endpoint_account.py).
BENCH_REMOTE_ROOT=/opt/masc-bench/remote
# The release binary, off PATH, and the wrapper the endpoint runs by name
# (keeper_sandbox_remote.ml shim_command).
BENCH_SHIM_BINARY=/usr/local/libexec/masc-exec-shim
BENCH_SHIM_COMMAND=/usr/local/bin/masc-exec-shim

# PID 1's effective uid and gid, from /proc/1/status rather than the owner of
# /proc/1: the kernel shows a non-dumpable process's /proc directory as root's.
bench_image_uid() { awk '$1 == "Uid:" { print $3 }' /proc/1/status; }
bench_image_gid() { awk '$1 == "Gid:" { print $3 }' /proc/1/status; }

# <text>: the text as one single-quoted word for /bin/sh.
bench_sh_quote() {
  local text="$1" quote="'"
  printf "'%s'" "${text//${quote}/${quote}\\${quote}${quote}}"
}

# <shim binary> <setpriv> <env> <uid> <gid> <passwd entry, or empty when the uid
# has none>: the wrapper script on stdout.
#
# setpriv and env are named by absolute path: the wrapper runs in an sshd
# session whose PATH is not the image's, and fedora keeps setpriv in /usr/sbin.
# With a passwd entry the wrapper takes the account's home and supplementary
# groups, as `docker exec -u` does, and its name as USER. Without one, docker
# gives the command HOME=/ and no supplementary groups, and so does the wrapper.
# USER differs from docker there: docker sets none, while the shim always gives
# a payload USER (its own, or "masc"), so the wrapper hands it the uid.
# The shim reads only HOME, USER and TMPDIR from its own environment, and an
# env_file HOME from the image replaces this HOME for payloads.
bench_shim_wrapper_text() {
  local binary="$1" setpriv="$2" env_command="$3" uid="$4" gid="$5" entry="$6" name home groups
  if [[ -n "${entry}" ]]; then
    IFS=: read -r name _ _ _ _ home _ <<<"${entry}"
    groups=--init-groups
  else
    name="${uid}"
    home=/
    groups=--clear-groups
  fi
  printf '#!/bin/sh\n'
  printf '# Written by the bench bootstrap (driver/endpoint_account.sh).\n'
  printf 'exec %s --reuid=%s --regid=%s %s %s HOME=%s USER=%s %s "$@"\n' \
    "$(bench_sh_quote "${setpriv}")" "${uid}" "${gid}" "${groups}" "$(bench_sh_quote "${env_command}")" \
    "$(bench_sh_quote "${home}")" "$(bench_sh_quote "${name}")" "$(bench_sh_quote "${binary}")"
}

# Installs the release shim off PATH and the wrapper in its place.
# <release shim binary>
bench_install_shim_as_image_user() {
  local release="$1" uid gid entry setpriv env_command
  uid="$(bench_image_uid)"
  gid="$(bench_image_gid)"
  entry="$(getent passwd "${uid}" || true)"
  setpriv="$(command -v setpriv)"
  env_command="$(command -v env)"
  install -D -m 0755 "${release}" "${BENCH_SHIM_BINARY}"
  bench_shim_wrapper_text "${BENCH_SHIM_BINARY}" "${setpriv}" "${env_command}" \
    "${uid}" "${gid}" "${entry}" > "${BENCH_SHIM_COMMAND}"
  chmod 0755 "${BENCH_SHIM_COMMAND}"
}

# <keeper name>: the keeper's directory, owned by the image's user.
bench_keeper_root() {
  local keeper="$1"
  # The image's user walks through the bench directory to reach its own; the
  # mode is set here rather than left to the umask of whoever made it.
  chmod 0755 "${BENCH_REMOTE_ROOT%/*}"
  install -d -m 0755 "${BENCH_REMOTE_ROOT}"
  install -d -m 0755 -o "$(bench_image_uid)" -g "$(bench_image_gid)" "${BENCH_REMOTE_ROOT}/${keeper}"
}

### Fixed

- The remote_ssh workspace cleanup passes over an unreadable process of the
  Keeper's own user only in a session a root process leads, which is the sshd
  pair of a connection. It used to pass over every such process whose `/proc`
  links belong to root, so a command that turned inspection off itself
  (`prctl(PR_SET_DUMPABLE, 0)`, as `ssh-agent` does) did not protect the entry
  it was working in. Such a process now keeps every entry for that pass. Both
  cleanup payloads also treat `ESRCH` from `/proc` as a process that exited
  instead of ending in a traceback (#PENDING).

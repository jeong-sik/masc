(** Keeping a terminal from stopping a long-running process and its children.

    When a background job of a terminal reads that terminal, or changes its
    settings, the kernel sends SIGTTIN or SIGTTOU to the job's whole process
    group, and the default action stops every process in it. masc keeps the
    children it starts in its own process group, so that killing the group
    also ends them. The same group made one prompting child stop everything:
    on 2026-09-24 `masc start` ran as a background job of a terminal. agy
    could not refresh its login token and opened /dev/tty for an interactive
    login. The server and all nine official-client children stopped for
    fourteen minutes.

    [ignore_signals ()] sets SIGTTIN and SIGTTOU to SIG_IGN. An ignored signal
    stays ignored across fork and exec, so every child and grandchild starts
    with it, whichever spawn path starts it. POSIX then turns a background
    read of the terminal into an EIO error instead of a stop. It also lets a
    background write or change of settings go through without SIGTTOU (POSIX
    General Terminal Interface, 11.1.4). Children stay in the group.

    What it does not cover:
    - A child that sets either signal back to its default is still stopped
      when it touches the terminal, but it stops alone: the kernel signals the
      whole group, and the rest of the group ignores the signal. /bin/stty on
      macOS does this (measured 2026-09-24).
    - A child may now change the terminal's settings. *)

val ignore_signals : unit -> unit

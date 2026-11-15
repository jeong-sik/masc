### Fixed

- One Ctrl-backslash no longer ends the TUI without a confirmation. Raw mode
  keeps ISIG on for Ctrl-C and Ctrl-Z, so the tty turned the key into SIGQUIT,
  and SIGQUIT ends the session. The TUI now turns the tty's quit key off for
  as long as it holds the terminal, the byte reaches the key reader and no
  binding takes it, and the shell gets its quit key back when the TUI hands
  the terminal over. `kill -QUIT` still ends the session (#49845, #PENDING).

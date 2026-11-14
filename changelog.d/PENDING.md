### Fixed

- Starting a child process installs the SIGCHLD handler only when the process
  has none, instead of on every spawn. Each installation wrote the runtime's
  signal handler table while other domains read it, which ThreadSanitizer
  reported as a race (#51395, #PENDING).

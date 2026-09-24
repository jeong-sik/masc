let ignore_signals () =
  Sys.set_signal Sys.sigttin Sys.Signal_ignore;
  Sys.set_signal Sys.sigttou Sys.Signal_ignore

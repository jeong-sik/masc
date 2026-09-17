(* A daemon launch can fail before any fiber exists.

   [Eio.Fiber.fork_daemon] checks its switch first (eio core/switch.ml,
   [check_our_domain]): when the TUI's root switch has already finished --
   the window closed, or the runtime is tearing down while a key handler is
   still running -- it raises [Invalid_argument "Switch finished!"] in the
   caller, synchronously, before forking anything. The loaders arm their
   inflight flag before this point, so the flag would stay armed forever
   and the pane would read as loading until the end of the process.

   The loaders already know the two failure moves for a load that never
   runs: clear the inflight flag, and put an error where the answer would
   have landed -- the same shape as the switch-unavailable [None] branch
   next to every launch site. This helper wraps the one call that can
   throw and runs those moves on its behalf.

   Cancellation is re-raised untouched: the switch that was cancelled is
   going away, so the flag's fate ends with the process and the loaders'
   own [run] convention (re-raise [Cancelled] from inside the daemon)
   applies to the launch too. *)

let launch ~sw ~on_sync_failure daemon_body =
  try Eio.Fiber.fork_daemon ~sw daemon_body with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> on_sync_failure (Printexc.to_string exn)

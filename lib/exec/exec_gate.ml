(* A3 exec_gate — single privileged entry, dispatches Verdict arms.

   The Ok payload returns the Trusted_argv itself today.  A4 wires
   this into Process_eio.run_argv_with_status and drops the 87 direct
   call sites; at that point the Ok payload becomes the command
   output record and this module becomes the sole invoker. *)

type error =
  [ `Ask_required of Verdict.request
  | `Denied of Verdict.deny_reason
  ]

let run : Verdict.t -> (Verdict.Trusted_argv.t, error) result = function
  | Verdict.Allow trusted -> Ok trusted
  | Verdict.Ask request -> Error (`Ask_required request)
  | Verdict.Deny { reason; _ } -> Error (`Denied reason)

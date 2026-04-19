(** A4a — typed approval gate plus first production spawn wrappers.

    [run] remains the typed dispatcher on an already-computed
    [Verdict.t].  The new [run_argv*] helpers are the production entry
    points used by the first cutover callers: they build a typed
    [Shell_ir.simple] from explicit argv, consult the overlay-aware
    approval policy, optionally emit shadow evidence, and only then
    delegate to [Process_eio]. *)

type error =
  [ `Ask_required of Verdict.request
  | `Denied of Verdict.deny_reason
  ]
(** Non-allow outcomes.  [Ask_required] carries the approval request
    so the caller may route it through the approval queue.  [Denied]
    is terminal — no user-approved override exists. *)

val run : Verdict.t -> (Verdict.Trusted_argv.t, error) result
(** [run verdict] dispatches on the three verdict arms.

    On [Allow trusted], returns [Ok trusted].  The production wrappers
    below consume this to decide whether the eventual [Process_eio]
    call is allowed to happen. *)

val run_argv :
  actor:string ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  string list ->
  string
(** Typed gate in front of [Process_eio.run_argv].  In [parallel] mode,
    Ask/Deny verdicts are recorded but execution still proceeds.  In
    [enforced] mode, Ask/Deny return a synthetic blocked output. *)

val run_argv_with_status :
  actor:string ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string)
(** Typed gate in front of [Process_eio.run_argv_with_status]. *)

val run_argv_with_status_split :
  actor:string ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  string list ->
  (Unix.process_status * string * string)
(** Typed gate in front of [Process_eio.run_argv_with_status_split]. *)

val run_argv_with_stdin_and_status :
  actor:string ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string)
(** Typed gate in front of [Process_eio.run_argv_with_stdin_and_status]. *)

val run_argv_with_stdin_and_status_split :
  actor:string ->
  raw_source:string ->
  summary:string ->
  ?timeout_sec:float ->
  ?env:string array ->
  ?cwd:string ->
  stdin_content:string ->
  string list ->
  (Unix.process_status * string * string)
(** Typed gate in front of [Process_eio.run_argv_with_stdin_and_status_split]. *)

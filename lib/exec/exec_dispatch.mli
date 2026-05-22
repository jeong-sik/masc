type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

val resolve_arg : Shell_ir.arg -> string
(** Resolve a Shell_ir.arg to a concrete string value. *)


val dispatch_simple :
  ?timeout_sec:float -> ?stdin_content:string -> Shell_ir.simple -> dispatch_result
(** Execute a simple command via argv-based spawn.  [stdin_content] is
    used by pipeline dispatch when a previous stage's stdout must be
    forwarded without dropping the stage's sandbox target.  [?timeout_sec]
    overrides the dispatch default. *)

val dispatch :
  ?timeout_sec:float -> Shell_ir.t -> dispatch_result
(** General dispatch over any [Shell_ir.t] variant.  [Simple] routes
    to [dispatch_simple]; [Pipeline] routes to internal pipeline
    logic.  Prefer [dispatch_decided] for production keeper paths.
    Exposed for tests and legacy call sites. *)

val dispatch_decided :
  ?timeout_sec:float ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir -> dispatch_result
(** RFC-0160 S3: dispatch a risk-classified IR.  The phantom type
    ensures the IR has passed through [Shell_ir_risk.classify]. *)

val dispatch_pipeline :
  ?timeout_sec:float -> Shell_ir.t list -> dispatch_result
(** Execute a pipeline of commands, streaming stdout between stages.
    Handles [Simple] stages natively; nested [Pipeline] stages are
    rejected with an error. *)

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

val dispatch_decided :
  ?timeout_sec:float ->
  Shell_ir_risk.decided Shell_ir_risk.decided_ir -> dispatch_result
(** RFC-0160 S3: dispatch a risk-classified IR.  The phantom type
    ensures the IR has passed through [Shell_ir_risk.classify]. *)

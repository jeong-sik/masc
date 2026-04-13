(** Keeper Failure Circuit Breaker — detect repeated tool failures and
    inject corrective hints into error responses.

    After [threshold] consecutive failures of the same error class,
    appends a corrective hint to the error message. Resets on success.

    @since v0.5.11 *)

(** Coarse error categories for grouping failures. *)
type error_class =
  | Path_not_found
  | Path_not_allowed
  | Cwd_not_directory
  | Shell_exit_nonzero
  | Other

(** Classify an error message string into an error class. *)
val classify_error : string -> error_class

(** Record a successful tool call (resets consecutive counter). *)
val record_success : keeper_name:string -> unit

(** Enrich an error message with a corrective hint if the circuit
    breaker threshold has been reached. Returns the original message
    unchanged if under threshold, or message + hint if tripped. *)
val maybe_enrich_error : keeper_name:string -> error_msg:string -> string

(** JSON snapshot of all breaker states for diagnostics. *)
val snapshot_json : unit -> Yojson.Safe.t

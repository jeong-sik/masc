(** Resolve a retained tool result by canonical execution, never by a recent
    call, provider ID alone, tool name or timestamp. This pure boundary does
    not read files, publish blobs, authorize HTTP requests or execute tools.
    The caller owns exact ledger/TurnRecord reads and a validated, stable
    keeper-owned raw trace. Missing raw traces are not a durability promise. *)

type error =
  | Execution_missing
  | Execution_ambiguous
  | Invalid_execution of string
  | Turn_mismatch of string
  | Invalid_run of string
  | Invalid_occurrence of string
  | Result_missing

val error_to_string : error -> string

type invocation
val invocation :
  keeper:string -> execution_id:Ids.Execution_id.t -> rows:Yojson.Safe.t list ->
  (invocation, error) result
(** [rows] must be all authoritative rows for this keeper and execution ID.
    Duplicates are refused. The canonical Tool_observation owns [turn_ref];
    all ledger coordinates are checked against it before a target is bound. *)
val turn_ref : invocation -> Ids.Turn_ref.t

type target
type binding = Awaiting_turn | Untraced_turn | Bound of target
val bind : invocation -> Turn_record.t option -> (binding, error) result
(** An absent enclosing TurnRecord can precede publication and is pending.
    A completed record without a raw reference is explicitly untraced.
    Both Direct and Autonomous records use the same exact identity checks. *)
val run_ref : target -> Turn_record.raw_trace_run_ref

type scan
val start : target -> scan
val observe : scan -> Agent_core.Raw_trace.record -> (scan, error) result
(** Fold decoded records in physical order, retaining only the matching tool
    result and constant-size occurrence metadata. File I/O, record decoding,
    stable source validation and resource limits remain the caller's job.
    This API alone does not establish a bounded JSONL reader. *)

type body =
  { execution_id : Ids.Execution_id.t
  ; turn_ref : Ids.Turn_ref.t
  ; start_seq : int
  ; finish_seq : int
  ; recorded_bytes : int
  ; content : string
  ; is_error : bool
  }
val finish : scan -> (body, error) result
(** Only the unique start/finish pair at the original invocation coordinates
    supplies [content]. JSON results receive full structural secret redaction;
    plain text receives full text redaction, without preview truncation.
    [recorded_bytes] is the pre-projection tool_result byte length. Recovering
    it never changes the producer's output-completeness evidence. Other raw
    fields, including assistant reasoning, are not returned. *)

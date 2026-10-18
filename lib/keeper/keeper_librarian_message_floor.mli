(** Shared volatile inference for an exact message boundary. Producers retain
    source serialization, publication and cursor ownership. *)

type prepared = private
  { anchor : Keeper_memory_os_current.program_anchor
  ; program : Keeper_memory_os_program.t
  ; working_state : string option
  ; served_by : Keeper_librarian_runtime.served_slot option
  }
(** [working_state=None] means no step was accepted and no previous state was
    supplied. A producer that needs a continuation must infer one separately.
    [served_by=None] means no Memory decision was accepted in this walk. *)

type error = private
  { detail : string
  ; reports : Keeper_librarian_runtime.not_committed list
  }
(** Runtime failures preserve their actual reports in callback order.
    Structural, anchor and staging errors have no fabricated Runtime reports. *)

val infer :
  ?cli_runner:Keeper_lane_cli_oneshot.runner ->
  base_path:string -> keepers_dir:string -> keeper_name:string ->
  sources:Keeper_librarian_unread.source list ->
  unread_message:(Keeper_librarian_unread.source ->
    reasons:Keeper_librarian_input_refusal.t list ->
    (Keeper_librarian_unread.t, string) result) ->
  previous_state:string option ->
  unread_messages:Keeper_librarian_unread.t list ->
  Keeper_librarian.input -> (prepared, error) result
(** Bind the frozen manifest to every input message before dispatch, capture
    Memory once, and thread accepted private Runtime decisions through the
    staged facts in original source order. Only Runtime's actual exhausted
    API-walk evidence may become an unread message; verify the producer's
    returned source and refusal causes exactly.

    Preserve joined tool and counterpart observations until one Memory step
    accepts them. If every source is unread but observations remain, require
    a real observation-only Memory step. Its empty source list accounts for
    no conversation message. All final sources are partitioned exactly once
    between accepted steps and unread records.

    Apart from the initial Memory anchor capture and ordinary Runtime
    telemetry, this performs no storage, recovery, publication or cursor
    operation. Cancellation propagates. The caller must validate and serialize
    its source again while publishing the returned program. *)

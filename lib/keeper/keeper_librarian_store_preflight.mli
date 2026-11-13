type purpose = Admission_execution | Admission_part | Admission_partition | Admission_closure
  | History_execution | Floor_execution | Admission_gate | History_gate | Floor_gate
val purpose : string -> purpose option
(** The Librarian record kind a scope belongs to, asked of each producer's
    own scope predicate, gates first: a floor step scope's prefix also starts
    a floor step gate scope (#49021). [None] is a scope no Librarian producer
    owns. *)

(** Current-only Librarian original payload inspection. Every retained record,
    including historical gates, is checked in its captured namespace. The
    supplied port reads verified parent/body snapshots; no Current, live-owner,
    worker, provider, recovery, mutation or ACK operation is reachable here.
    This establishes readable schema/source/binding, not effect authority or
    completed consumption.

    A validator belongs to one scan. It keeps the Librarian forests it has
    already read and passed, so the records of one owner share a single read of
    that owner's scopes. A forest that failed is read again by the next record
    that names it. *)
val validator : unit ->
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  read_body:(scope:string -> request_digest:string -> (Yojson.Safe.t, string) result) ->
  read_archive:(scope:string -> date:string -> request_id:string ->
    (Lane_addon_tool_request_owner.Record.t option, string) result) ->
  read_fence:Keeper_librarian_history_resolution_lineage.reader ->
  read_resolution:Keeper_librarian_history_resolution_lineage.reader ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result

val preflight : unit -> Lane_addon_store_preflight.payload_validator
(** The deploy check of a Librarian original: {!validator}, then the reads its
    consumer makes of Exact files, on the files the Exact check leaves (RFC
    exact-request-skips-a-slot-that-refused-its-input 3.3, item 5). An
    original whose consumer stops on those files is refused with every scope
    of its owner, and with its proof link when no record of it is left. The
    consumer's own rules decide: a Dispatch_pending original recovers its
    record and confirms the final it finishes with, a phase that holds a
    judgment decodes and confirms it, and an execution refusal confirms the
    final its evidence names. Admission then reads the size evidence of a body
    refusal ([Request_body_refused]) through the original's record, so an
    admission original whose record the Exact check deletes is refused for
    that final too; history and floor build its evidence from the final
    alone. A gate follows its parent execution. A
    partition and a root that replaces an earlier frontier compare the
    evidence they retain with what their executions show. A manual
    installation, a fenced history original and a member of a Closing or
    Closed closure are read by no consumer. A proof that names another store
    root stops the scan. Live owner state is not observed.

    A check belongs to one scan, like {!validator}. It keeps each owner's
    forest of parts and partitions for the scan, and reads it again before it
    refuses a record. *)

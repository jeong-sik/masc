(** Durable retention of a HITL judge original.

    A judge original is stored through [Lane_addon_tool_request_owner], the
    host's one original-request store: the request body once, named by its
    digest, and a small record that holds the identity, that digest, a summary
    and the progress. Nothing here adds a store, a registry or a worker.

    Retention records what was asked, never what may be done with it: the
    approval's decision, its terminalisation and its consumption stay with the
    host's approval queue. The caller holds the workspace process lease and
    serialises retains and progress updates, as for every user of the owner. *)

val scope : string
(** The owner scope of every judge original. *)

val package_id : string
val tool : string

val installation : Lane_addon_tool_request_owner.installation
(** The host itself, not a configured declaration: until an Addon is installed
    for this service, the original belongs to the host. *)

val request_id : Hitl_judge_original.t -> string
(** One record per approval attempt: the approval id and its sequence. The
    input hash is not part of the id, so the same attempt prepared from a
    different input is a binding conflict, not a second record. *)

val summary : Hitl_judge_original.t -> Yojson.Safe.t
(** The canonical index the record keeps beside the request: approval id, input
    hash and sequence. {!load} checks it against the restored request. *)

val retain
  :  store:Lane_addon_store.t
  -> Hitl_judge_original.t
  -> (unit, string) result
(** Persist the original before any dispatch. The same original is idempotent
    and keeps advanced progress; another original for the same attempt is
    refused. *)

val load
  :  store:Lane_addon_store.t
  -> approval_id:string
  -> sequence:int
  -> (Lane_addon_tool_request_owner.retained option * Hitl_judge_original.t option, string) result
(** The retained record and the original it names, restored strictly. [None]
    means no such attempt. A record whose request does not decode as a judge
    original, or whose summary or identity differs from it, is an error. *)

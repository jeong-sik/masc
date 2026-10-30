(** Host-owned provenance of an approval request. Physical turns are witnesses;
    only the stable logical source participates in duplicate identity. *)
type admitted_source = private
  { snapshot_ref : string
  ; admitted_revision : int64
  ; board_post_id : string option
  }

type logical_source = private
  | Direct_operation of Keeper_operation_id.t
  | Admitted_sources of admitted_source list
  | No_admitted_source

type t = private
  { source : logical_source
  ; turn_ref : Ids.Turn_ref.t option
  }

val unavailable : t
(** Explicit absence of admitted provenance. It does not infer a source from
    history, a prompt, the current turn, or the reply route. *)

val admitted_source :
  snapshot_ref:string -> admitted_revision:int64 -> board_post_id:string option ->
  (admitted_source, string) result
(** A producer-owned exact source snapshot and its durable admission revision.
    [board_post_id] is [Some] only for an actual admitted Board source. *)

val direct_operation :
  operation_id:Keeper_operation_id.t -> turn_ref:Ids.Turn_ref.t -> t

val admitted_sources :
  sources:admitted_source list -> turn_ref:Ids.Turn_ref.t -> (t, string) result
(** Canonicalize a nonempty source set. Duplicate exact sources are refused. *)

val same_logical_source : t -> t -> bool
(** Ignores the physical [turn_ref]. The reply surface remains the queue's
    existing typed continuation-channel identity. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict canonical object; missing, duplicate and unknown fields are errors. *)

(** Typed host admission before the physical turn reference is allocated. *)
type admission =
  | Direct_request of Keeper_operation_id.t
  | Admitted of Keeper_event_queue_state.pending_selection list
      (** One intake batch taken once from one durable queue state, which keeps a
          single entry per stimulus identity ([uniq_stimuli] on admission,
          [validate_state] on decode). [snapshot_ref] hashes the whole stimulus, so
          the same [snapshot_ref] + [admitted_revision] cannot appear twice; a
          duplicate is a fabricated batch and {!from_admission} refuses it. *)
  | Unavailable

val from_admission : admission -> turn_ref:Ids.Turn_ref.t -> (t, string) result
(** Exact durable source coordinates only; an empty batch is explicitly
    unavailable. Only Board payloads contribute a [board_post_id]. The set
    describes admitted context, not an invented per-tool causal attribution. *)

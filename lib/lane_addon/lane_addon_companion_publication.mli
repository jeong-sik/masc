(** Immutable, schema-validated public notices on an original companion source.
    No Browser command, provider connection, queue wake or secret is retained. *)
type kind = Attention_required | Effect_submitted | Terminal | Owner_lost
val kind_to_string : kind -> string
type event = private { publication_id:string; kind:kind; output:Yojson.Safe.t }
type error = Invalid_event | Schema_rejected | Binding_conflict | Corrupt
  | Unavailable | Commit_unconfirmed
val error_to_string : error -> string
val validate_output_schema : Yojson.Safe.t -> (unit, string) result
(** The same recursively closed schema contract used by exported companion
    replies. Values remain subject to that captured schema before persistence. *)
val event : output_schema:Yojson.Safe.t -> Yojson.Safe.t -> (event,error) result
(** Decode a worker publication. [Owner_lost] is never accepted here. *)
val owner_lost : publication_id:string -> (event,error) result
(** Host-only fixed [{"outcome":"unknown"}] after a previously accepted original
    provider ends without a confirmed terminal publication. This constructor
    grants no publication authority and persists nothing. The private retained
    record still binds the original closed worker schema as provenance. *)
val event_json : event -> Yojson.Safe.t
type record = private {
  origin:Lane_addon_companion_origin.record;
  output_schema:Yojson.Safe.t;
  event:event;
}
val retain : fs:Eio.Fs.dir_ty Eio.Path.t -> config:Workspace.config ->
  origin:Lane_addon_companion_origin.record -> output_schema:Yojson.Safe.t ->
  event:event -> (record,error) result
(** Commit before queue admission. A repeated ID must match the exact original
    source, schema and canonical output. Existing damaged files refuse without
    repair. Mandatory recovery and the private target projection are bound to
    the opened MASC root. An unchanged existing target with successful cleanup
    and lane release may be reconciled; uncertain effects remain unconfirmed.
    A stable per-target owner lock excludes other fibers/processes before
    recovery readiness through lane release. Contention refuses without
    waiting; admitted work uses the durable lock's cancellation protection.
    Reconciliation never replays Browser work or creates a new ID. *)
val find : config:Workspace.config -> origin_id:string -> publication_id:string ->
  (record,error) result
(** Re-read the original source and immutable notice with no provider effects.
    Missing/corrupt/unsafe records refuse; they do not become empty results. *)
val queue_payload : record -> Keeper_event_queue.addon_operation_change
(** Original coordinates only. No current Task or route is consulted. *)
val matches_queue : keeper_name:string -> Keeper_event_queue.addon_operation_change ->
  record -> bool

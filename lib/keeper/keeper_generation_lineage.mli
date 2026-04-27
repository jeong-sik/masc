(** Generation lineage — handoff manifest + per-keeper rollover index.

    Records the parent→child meta projection on each rollover and
    exposes a [surface_json] view consumed by the dashboard
    generation-lineage panel. *)

(** Drift_guard verdict + similarity projected to JSON. *)
type continuity_judgment =
  { json : Yojson.Safe.t
  ; verdict : string
  ; similarity : float option
  }

(** SSOT list of identity fields tracked across generations.
    Each pair is [(field_name, getter)]. *)
val identity_fields :
  (string * (Keeper_types.keeper_meta -> string)) list

val string_list_to_json : string list -> Yojson.Safe.t
val float_opt_to_json : float option -> Yojson.Safe.t

val option_to_json :
  ('a -> Yojson.Safe.t) -> 'a option -> Yojson.Safe.t

(** Compose the canonical [<keeper>:<generation>:<trace_id>]
    generation identifier. *)
val generation_id :
  keeper_name:string -> generation:int -> trace_id:string -> string

(** Project [meta] to its identity field pairs in [identity_fields]
    declaration order. *)
val identity_pairs :
  Keeper_types.keeper_meta -> (string * string) list

(** Render [meta]'s identity pairs as a JSON object keyed by field. *)
val identity_snapshot_json :
  Keeper_types.keeper_meta -> Yojson.Safe.t

(** Compare [previous] vs [current] identity field pairs.
    Returns [(inherited, changed, dropped)] in declaration order. *)
val classify_identity_fields :
  previous:(string * string) list ->
  current:(string * string) list ->
  string list * string list * string list

(** Render the parent→child identity diff as JSON for the
    manifest's [inheritance_delta] field. *)
val inheritance_delta_json :
  parent:Keeper_types.keeper_meta ->
  child:Keeper_types.keeper_meta ->
  Yojson.Safe.t

(** Run Drift_guard against [original] vs [received] and project
    the verdict + similarity to [continuity_judgment]. *)
val continuity_judgment :
  original:string -> received:string -> continuity_judgment

(** Build the per-rollover manifest JSON document
    ([keeper_generation_lineage_v1] schema). *)
val manifest_json :
  parent:Keeper_types.keeper_meta ->
  child:Keeper_types.keeper_meta ->
  parent_trace_id:string ->
  trigger_reason:string ->
  context_ratio:float ->
  model:string ->
  Yojson.Safe.t

(** Build the per-rollover index-entry JSON appended to the keeper
    generation-index JSONL. *)
val index_entry_json :
  manifest_path:string ->
  parent:Keeper_types.keeper_meta ->
  child:Keeper_types.keeper_meta ->
  parent_trace_id:string ->
  trigger_reason:string ->
  context_ratio:float ->
  model:string ->
  Yojson.Safe.t

(** Persist both the manifest (atomic write) and the index entry
    (JSONL append) for the given handoff. Logs and swallows
    non-cancel exceptions — best-effort lineage telemetry. *)
val record_handoff_artifacts :
  config:Coord.config ->
  parent:Keeper_types.keeper_meta ->
  child:Keeper_types.keeper_meta ->
  parent_trace_id:string ->
  trigger_reason:string ->
  context_ratio:float ->
  model:string ->
  unit

(** Load a JSON file as [Some json] when present and parseable;
    [None] otherwise. *)
val load_json_file_opt : string -> Yojson.Safe.t option

(** Load a JSONL file as a list of values; returns [[]] when the
    file is missing or unreadable. *)
val load_jsonl_file : string -> Yojson.Safe.t list

(** [take n xs] keeps the first [n] elements of [xs] (or all when
    [n >= List.length xs]). *)
val take : int -> 'a list -> 'a list

(** Render the lineage surface document for [meta]: current
    generation/trace, manifest path, recent index entries (capped
    to [recent_limit]). *)
val surface_json :
  Coord.config ->
  Keeper_types.keeper_meta ->
  recent_limit:int ->
  Yojson.Safe.t

(** Generation lineage — read surface over the handoff manifest and
    per-keeper rollover index.

    Exposes a [surface_json] view consumed by the dashboard
    generation-lineage panel. *)

(** Compose the canonical [<keeper>:<generation>:<trace_id>]
    generation identifier. *)
val generation_id :
  keeper_name:string -> generation:int -> trace_id:string -> string

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
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  recent_limit:int ->
  Yojson.Safe.t

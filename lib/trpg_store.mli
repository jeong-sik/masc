(** Abstract storage interface for TRPG game engine.

    Decouples TRPG handlers from MASC internals (base_dir, .masc/ directory).
    Uses record-of-functions pattern — base_dir is captured in closures,
    so callers never see filesystem paths. *)

type snapshot = {
  last_seq : int;
  ts : string;
  state : Trpg_engine_types.room_state;
}

type t = {
  (* Event storage *)
  append_event : event:Trpg_engine_event.t -> (unit, string) result;
  read_events : room_id:string -> (Trpg_engine_event.t list, string) result;
  read_events_after :
    room_id:string -> after_seq:int -> (Trpg_engine_event.t list, string) result;
  (* Snapshot *)
  write_snapshot :
    room_id:string ->
    last_seq:int ->
    ts:string ->
    state:Trpg_engine_types.room_state ->
    (unit, string) result;
  read_snapshot : room_id:string -> (snapshot option, string) result;
  load_recovery :
    room_id:string ->
    (snapshot option * Trpg_engine_event.t list, string) result;
  (* Config/presets *)
  load_catalog : unit -> (Trpg_preset_store.catalog, string) result;
  load_world_contracts : unit -> Yojson.Safe.t;
  (* Filesystem paths — base_dir captured in closure *)
  room_dir : room_id:string -> string;
}

val make_sqlite : base_dir:string -> t
val make_jsonl : base_dir:string -> t

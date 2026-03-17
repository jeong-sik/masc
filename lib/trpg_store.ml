(** Abstract storage interface — record-of-functions implementation.

    base_dir is captured once in make_sqlite / make_jsonl closures.
    TRPG handlers only see [t] and never touch MASC internals. *)

type snapshot = {
  last_seq : int;
  ts : string;
  state : Trpg_engine_types.room_state;
}

type t = {
  append_event : event:Trpg_engine_event.t -> (unit, string) result;
  read_events : room_id:string -> (Trpg_engine_event.t list, string) result;
  read_events_after :
    room_id:string -> after_seq:int -> (Trpg_engine_event.t list, string) result;
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
  load_catalog : unit -> (Trpg_preset_store.catalog, string) result;
  load_world_contracts : unit -> Yojson.Safe.t;
  room_dir : room_id:string -> string;
}

(* Convert implementation-specific snapshot to our snapshot type *)
let convert_sqlite_snapshot (s : Trpg_engine_store_sqlite.snapshot) : snapshot =
  { last_seq = s.last_seq; ts = s.ts; state = s.state }

let convert_jsonl_snapshot (s : Trpg_engine_store.snapshot) : snapshot =
  { last_seq = s.last_seq; ts = s.ts; state = s.state }

let world_contracts_path ~base_dir =
  Filename.concat base_dir "config/trpg/world_contracts.json"

let load_world_contracts_from_dir ~base_dir : Yojson.Safe.t =
  let path = world_contracts_path ~base_dir in
  if not (Sys.file_exists path) then `Null
  else
    match Safe_ops.read_json_eio path with
    | exception _ -> `Null
    | json -> json

let make_sqlite ~base_dir : t =
  let _ = Trpg_engine_store_sqlite.init ~base_dir in
  {
    append_event = (fun ~event -> Trpg_engine_store_sqlite.append_event ~base_dir ~event);
    read_events = (fun ~room_id -> Trpg_engine_store_sqlite.read_events ~base_dir ~room_id);
    read_events_after =
      (fun ~room_id ~after_seq ->
        Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq);
    write_snapshot =
      (fun ~room_id ~last_seq ~ts ~state ->
        Trpg_engine_store_sqlite.write_snapshot ~base_dir ~room_id ~last_seq ~ts ~state);
    read_snapshot =
      (fun ~room_id ->
        Trpg_engine_store_sqlite.read_snapshot ~base_dir ~room_id
        |> Result.map (Option.map convert_sqlite_snapshot));
    load_recovery =
      (fun ~room_id ->
        Trpg_engine_store_sqlite.load_recovery ~base_dir ~room_id
        |> Result.map (fun (snap_opt, events) ->
               (Option.map convert_sqlite_snapshot snap_opt, events)));
    load_catalog = (fun () -> Trpg_preset_store.load_catalog ~base_dir);
    load_world_contracts = (fun () -> load_world_contracts_from_dir ~base_dir);
    room_dir = (fun ~room_id -> Filename.concat base_dir room_id);
  }

let make_jsonl ~base_dir : t =
  {
    append_event = (fun ~event -> Trpg_engine_store.append_event ~base_dir ~event);
    read_events = (fun ~room_id -> Trpg_engine_store.read_events ~base_dir ~room_id);
    read_events_after =
      (fun ~room_id ~after_seq ->
        Trpg_engine_store.read_events_after ~base_dir ~room_id ~after_seq);
    write_snapshot =
      (fun ~room_id ~last_seq ~ts ~state ->
        Trpg_engine_store.write_snapshot ~base_dir ~room_id ~last_seq ~ts ~state);
    read_snapshot =
      (fun ~room_id ->
        Trpg_engine_store.read_snapshot ~base_dir ~room_id
        |> Result.map (Option.map convert_jsonl_snapshot));
    load_recovery =
      (fun ~room_id ->
        Trpg_engine_store.load_recovery ~base_dir ~room_id
        |> Result.map (fun (snap_opt, events) ->
               (Option.map convert_jsonl_snapshot snap_opt, events)));
    load_catalog = (fun () -> Trpg_preset_store.load_catalog ~base_dir);
    load_world_contracts = (fun () -> load_world_contracts_from_dir ~base_dir);
    room_dir = (fun ~room_id -> Filename.concat base_dir room_id);
  }

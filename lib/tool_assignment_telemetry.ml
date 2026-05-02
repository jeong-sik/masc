module Random = Stdlib.Random
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_assignment_telemetry — Unified tool assignment lifecycle events

    See .mli for design rationale and public API. *)

type assignment_id = string

type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value

let error_kind_to_string (Error_kind value) = value

type tool_event =
  | Assigned of {
      assignment_id : assignment_id;
      agent_id : string;
      profile : string;
      preset : string option;
      tool_list : string list;
      allow_set : string list;
      deny_set : string list;
      config_hash : string;
      reason : string;
      timestamp : float;
    }
  | Called of {
      assignment_id : assignment_id;
      tool_name : string;
      arguments_hash : string;
      source : string;
      timestamp : float;
    }
  | Completed of {
      assignment_id : assignment_id;
      tool_name : string;
      success : bool;
      duration_ms : float;
      error_kind : error_kind option;
      timestamp : float;
    }

(* ── JSON serialization ───────────────────────────────── *)

let event_to_json = function
  | Assigned
      { assignment_id; agent_id; profile; preset; tool_list; allow_set; deny_set;
        config_hash; reason; timestamp } ->
      `Assoc
        [ ("event_type", `String "Assigned")
        ; ("assignment_id", `String assignment_id)
        ; ("agent_id", `String agent_id)
        ; ("profile", `String profile)
        ; ("preset", match preset with Some p -> `String p | None -> `Null)
        ; ("tool_list", `List (List.map (fun s -> `String s) tool_list))
        ; ("allow_set", `List (List.map (fun s -> `String s) allow_set))
        ; ("deny_set", `List (List.map (fun s -> `String s) deny_set))
        ; ("config_hash", `String config_hash)
        ; ("reason", `String reason)
        ; ("timestamp", `Float timestamp)
        ]
  | Called { assignment_id; tool_name; arguments_hash; source; timestamp } ->
      `Assoc
        [ ("event_type", `String "Called")
        ; ("assignment_id", `String assignment_id)
        ; ("tool_name", `String tool_name)
        ; ("arguments_hash", `String arguments_hash)
        ; ("source", `String source)
        ; ("timestamp", `Float timestamp)
        ]
  | Completed
      { assignment_id; tool_name; success; duration_ms; error_kind; timestamp }
    ->
      `Assoc
        [ ("event_type", `String "Completed")
        ; ("assignment_id", `String assignment_id)
        ; ("tool_name", `String tool_name)
        ; ("success", `Bool success)
        ; ("duration_ms", `Float duration_ms)
        ; ( "error_kind"
          , match error_kind with
            | Some e -> `String (error_kind_to_string e)
            | None -> `Null )
        ; ("timestamp", `Float timestamp)
        ]

let event_of_json json : (tool_event, string) Result.t =
  let open Yojson.Safe.Util in
  try
    match json |> member "event_type" |> to_string with
    | "Assigned" ->
        let preset =
          match json |> member "preset" with
          | `Null -> None
          | `String s -> Some s
          | _ -> None
        in
        let string_list field =
          json |> member field |> to_list
          |> List.filter_map (function `String s -> Some s | _ -> None)
        in
        Ok
          (Assigned
             { assignment_id = json |> member "assignment_id" |> to_string
             ; agent_id = json |> member "agent_id" |> to_string
             ; profile = json |> member "profile" |> to_string
             ; preset
             ; tool_list = string_list "tool_list"
             ; allow_set = string_list "allow_set"
             ; deny_set = string_list "deny_set"
             ; config_hash = json |> member "config_hash" |> to_string
             ; reason = json |> member "reason" |> to_string
             ; timestamp = json |> member "timestamp" |> to_number
             })
    | "Called" ->
        let source = json |> member "source" |> to_string in
        Ok
          (Called
             { assignment_id = json |> member "assignment_id" |> to_string
             ; tool_name = json |> member "tool_name" |> to_string
             ; arguments_hash = json |> member "arguments_hash" |> to_string
             ; source
             ; timestamp = json |> member "timestamp" |> to_number
             })
    | "Completed" ->
        let error_kind =
          match json |> member "error_kind" with
          | `Null -> None
          | `String s -> Some (error_kind_of_string s)
          | _ -> None
        in
        Ok
          (Completed
             { assignment_id = json |> member "assignment_id" |> to_string
             ; tool_name = json |> member "tool_name" |> to_string
             ; success = json |> member "success" |> to_bool
             ; duration_ms = json |> member "duration_ms" |> to_number
             ; error_kind
             ; timestamp = json |> member "timestamp" |> to_number
             })
    | other -> Error (Printf.sprintf "unknown event_type: %s" other)
  with Type_error (msg, _) -> Error msg

(* ── In-memory state ──────────────────────────────────── *)

let store_ref : Dated_jsonl.t option ref = ref None
let store_mu = Eio.Mutex.create ()

let agent_index : (string, assignment_id) Hashtbl.t = Hashtbl.create 64
let index_mu = Eio.Mutex.create ()

let rng = Random.State.make_self_init ()
let rng_mu = Eio.Mutex.create ()
let with_rng f = Eio.Mutex.use_ro rng_mu (fun () -> f rng)

(* ── Store lifecycle ──────────────────────────────────── *)

let get_or_create_store () : Dated_jsonl.t =
  match !store_ref with
  | Some s -> s
  | None ->
      Eio_guard.with_mutex store_mu (fun () ->
        match !store_ref with
        | Some s -> s
        | None ->
            let base_path = Env_config.base_path () in
            let dir = Filename.concat base_path "data/tool-events" in
            Fs_compat.mkdir_p dir;
            let s = Dated_jsonl.create ~base_dir:dir () in
            store_ref := Some s;
            s)

(* ── Default config hash ──────────────────────────────── *)

let default_config_hash ~profile ~tool_list ~allow_set ~deny_set =
  let input = String.concat "|" (profile :: tool_list @ allow_set @ deny_set) in
  Digestif.SHA256.(digest_string input |> to_hex)

(* ── Public API ───────────────────────────────────────── *)

let emit_assigned
    ~agent_id
    ~profile
    ?preset
    ~tool_list
    ?(allow_set = [])
    ?(deny_set = [])
    ?config_hash
    ?(reason = "")
    () : assignment_id =
  let assignment_id =
    with_rng (fun rng -> Uuidm.(v4_gen rng () |> to_string))
  in
  let config_hash =
    match config_hash with
    | Some h -> h
    | None -> default_config_hash ~profile ~tool_list ~allow_set ~deny_set
  in
  let event =
    Assigned
      { assignment_id
      ; agent_id
      ; profile
      ; preset
      ; tool_list
      ; allow_set
      ; deny_set
      ; config_hash
      ; reason
      ; timestamp = Time_compat.now ()
      }
  in
  let store = get_or_create_store () in
  Dated_jsonl.append store (event_to_json event);
  Eio_guard.with_mutex index_mu (fun () ->
    Hashtbl.replace agent_index agent_id assignment_id);
  assignment_id

let emit_called
    ~agent_id
    ~tool_name
    ?(arguments_hash = "")
    ~source
    () : assignment_id option =
  let assignment_id_opt =
    Eio_guard.with_mutex_ro index_mu (fun () ->
      Hashtbl.find_opt agent_index agent_id)
  in
  match assignment_id_opt with
  | None -> None
  | Some assignment_id ->
      let event =
        Called
          { assignment_id
          ; tool_name
          ; arguments_hash
          ; source
          ; timestamp = Time_compat.now ()
          }
      in
      let store = get_or_create_store () in
      Dated_jsonl.append store (event_to_json event);
      Some assignment_id

let emit_completed
    ~assignment_id
    ~tool_name
    ~success
    ~duration_ms
    ?error_kind
    () : unit =
  let event =
    Completed
      { assignment_id
      ; tool_name
      ; success
      ; duration_ms
      ; error_kind
      ; timestamp = Time_compat.now ()
      }
  in
  let store = get_or_create_store () in
  Dated_jsonl.append store (event_to_json event)

let find_latest_assignment_id ~agent_id : assignment_id option =
  Eio_guard.with_mutex_ro index_mu (fun () ->
    Hashtbl.find_opt agent_index agent_id)

let read_recent ~n : (tool_event list, string) Result.t =
  try
    let store = get_or_create_store () in
    let jsons = Dated_jsonl.read_recent store n in
    let events =
      List.filter_map
        (fun json ->
          match event_of_json json with Ok ev -> Some ev | Error _ -> None)
        jsons
    in
    (* Dated_jsonl returns oldest-first; API promises newest-first. *)
    Ok (List.rev events)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Stdlib.Printexc.to_string exn)

let warm_up () : unit =
  try
    let store = get_or_create_store () in
    let jsons = Dated_jsonl.read_recent store 100_000 in
    Eio_guard.with_mutex index_mu (fun () ->
      Hashtbl.clear agent_index;
      List.iter
        (fun json ->
          match event_of_json json with
          | Ok (Assigned { assignment_id; agent_id; _ }) ->
              Hashtbl.replace agent_index agent_id assignment_id
          | _ -> ())
        jsons)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Telemetry.warn "warm_up failed: %s" (Stdlib.Printexc.to_string exn)

let reset_for_testing () : unit =
  store_ref := None;
  Eio_guard.with_mutex index_mu (fun () -> Hashtbl.clear agent_index)

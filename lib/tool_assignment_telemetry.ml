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
      { assignment_id; agent_id; profile; tool_list; allow_set; deny_set;
        config_hash; reason; timestamp } ->
      `Assoc
        [ ("event_type", `String "Assigned")
        ; ("assignment_id", `String assignment_id)
        ; ("agent_id", `String agent_id)
        ; ("profile", `String profile)
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
  try
    match Json_util.get_string_with_default json ~key:"event_type" ~default:"" with
    | "Assigned" ->
        let string_list field =
          (match Json_util.get_array json field with
           | Some (`List items) -> items
           | _ -> [])
          |> List.filter_map (function `String s -> Some s | _ -> None)
        in
        Ok
          (Assigned
             { assignment_id = Json_util.get_string_with_default json ~key:"assignment_id" ~default:""
             ; agent_id = Json_util.get_string_with_default json ~key:"agent_id" ~default:""
             ; profile = Json_util.get_string_with_default json ~key:"profile" ~default:""
             ; tool_list = string_list "tool_list"
             ; allow_set = string_list "allow_set"
             ; deny_set = string_list "deny_set"
             ; config_hash = Json_util.get_string_with_default json ~key:"config_hash" ~default:""
             ; reason = Json_util.get_string_with_default json ~key:"reason" ~default:""
             ; timestamp = Json_util.get_float json "timestamp" |> Option.value ~default:0.0
             })
    | "Called" ->
        let source = Json_util.get_string_with_default json ~key:"source" ~default:"" in
        Ok
          (Called
             { assignment_id = Json_util.get_string_with_default json ~key:"assignment_id" ~default:""
             ; tool_name = Json_util.get_string_with_default json ~key:"tool_name" ~default:""
             ; arguments_hash = Json_util.get_string_with_default json ~key:"arguments_hash" ~default:""
             ; source
             ; timestamp = Json_util.get_float json "timestamp" |> Option.value ~default:0.0
             })
    | "Completed" ->
        let error_kind =
          Json_util.get_string json "error_kind"
          |> Option.map error_kind_of_string
        in
        Ok
          (Completed
             { assignment_id = Json_util.get_string_with_default json ~key:"assignment_id" ~default:""
             ; tool_name = Json_util.get_string_with_default json ~key:"tool_name" ~default:""
             ; success = Json_util.get_bool json "success" |> Option.value ~default:false
             ; duration_ms = Json_util.get_float json "duration_ms" |> Option.value ~default:0.0
             ; error_kind
             ; timestamp = Json_util.get_float json "timestamp" |> Option.value ~default:0.0
             })
    | other -> Error (Printf.sprintf "unknown event_type: %s" other)
  with Yojson.Safe.Util.Type_error (msg, _) -> Error msg

(* ── In-memory state ──────────────────────────────────── *)

let store_ref : Dated_jsonl.t option ref = ref None
let store_mu = Eio.Mutex.create ()

let agent_index : (string, assignment_id) Hashtbl.t = Hashtbl.create 64
let index_mu = Eio.Mutex.create ()

let rng = Random.State.make_self_init ()
let rng_mu = Eio.Mutex.create ()
let with_rng f = Eio.Mutex.use_ro rng_mu (fun () -> f rng)

let record_failure_metric ?(delta = 1.0) ~site () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_tool_assignment_telemetry_failures
    ~labels:[ ("site", site) ] ~delta ()

let observe_failure ~site ~error =
  record_failure_metric ~site ();
  Log.Telemetry.warn "tool_assignment_telemetry failure: site=%s error=%s"
    site error

type failure_acc =
  { mutable count : int
  ; mutable first_error : string option
  }

let create_failure_acc () = { count = 0; first_error = None }

let add_decode_failure acc error =
  acc.count <- acc.count + 1;
  match acc.first_error with
  | Some _ -> ()
  | None -> acc.first_error <- Some error

let observe_decode_failures ~site acc =
  if acc.count > 0 then (
    record_failure_metric ~site ~delta:(float_of_int acc.count) ();
    let first_error = Option.value ~default:"unknown" acc.first_error in
    Log.Telemetry.warn
      "tool_assignment_telemetry failures: site=%s count=%d first_error=%s"
      site acc.count first_error)

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
            (* RFC-0121: layout SSOT via [Config_dir_resolver.data_dir]. *)
            let dir =
              Filename.concat
                (Config_dir_resolver.data_dir ~base_path)
                "tool-events"
            in
            Fs_compat.mkdir_p dir;
            let s = Dated_jsonl.create ~base_dir:dir () in
            store_ref := Some s;
            s)

(* ── Default config hash ──────────────────────────────── *)

let default_config_hash ~profile ~tool_list ~allow_set ~deny_set =
  let input = String.concat "|" (profile :: tool_list @ allow_set @ deny_set) in
  Digestif.SHA256.(digest_string input |> to_hex)

(* ── Public API ───────────────────────────────────────── *)

let emit_assigned_result
    ~agent_id
    ~profile
    ~tool_list
    ?(allow_set = [])
    ?(deny_set = [])
    ?config_hash
    ?(reason = "")
    () : (assignment_id, string) result =
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
      ; tool_list
      ; allow_set
      ; deny_set
      ; config_hash
      ; reason
      ; timestamp = Time_compat.now ()
      }
  in
  let store = get_or_create_store () in
  match Dated_jsonl.append_result store (event_to_json event) with
  | Error error -> Error error
  | Ok () ->
      Eio_guard.with_mutex index_mu (fun () ->
        Hashtbl.replace agent_index agent_id assignment_id);
      Ok assignment_id

let emit_assigned
    ~agent_id
    ~profile
    ~tool_list
    ?allow_set
    ?deny_set
    ?config_hash
    ?reason
    () : assignment_id =
  match
    emit_assigned_result
      ~agent_id
      ~profile
      ~tool_list
      ?allow_set
      ?deny_set
      ?config_hash
      ?reason
      ()
  with
  | Ok assignment_id -> assignment_id
  | Error error -> raise (Sys_error error)

let emit_called_result
    ~agent_id
    ~tool_name
    ?(arguments_hash = "")
    ~source
    () : (assignment_id option, string) result =
  let assignment_id_opt =
    Eio_guard.with_mutex_ro index_mu (fun () ->
      Hashtbl.find_opt agent_index agent_id)
  in
  match assignment_id_opt with
  | None -> Ok None
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
      (match Dated_jsonl.append_result store (event_to_json event) with
       | Error error -> Error error
       | Ok () -> Ok (Some assignment_id))

let emit_called
    ~agent_id
    ~tool_name
    ?arguments_hash
    ~source
    () : assignment_id option =
  match emit_called_result ~agent_id ~tool_name ?arguments_hash ~source () with
  | Ok assignment_id -> assignment_id
  | Error error -> raise (Sys_error error)

let emit_completed_result
    ~assignment_id
    ~tool_name
    ~success
    ~duration_ms
    ?error_kind
    () : (unit, string) result =
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
  Dated_jsonl.append_result store (event_to_json event)

let emit_completed ~assignment_id ~tool_name ~success ~duration_ms ?error_kind () : unit =
  match
    emit_completed_result
      ~assignment_id
      ~tool_name
      ~success
      ~duration_ms
      ?error_kind
      ()
  with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

let find_latest_assignment_id ~agent_id : assignment_id option =
  Eio_guard.with_mutex_ro index_mu (fun () ->
    Hashtbl.find_opt agent_index agent_id)

let read_recent ~n : (tool_event list, string) Result.t =
  try
    let store = get_or_create_store () in
    let jsons = Dated_jsonl.read_recent store n in
    let decode_failures = create_failure_acc () in
    let events =
      List.filter_map
        (fun json ->
          match event_of_json json with
          | Ok ev -> Some ev
          | Error msg ->
              add_decode_failure decode_failures msg;
              None)
        jsons
    in
    observe_decode_failures ~site:"read_recent_decode" decode_failures;
    (* Dated_jsonl returns oldest-first; API promises newest-first. *)
    Ok (List.rev events)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let error = Stdlib.Printexc.to_string exn in
      observe_failure ~site:"read_recent_exception" ~error;
      Error error

let warm_up () : unit =
  try
    let store = get_or_create_store () in
    let decode_failures = create_failure_acc () in
    Eio_guard.with_mutex index_mu (fun () ->
      Hashtbl.clear agent_index;
      Dated_jsonl.iter_all store (fun json ->
        match event_of_json json with
        | Ok (Assigned { assignment_id; agent_id; _ }) ->
          Hashtbl.replace agent_index agent_id assignment_id
        | Error msg -> add_decode_failure decode_failures msg
        | _ -> ()));
    observe_decode_failures ~site:"warm_up_decode" decode_failures
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let error = Stdlib.Printexc.to_string exn in
      observe_failure ~site:"warm_up_exception" ~error

let reset_for_testing () : unit =
  store_ref := None;
  Eio_guard.with_mutex index_mu (fun () -> Hashtbl.clear agent_index)

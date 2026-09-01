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
      { assignment_id; agent_id; profile; tool_list; config_hash; reason;
        timestamp } ->
      `Assoc
        [ ("event_type", `String "Assigned")
        ; ("assignment_id", `String assignment_id)
        ; ("agent_id", `String agent_id)
        ; ("profile", `String profile)
        ; ("tool_list", `List (List.map (fun s -> `String s) tool_list))
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

module Assignment_by_agent = Set_util.StringMap

type runtime_state = {
  epoch : int;
  revision : int;
  store : Dated_jsonl.t option;
  assignments : assignment_id Assignment_by_agent.t;
}

let runtime_state =
  Atomic.make
    {
      epoch = 0;
      revision = 0;
      store = None;
      assignments = Assignment_by_agent.empty;
    }

let store_lifecycle_lock = Cross_context_mutex.create ()

type active_runtime = {
  epoch : int;
  store : Dated_jsonl.t;
  assignments : assignment_id Assignment_by_agent.t;
}

let activate (runtime : runtime_state) store : active_runtime =
  { epoch = runtime.epoch; store; assignments = runtime.assignments }

let record_failure_metric ?(delta = 1.0) ~site () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_tool_assignment_telemetry_failures
    ~labels:[ ("site", site) ] ~delta ()

let observe_failure ~site ~error =
  record_failure_metric ~site ();
  Log.Telemetry.warn "tool_assignment_telemetry failure: site=%s error=%s"
    site error

type failure_acc = {
  count : int;
  first_error : string option;
}

let create_failure_acc () = { count = 0; first_error = None }

let add_decode_failure acc error =
  {
    count = acc.count + 1;
    first_error =
      (match acc.first_error with
       | Some _ as first_error -> first_error
       | None -> Some error);
  }

let observe_decode_failures ~site acc =
  if acc.count > 0 then (
    record_failure_metric ~site ~delta:(float_of_int acc.count) ();
    let first_error = Option.value ~default:"unknown" acc.first_error in
    Log.Telemetry.warn
      "tool_assignment_telemetry failures: site=%s count=%d first_error=%s"
      site acc.count first_error)

(* ── Store lifecycle ──────────────────────────────────── *)

let get_or_create_runtime () : active_runtime =
  let observed = Atomic.get runtime_state in
  match observed.store with
  | Some store -> activate observed store
  | None ->
    (* Store creation touches the filesystem and callers include tests that run
       outside an Eio scheduler. This cooperative cross-context lock owns only
       the rare initialise/reset effect; normal reads use the atomic snapshot. *)
    Cross_context_mutex.with_lock store_lifecycle_lock (fun () ->
      let current = Atomic.get runtime_state in
      match current.store with
      | Some store -> activate current store
      | None ->
        let base_path = Env_config.base_path () in
        (* RFC-0121: layout SSOT via [Config_dir_resolver.data_dir]. *)
        let dir =
          Filename.concat
            (Config_dir_resolver.data_dir ~base_path)
            "tool-events"
        in
        Fs_compat.mkdir_p dir;
        let store = Dated_jsonl.create ~base_dir:dir () in
        let next =
          { current with revision = current.revision + 1; store = Some store }
        in
        Atomic.set runtime_state next;
        activate next store)

let rec update_assignments_for_epoch epoch transition =
  let current = Atomic.get runtime_state in
  if current.epoch <> epoch
  then ()
  else (
    let next =
      {
        current with
        revision = current.revision + 1;
        assignments = transition current.assignments;
      }
    in
    if not (Atomic.compare_and_set runtime_state current next)
    then update_assignments_for_epoch epoch transition)

(* ── Default config hash ──────────────────────────────── *)

let default_config_hash ~profile ~tool_list =
  let input = String.concat "|" (profile :: tool_list) in
  Digestif.SHA256.(digest_string input |> to_hex)

(* ── Public API ───────────────────────────────────────── *)

let emit_assigned
    ~agent_id
    ~profile
    ~tool_list
    ?config_hash
    ?(reason = "")
    () : assignment_id =
  let assignment_id = Random_id.uuid_v7 () in
  let config_hash =
    match config_hash with
    | Some h -> h
    | None -> default_config_hash ~profile ~tool_list
  in
  let event =
    Assigned
      { assignment_id
      ; agent_id
      ; profile
      ; tool_list
      ; config_hash
      ; reason
      ; timestamp = Time_compat.now ()
      }
  in
  let runtime = get_or_create_runtime () in
  Dated_jsonl.append runtime.store (event_to_json event);
  update_assignments_for_epoch runtime.epoch (fun current ->
    Assignment_by_agent.add agent_id assignment_id current);
  assignment_id

let emit_called
    ~agent_id
    ~tool_name
    ?(arguments_hash = "")
    ~source
    () : assignment_id option =
  let runtime = get_or_create_runtime () in
  let assignment_id_opt =
    Assignment_by_agent.find_opt agent_id runtime.assignments
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
      Dated_jsonl.append runtime.store (event_to_json event);
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
  let runtime = get_or_create_runtime () in
  Dated_jsonl.append runtime.store (event_to_json event)

let find_latest_assignment_id ~agent_id : assignment_id option =
  Assignment_by_agent.find_opt agent_id (Atomic.get runtime_state).assignments

let read_recent ~n : (tool_event list, string) Result.t =
  try
    let runtime = get_or_create_runtime () in
    let jsons = Dated_jsonl.read_recent runtime.store n in
    let events, decode_failures =
      List.fold_left
        (fun (events, failures) json ->
          match event_of_json json with
          | Ok event -> event :: events, failures
          | Error error -> events, add_decode_failure failures error)
        ([], create_failure_acc ())
        jsons
    in
    observe_decode_failures ~site:"read_recent_decode" decode_failures;
    (* Dated_jsonl returns oldest-first; consing above produces newest-first. *)
    Ok events
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let error = Stdlib.Printexc.to_string exn in
      observe_failure ~site:"read_recent_exception" ~error;
      Error error

let rebuild_assignment_index store =
  let rebuilt = ref Assignment_by_agent.empty in
  let decode_failures = ref (create_failure_acc ()) in
  Dated_jsonl.iter_all store (fun json ->
    match event_of_json json with
    | Ok (Assigned { assignment_id; agent_id; _ }) ->
      rebuilt := Assignment_by_agent.add agent_id assignment_id !rebuilt
    | Error error ->
      decode_failures := add_decode_failure !decode_failures error
    | _ -> ());
  !rebuilt, !decode_failures

let rec publish_rebuilt_assignment_index () =
  let runtime = get_or_create_runtime () in
  let observed = Atomic.get runtime_state in
  if observed.epoch <> runtime.epoch
  then publish_rebuilt_assignment_index ()
  else (
    let rebuilt, decode_failures = rebuild_assignment_index runtime.store in
    let next =
      {
        observed with
        revision = observed.revision + 1;
        assignments = rebuilt;
      }
    in
    if Atomic.compare_and_set runtime_state observed next
    then decode_failures
    else publish_rebuilt_assignment_index ())

let warm_up () : unit =
  try
    let decode_failures = publish_rebuilt_assignment_index () in
    observe_decode_failures ~site:"warm_up_decode" decode_failures
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let error = Stdlib.Printexc.to_string exn in
      observe_failure ~site:"warm_up_exception" ~error

let reset_for_testing () : unit =
  Cross_context_mutex.with_lock store_lifecycle_lock (fun () ->
    let current = Atomic.get runtime_state in
    Atomic.set
      runtime_state
      {
        epoch = current.epoch + 1;
        revision = current.revision + 1;
        store = None;
        assignments = Assignment_by_agent.empty;
      })

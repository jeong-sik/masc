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

(** Tool_local_runtime_status -- runtime pool status reporting. *)

include Tool_local_runtime_core

type runtime_status_read_error =
  | Runtime_model_fetch_error of
      { base_url : string
      ; endpoint : string
      ; message : string
      }
  | Runtime_process_discovery_error of string

type runtime_status_with_errors =
  { status_json : Yojson.Safe.t
  ; read_errors : runtime_status_read_error list
  }

type runtime_status_dependencies =
  { fetch_models_at : string -> (string * string list, string) result
  ; discover_processes : unit -> (llama_process list, string) result
  }

let runtime_status_dependencies = ref { fetch_models_at; discover_processes }

module For_testing = struct
  let with_dependencies ~fetch_models_at ~discover_processes f =
    let previous = !runtime_status_dependencies in
    runtime_status_dependencies := { fetch_models_at; discover_processes };
    Fun.protect
      ~finally:(fun () -> runtime_status_dependencies := previous)
      f
  ;;
end

let active_fetch_models_at base_url = (!runtime_status_dependencies).fetch_models_at base_url

let active_discover_processes () =
  (!runtime_status_dependencies).discover_processes ()
;;

let runtime_status_read_error_to_string = function
  | Runtime_model_fetch_error { endpoint; message; base_url = _ } ->
    Printf.sprintf "model_fetch endpoint=%s: %s" endpoint message
  | Runtime_process_discovery_error message ->
    Printf.sprintf "process_discovery: %s" message
;;

let runtime_status_read_error_to_yojson = function
  | Runtime_model_fetch_error { base_url; endpoint; message } ->
    `Assoc
      [ "source", `String "model_fetch"
      ; "base_url", `String base_url
      ; "endpoint", `String endpoint
      ; "message", `String message
      ]
  | Runtime_process_discovery_error message ->
    `Assoc [ "source", `String "process_discovery"; "message", `String message ]
;;

let warn_runtime_status_read_errors errors =
  List.iter
    (fun error ->
       Log.Misc.warn
         "tool_local_runtime_status read_error: %s"
         (runtime_status_read_error_to_string error))
    errors
;;

let runtime_snapshot_to_yojson_with_errors ~include_models
    (snapshot : Local_runtime_pool.runtime_snapshot) =
  let endpoint =
    String.trim snapshot.base_url ^ Masc_network_defaults.openai_models_path
  in
  let fetched_models, model_error_fields, read_errors =
    if not include_models then [], [], []
    else
      match active_fetch_models_at snapshot.base_url with
      | Ok (_, models) -> models, [], []
      | Error message ->
        ( []
        , [ "model_fetch_error", `String message ]
        , [ Runtime_model_fetch_error { base_url = snapshot.base_url; endpoint; message } ]
        )
  in
  let base_fields =
    match Local_runtime_pool.snapshot_to_yojson snapshot with
    | `Assoc fields -> fields
    | json -> [ ("snapshot", json) ]
  in
  ( `Assoc
      (base_fields
       @ [ "endpoint", `String endpoint
         ; "models", `List (List.map (fun model -> `String model) fetched_models)
         ; "model_count", `Int (List.length fetched_models)
         ]
       @ model_error_fields)
  , read_errors
  )

let runtime_status_json_with_errors ?(include_models = true) () =
  let runtime_snapshots = Local_runtime_pool.snapshots () in
  let runtime_ports =
    runtime_snapshots
    |> List.filter_map (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
           runtime.port)
  in
  let process_result = active_discover_processes () in
  let processes, process_read_errors =
    match process_result with
    | Ok values -> values, []
    | Error message -> [], [ Runtime_process_discovery_error message ]
  in
  let matching_processes =
    List.filter (process_matches_runtime_ports runtime_ports) processes
  in
  let runtime_results =
    runtime_snapshots
    |> List.map (runtime_snapshot_to_yojson_with_errors ~include_models)
  in
  let runtime_json =
    runtime_results |> List.map fst
  in
  let model_read_errors =
    runtime_results |> List.concat_map snd
  in
  let read_errors = process_read_errors @ model_read_errors in
  let models =
    if not include_models then []
    else
      runtime_json
      |> List.concat_map (fun json ->
             match Json_util.assoc_member_opt "models" json with
             | Some (`List items) ->
                 List.filter_map
                   (function `String s -> Some s | _ -> None)
                   items
             | _ -> [])
      |> Json_util.dedupe_keep_order
  in
  let configured_capacity = Local_runtime_pool.configured_capacity () in
  let allocated_slots = Local_runtime_pool.allocated_slots () in
  let healthy_runtime_count = Local_runtime_pool.healthy_runtime_count () in
  let measured_ceiling = Local_runtime_pool.measured_ceiling () in
  let parse_errors = Local_runtime_pool.parse_errors () in
  let observations =
    []
    |> (fun items ->
         if configured_capacity < 64 then
           Printf.sprintf
             "Configured local llama capacity is %d; local64 needs shard pool capacity >= 64."
             configured_capacity
           :: items
         else items)
    |> (fun items ->
         if Stdlib.List.length matching_processes = 0 then
           "No local llama-server process matched the configured runtime pool."
           :: items
         else items)
    |> (fun items ->
         match process_result with
         | Ok _ -> items
         | Error message ->
           Printf.sprintf "Runtime process discovery failed: %s" message :: items)
    |> (fun items ->
         if List.exists (fun (proc : llama_process) -> proc.slots_enabled) matching_processes then
           "Matched llama-server process has --slots enabled."
           :: items
         else items)
    |> (fun items ->
         match parse_errors with
         | [] -> items
         | errors ->
             (Printf.sprintf "Runtime pool config issues: %s"
                (String.concat "; " errors))
             :: items)
    |> List.rev
  in
  { status_json =
      `Assoc
        [ "server_url", `String Env_config.Local_runtime.server_url
        ; ( "endpoint"
          , `String
              (Env_config.Local_runtime.server_url
               ^ Masc_network_defaults.openai_models_path) )
        ; "source", `String "llama.cpp runtime"
        ; "models", `List (List.map (fun model -> `String model) models)
        ; "model_count", `Int (List.length models)
        ; "configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models
        ; "target_parallelism", `Int configured_capacity
        ; "managed_gap_to_target", `Int 0
        ; "runtime_count", `Int (List.length runtime_snapshots)
        ; "healthy_runtime_count", `Int healthy_runtime_count
        ; "configured_capacity", `Int configured_capacity
        ; "allocated_slots", `Int allocated_slots
        ; "measured_ceiling", Json_util.int_opt_to_json measured_ceiling
        ; "process_count", `Int (List.length processes)
        ; "matching_process_count", `Int (List.length matching_processes)
        ; "runtime_config_errors", `List (List.map (fun item -> `String item) parse_errors)
        ; "runtime_status_read_error_count", `Int (List.length read_errors)
        ; ( "runtime_status_read_errors"
          , `List (List.map runtime_status_read_error_to_yojson read_errors) )
        ; "runtimes", `List runtime_json
        ; "processes", `List (List.map process_to_yojson matching_processes)
        ; "observations", `List (List.map (fun item -> `String item) observations)
        ]
  ; read_errors
  }

let runtime_status_json ?include_models () =
  let result = runtime_status_json_with_errors ?include_models () in
  warn_runtime_status_read_errors result.read_errors;
  result.status_json

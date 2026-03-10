include Cp_serde

let ensure_dirs config =
  Room_utils.mkdir_p (control_plane_dir config);
  Room_utils.mkdir_p (traces_dir config)

let read_units config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (units_path config)) then
    []
  else
    match Room_utils.read_json_opt config (units_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "units" fields with
        | Some (`List rows) -> List.filter_map unit_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map unit_of_json rows
    | _ -> []

let write_units config units =
  ensure_dirs config;
  Room_utils.write_json config (units_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("units", `List (List.map unit_to_json units));
      ])

let read_operations config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (operations_path config)) then
    []
  else
    match Room_utils.read_json_opt config (operations_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "operations" fields with
        | Some (`List rows) -> List.filter_map operation_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map operation_of_json rows
    | _ -> []

let write_operations config operations =
  ensure_dirs config;
  Room_utils.write_json config (operations_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("operations", `List (List.map operation_to_json operations));
      ])

let read_search_stats config =
  ensure_dirs config;
  Cp_search_fabric.load_store (search_stats_path config)

let write_search_stats config store =
  ensure_dirs config;
  Cp_search_fabric.save_store (search_stats_path config) store

let read_detachments config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (detachments_path config)) then
    []
  else
    match Room_utils.read_json_opt config (detachments_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "detachments" fields with
        | Some (`List rows) -> List.filter_map detachment_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map detachment_of_json rows
    | _ -> []

let write_detachments config detachments =
  ensure_dirs config;
  Room_utils.write_json config (detachments_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("detachments", `List (List.map detachment_to_json detachments));
      ])

let read_policy_decisions config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (decisions_path config)) then
    []
  else
    match Room_utils.read_json_opt config (decisions_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "decisions" fields with
        | Some (`List rows) -> List.filter_map policy_decision_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map policy_decision_of_json rows
    | _ -> []

let write_policy_decisions config decisions =
  ensure_dirs config;
  Room_utils.write_json config (decisions_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("decisions", `List (List.map policy_decision_to_json decisions));
      ])

let read_intents config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (intents_path config)) then
    []
  else
    match Room_utils.read_json_opt config (intents_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "intents" fields with
        | Some (`List rows) -> List.filter_map intent_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map intent_of_json rows
    | _ -> []

let write_intents config intents =
  ensure_dirs config;
  Room_utils.write_json config (intents_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("intents", `List (List.map intent_to_json intents));
      ])

let read_events config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (events_path config)) then
    []
  else
    In_channel.with_open_text (events_path config) (fun ic ->
        let rec loop acc =
          match input_line ic with
          | line ->
              let trimmed = String.trim line in
              let acc' =
                if trimmed = "" then
                  acc
                else
                  match Safe_ops.parse_json_safe ~context:"command_plane_v2.events" trimmed with
                  | Ok json -> (
                      match event_of_json json with
                      | Some event -> event :: acc
                      | None -> acc)
                  | Error _ -> acc
              in
              loop acc'
          | exception End_of_file -> List.rev acc
        in
        loop [])

let append_event config (event : event_record) =
  ensure_dirs config;
  let line = Yojson.Safe.to_string (event_to_json event) ^ "\n" in
  let path = events_path config in
  let oc = open_out_gen [ Open_creat; Open_append; Open_wronly ] 0o600 path in
  Common.protect ~module_name:"command_plane_v2" ~finally_label:"close_out"
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc line)

let next_event_id prefix =
  Printf.sprintf "%s-%s-%04x" prefix
    (Int64.to_string (Int64.of_float (Unix.gettimeofday () *. 1000.0)))
    (Random.bits () land 0xffff)

let next_operation_id () =
  next_event_id "op"

let next_intent_id () =
  next_event_id "intent"

let next_trace_id () =
  next_event_id "trace"

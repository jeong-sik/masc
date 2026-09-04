(** masc-trace — print typed runtime evidence matching a
    [(keeper, turn_id)] pair.

    Reads execution receipts, runtime manifests, FSM transition log details,
    and tool-call JSONL. Each source is filtered by its structured identity
    fields; presentation strings do not participate in routing.

    Usage:  masc-trace <base-path> <keeper> <turn_id>
    Example: masc-trace ~/me example-keeper 5
*)

let usage_and_exit () =
  prerr_endline "Usage: masc-trace <base-path> <keeper> <turn_id>";
  exit 2

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | line -> loop (line :: acc)
      | exception End_of_file -> List.rev acc
    in
    match loop [] with
    | lines ->
      close_in_noerr ic;
      lines
    | exception exn ->
      close_in_noerr ic;
      raise exn

let int_field json key =
  match Yojson.Safe.Util.member key json with `Int n -> Some n | _ -> None

let string_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let turn_fsm_transition_detail json =
  match Yojson.Safe.Util.member "details" json with
  | `Assoc fields ->
    List.assoc_opt "turn_fsm_transition" fields
    |> Option.map
         Keeper_transition_audit_types.turn_fsm_transition_of_json
  | _ -> None

let decision_int_field json key =
  Yojson.Safe.Util.member "decision" json |> fun decision ->
  int_field decision key

let decision_string_field json key =
  Yojson.Safe.Util.member "decision" json |> fun decision ->
  string_field decision key

let masc_root ~base_path = Config_dir_resolver.masc_root ~base_path

let receipts_dir ~base_path ~keeper =
  List.fold_left Filename.concat (masc_root ~base_path)
    [ "keepers"; keeper; "execution-receipts" ]

let runtime_manifests_dir ~base_path ~keeper =
  List.fold_left Filename.concat (masc_root ~base_path)
    [ "keepers"; keeper; "runtime-manifests" ]

let logs_dir ~base_path =
  List.fold_left Filename.concat (masc_root ~base_path) [ "logs" ]

let tool_calls_dir ~base_path =
  List.fold_left Filename.concat (masc_root ~base_path) [ "tool_calls" ]

(** Naive substring check — avoids pulling in [Str] for one call. *)
let dump_receipts ~base_path ~keeper ~turn_id =
  let dir = receipts_dir ~base_path ~keeper in
  if not (Sys.file_exists dir) then begin
    Printf.eprintf "[masc-trace] no receipts dir: %s\n" dir;
    ()
  end
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   if int_field json "turn_count" = Some turn_id then
                     Some (f, json)
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no receipt found for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun (f, json) ->
          let outcome =
            Option.value (string_field json "outcome") ~default:"-"
          in
          let reason =
            Option.value
              (string_field json "terminal_reason_code")
              ~default:"-"
          in
          let runtime =
            Option.value (string_field json "runtime_id") ~default:"-"
          in
          let ended =
            Option.value (string_field json "ended_at") ~default:"-"
          in
          Printf.printf
            "%s [receipt %s] runtime=%s outcome=%s reason=%s\n"
            ended f runtime outcome reason)
        matches

(** Scan [.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl]
    for manifest rows matching [keeper_turn_id].  This is the causal
    chain source: phase gate, runtime routing, provider attempts, context
    checkpoints, receipts, and terminal outcome. *)
let dump_runtime_manifests ~base_path ~keeper ~turn_id =
  let dir = runtime_manifests_dir ~base_path ~keeper in
  if not (Sys.file_exists dir) then
    Printf.eprintf "[masc-trace] no runtime-manifests dir: %s\n" dir
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   let keeper_match =
                     string_field json "keeper_name" = Some keeper
                   in
                   let turn_match =
                     int_field json "keeper_turn_id" = Some turn_id
                   in
                   if keeper_match && turn_match then Some (f, json)
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no runtime manifest found for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      let json_rows = List.map snd matches in
      let count_event event =
        json_rows
        |> List.fold_left
             (fun count json ->
               if string_field json "event" = Some event then count + 1
               else count)
             0
      in
      let max_agent_core_turn_count =
        json_rows
        |> List.filter_map (fun json -> int_field json "agent_core_turn_count")
        |> List.fold_left
             (fun acc value ->
               match acc with
               | None -> Some value
               | Some current -> Some (max current value))
             None
      in
      let event_bus_rows =
        json_rows
        |> List.filter (fun json ->
             string_field json "event" = Some "event_bus_correlated")
      in
      let event_bus_correlation =
        match
          event_bus_rows
          |> List.filter_map (fun json ->
               decision_string_field json "correlation_id")
        with
        | first :: _ -> first
        | [] -> "-"
      in
      Printf.printf
        "=== turn identity === keeper=%s keeper_turn_id=%d manifest_rows=%d \
         max_agent_core_turn_count=%s runtime_completed=%d runtime_failed=%d provider_lanes=%d \
         checkpoints_saved=%d receipts_appended=%d turn_finished=%d \
         event_bus=%d correlation_id=%s\n"
        keeper turn_id (List.length matches)
        (match max_agent_core_turn_count with
         | None -> "-"
         | Some value -> string_of_int value)
        (count_event "runtime_completed")
        (count_event "runtime_failed")
        (count_event "provider_lane_resolved")
        (count_event "checkpoint_saved")
        (count_event "receipt_appended")
        (count_event "turn_finished")
        (List.length event_bus_rows)
        event_bus_correlation;
      List.iter
        (fun (f, json) ->
          let ts = Option.value (string_field json "ts") ~default:"-" in
          let event = Option.value (string_field json "event") ~default:"-" in
          let status = Option.value (string_field json "status") ~default:"-" in
          let runtime =
            Option.value (string_field json "runtime_id") ~default:"-"
          in
          let decision =
            match Yojson.Safe.Util.member "decision" json with
            | `Null -> "{}"
            | decision_json -> Yojson.Safe.to_string decision_json
          in
          Printf.printf
            "%s [manifest %s] event=%s status=%s runtime=%s decision=%s\n"
            ts f event status runtime decision)
        matches

(** Scan [.masc/logs/system_log_*.jsonl] for typed FSM transition details
    matching the given [(keeper, turn_id)]. *)
let dump_fsm_transitions ~base_path ~keeper ~turn_id =
  let dir = logs_dir ~base_path in
  if not (Sys.file_exists dir) then ()
  else
    let files =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f ->
             Filename.check_suffix f ".jsonl"
             && String.length f >= String.length "system_log_"
             && String.sub f 0 (String.length "system_log_")
                = "system_log_")
      |> List.sort compare
    in
    let matches =
      List.concat_map
        (fun f ->
          let path = Filename.concat dir f in
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   if string_field json "keeper_name" <> Some keeper then None
                   else
                     (match turn_fsm_transition_detail json with
                      | None -> None
                      | Some (Ok transition)
                        when transition.turn_fsm_turn_id = turn_id ->
                        let ts =
                          Option.value (string_field json "ts") ~default:"-"
                        in
                        Some (ts, transition)
                      | Some (Ok _) -> None
                      | Some (Error error) ->
                        Printf.eprintf
                          "[masc-trace] warning: skipping malformed FSM \
                           transition in %s: %s\n"
                          f
                          error;
                        None)
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     f (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no typed FSM transitions for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun
          ( ts
          , (transition :
              Keeper_transition_audit_types.turn_fsm_transition_record) )
        ->
          let render_optional_bool name = function
            | Some value -> Printf.sprintf " %s=%b" name value
            | None -> ""
          in
          let stop_fields =
            render_optional_bool
              "stop_before"
              transition.turn_fsm_stop_signaled_before
            ^ render_optional_bool
                "stop_after"
                transition.turn_fsm_stop_signaled_after
          in
          Printf.printf
            "%s [fsm] %s -> %s action=%s%s\n"
            ts
            transition.turn_fsm_prev_state
            transition.turn_fsm_new_state
            transition.turn_fsm_action
            stop_fields)
        matches;
    (* An operator scanning for "did this turn reach done?" gets the typed
       destination path in one line without parsing presentation text. *)
    if matches <> [] then begin
      let state_with_ts =
        List.map
          (fun
            ( ts
            , (transition :
                Keeper_transition_audit_types.turn_fsm_transition_record) )
          ->
            transition.turn_fsm_new_state, ts)
          matches
      in
      let render (state, ts) = Printf.sprintf "%s @%s" state ts in
      Printf.printf "=== fsm path === %s -> %s\n" keeper
        (String.concat " -> " (List.map render state_with_ts))
    end

(** Scan [.masc/tool_calls/<YYYY-MM>/<DD>.jsonl] for tool call
    rows whose [keeper] = our keeper and
    [runtime_contract.keeper_turn_id] = our turn_id.

    Current identity fields:
    - top-level [keeper], [tool], [success], [duration_ms], [ts] (epoch float)
    - nested [runtime_contract.keeper_turn_id] (int option) *)
let dump_tool_calls ~base_path ~keeper ~turn_id =
  let root = tool_calls_dir ~base_path in
  if not (Sys.file_exists root) then ()
  else
    (* tool_calls/YYYY-MM/DD.jsonl — recurse one level. *)
    let month_dirs =
      Sys.readdir root
      |> Array.to_list
      |> List.filter (fun d ->
             Sys.is_directory (Filename.concat root d))
      |> List.sort compare
    in
    let files =
      List.concat_map
        (fun mdir ->
          let mpath = Filename.concat root mdir in
          Sys.readdir mpath
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
          |> List.sort compare
          |> List.map (fun f -> Filename.concat mpath f))
        month_dirs
    in
    let runtime_contract_int_field json key =
      match Yojson.Safe.Util.member "runtime_contract" json with
      | `Assoc _ as rc -> int_field rc key
      | _ -> None
    in
    let matches =
      List.concat_map
        (fun path ->
          read_lines path
          |> List.filter_map (fun line ->
                 try
                   let json = Yojson.Safe.from_string line in
                   let keeper_match =
                     string_field json "keeper" = Some keeper
                   in
                   let turn_match =
                     runtime_contract_int_field json
                       "keeper_turn_id"
                     = Some turn_id
                   in
                   if keeper_match && turn_match then Some json
                   else None
                 with exn ->
                   Printf.eprintf
                     "[masc-trace] warning: skipping malformed line in %s: %s\n"
                     (Filename.basename path)
                       (Printexc.to_string exn);
                   None))
        files
    in
    if matches = [] then
      Printf.eprintf
        "[masc-trace] no tool_calls for keeper=%s turn_id=%d\n"
        keeper turn_id
    else
      List.iter
        (fun json ->
          let tool =
            Option.value (string_field json "tool") ~default:"-"
          in
          let success =
            match Yojson.Safe.Util.member "success" json with
            | `Bool b -> if b then "ok" else "fail"
            | _ -> "-"
          in
          let duration_ms =
            match Yojson.Safe.Util.member "duration_ms" json with
            | `Float f -> Printf.sprintf "%.0f" f
            | `Int n -> string_of_int n
            | _ -> "-"
          in
          let ts =
            match Yojson.Safe.Util.member "ts" json with
            | `Float f -> Printf.sprintf "%.3f" f
            | `Int n -> string_of_int n
            | _ -> "-"
          in
          Printf.printf
            "%s [tool %s] %s duration_ms=%s\n"
            ts tool success duration_ms)
        matches

let () =
  match Array.to_list Sys.argv with
  | _ :: base_path :: keeper :: turn_id_str :: _ -> (
      match int_of_string_opt turn_id_str with
      | Some turn_id ->
          dump_receipts ~base_path ~keeper ~turn_id;
          dump_runtime_manifests ~base_path ~keeper ~turn_id;
          dump_fsm_transitions ~base_path ~keeper ~turn_id;
          dump_tool_calls ~base_path ~keeper ~turn_id
      | None ->
          prerr_endline "turn_id must be an integer";
          usage_and_exit ())
  | _ -> usage_and_exit ()

(** Per-keeper autonomous practice summary. See the .mli for the contract. *)

open Dashboard_http_keeper_types

type turn_outcome =
  | Success
  | Checkpoint
  | Input_required
  | Error

let turn_outcome_to_string = function
  | Success -> "success"
  | Checkpoint -> "checkpoint"
  | Input_required -> "input_required"
  | Error -> "error"
;;

let turn_outcome_of_string raw =
  match String.trim raw with
  | "success" -> Some Success
  | "checkpoint" -> Some Checkpoint
  | "input_required" -> Some Input_required
  | "error" -> Some Error
  | _ -> None
;;

(* Mirrors Keeper_unified_metrics_decision.execution_path wire labels. A new
   writer label parses to None and its rows count as unrecognized. *)
type path =
  | Direct
  | Autonomous

let path_of_string raw =
  match String.trim raw with
  | "direct_turn" -> Some Direct
  | "autonomous_cycle" -> Some Autonomous
  | _ -> None
;;

module String_histogram = Map.Make (String)

type accumulator =
  { tail_rows : int
  ; turn_rows : int
  ; unrecognized_turn_rows : int
  ; direct_turns : int
  ; autonomous_turns : int
  ; mode_tool_use : int
  ; mode_text_response : int
  ; mode_skip_text : int
  ; mode_noop : int
  ; mode_absent : int
  ; outcome_success : int
  ; outcome_checkpoint : int
  ; outcome_input_required : int
  ; outcome_error : int
  ; terminal_code_absent_on_error : int
  ; terminal_codes : int String_histogram.t
  ; triggers : int String_histogram.t
  ; tools : int String_histogram.t
  ; tool_calls_total : int
  ; latency_ms_total : int
  ; latency_ms_count : int
  ; latency_ms_max : int option
  ; since_unix : float option
  ; until_unix : float option
  }

let empty_accumulator =
  { tail_rows = 0
  ; turn_rows = 0
  ; unrecognized_turn_rows = 0
  ; direct_turns = 0
  ; autonomous_turns = 0
  ; mode_tool_use = 0
  ; mode_text_response = 0
  ; mode_skip_text = 0
  ; mode_noop = 0
  ; mode_absent = 0
  ; outcome_success = 0
  ; outcome_checkpoint = 0
  ; outcome_input_required = 0
  ; outcome_error = 0
  ; terminal_code_absent_on_error = 0
  ; terminal_codes = String_histogram.empty
  ; triggers = String_histogram.empty
  ; tools = String_histogram.empty
  ; tool_calls_total = 0
  ; latency_ms_total = 0
  ; latency_ms_count = 0
  ; latency_ms_max = None
  ; since_unix = None
  ; until_unix = None
  }
;;

type summary =
  { keeper_name : string
  ; acc : accumulator
  }

let bump histogram label =
  let count =
    match String_histogram.find_opt label histogram with
    | None -> 1
    | Some n -> n + 1
  in
  String_histogram.add label count histogram
;;

let sorted_histogram histogram =
  String_histogram.bindings histogram
  |> List.sort (fun (la, ca) (lb, cb) ->
    match compare cb ca with
    | 0 -> String.compare la lb
    | order -> order)
;;

let string_member_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`String s) ->
    let trimmed = String.trim s in
    if String.equal trimmed "" then None else Some trimmed
  | _ -> None
;;

let float_member_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`Float f) when Float.is_finite f -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let int_member_opt key json =
  match Json_util.assoc_member_opt key json with
  | Some (`Int i) -> Some i
  | Some (`Float f) when Float.is_finite f -> Some (int_of_float f)
  | _ -> None
;;

let string_list_member key json =
  match Json_util.assoc_member_opt key json with
  | Some (`List items) ->
    List.filter_map
      (function
        | `String s ->
          let trimmed = String.trim s in
          if String.equal trimmed "" then None else Some trimmed
        | _ -> None)
      items
  | _ -> []
;;

let extend_window acc ts =
  let since_unix =
    match acc.since_unix with
    | None -> Some ts
    | Some lo -> Some (Float.min lo ts)
  in
  let until_unix =
    match acc.until_unix with
    | None -> Some ts
    | Some hi -> Some (Float.max hi ts)
  in
  { acc with since_unix; until_unix }
;;

let fold_turn_row acc json =
  let acc = { acc with turn_rows = acc.turn_rows + 1 } in
  let path = Option.bind (string_member_opt "execution_path" json) path_of_string in
  let outcome = Option.bind (string_member_opt "outcome" json) turn_outcome_of_string in
  match path, outcome with
  | None, _ | _, None -> { acc with unrecognized_turn_rows = acc.unrecognized_turn_rows + 1 }
  | Some Direct, _ -> { acc with direct_turns = acc.direct_turns + 1 }
  | Some Autonomous, outcome ->
    let acc = { acc with autonomous_turns = acc.autonomous_turns + 1 } in
    let acc =
      match outcome with
      | Success -> { acc with outcome_success = acc.outcome_success + 1 }
      | Checkpoint -> { acc with outcome_checkpoint = acc.outcome_checkpoint + 1 }
      | Input_required ->
        { acc with outcome_input_required = acc.outcome_input_required + 1 }
      | Error -> { acc with outcome_error = acc.outcome_error + 1 }
    in
    let acc =
      match
        Option.bind (string_member_opt "turn_mode" json) Turn_mode_codec.turn_mode_of_string
      with
      | Some Turn_mode_codec.Tool_use -> { acc with mode_tool_use = acc.mode_tool_use + 1 }
      | Some Turn_mode_codec.Text_response ->
        { acc with mode_text_response = acc.mode_text_response + 1 }
      | Some Turn_mode_codec.Skip_text -> { acc with mode_skip_text = acc.mode_skip_text + 1 }
      | Some Turn_mode_codec.Noop -> { acc with mode_noop = acc.mode_noop + 1 }
      | None -> { acc with mode_absent = acc.mode_absent + 1 }
    in
    let acc =
      match outcome with
      | Error ->
        (match string_member_opt "terminal_reason_code" json with
         | Some code -> { acc with terminal_codes = bump acc.terminal_codes code }
         | None ->
           { acc with terminal_code_absent_on_error = acc.terminal_code_absent_on_error + 1 })
      | Success | Checkpoint | Input_required -> acc
    in
    let triggers = List.fold_left bump acc.triggers (string_list_member "trigger_signals" json) in
    let tools = List.fold_left bump acc.tools (string_list_member "tools_used" json) in
    let tool_calls_total =
      match int_member_opt "tool_call_count" json with
      | Some count -> acc.tool_calls_total + count
      | None -> acc.tool_calls_total
    in
    let latency_ms_total, latency_ms_count, latency_ms_max =
      match int_member_opt "latency_ms" json with
      | None -> acc.latency_ms_total, acc.latency_ms_count, acc.latency_ms_max
      | Some latency ->
        let max =
          match acc.latency_ms_max with
          | None -> Some latency
          | Some hi -> Some (max hi latency)
        in
        acc.latency_ms_total + latency, acc.latency_ms_count + 1, max
    in
    let acc =
      { acc with
        triggers
      ; tools
      ; tool_calls_total
      ; latency_ms_total
      ; latency_ms_count
      ; latency_ms_max
      }
    in
    (match float_member_opt "ts_unix" json with
     | None -> acc
     | Some ts -> extend_window acc ts)
;;

let is_turn_row json =
  match Json_util.assoc_member_opt "event" json with
  | Some (`String s) -> String.equal (String.trim s) "turn"
  | _ -> false
;;

let summarize_rows ~keeper_name rows =
  let acc =
    List.fold_left
      (fun acc json ->
        let acc = { acc with tail_rows = acc.tail_rows + 1 } in
        if is_turn_row json then fold_turn_row acc json else acc)
      empty_accumulator
      rows
  in
  { keeper_name; acc }
;;

let float_opt_json = function
  | None -> `Null
  | Some f -> `Float f
;;

let int_opt_json = function
  | None -> `Null
  | Some i -> `Int i
;;

let label_list_json histogram =
  `List
    (List.map
       (fun (label, count) -> `Assoc [ "label", `String label; "count", `Int count ])
       (sorted_histogram histogram))
;;

let to_json { keeper_name; acc } =
  `Assoc
    [ "schema", `String "keeper.practice.v1"
    ; "keeper", `String keeper_name
    ; ( "window"
      , `Assoc
          [ "tail_rows", `Int acc.tail_rows
          ; "turn_rows", `Int acc.turn_rows
          ; "unrecognized_turn_rows", `Int acc.unrecognized_turn_rows
          ; "since_unix", float_opt_json acc.since_unix
          ; "until_unix", float_opt_json acc.until_unix
          ] )
    ; ( "paths"
      , `Assoc
          [ "autonomous_cycle", `Int acc.autonomous_turns
          ; "direct_turn", `Int acc.direct_turns
          ] )
    ; ( "autonomous"
      , `Assoc
          [ "turns", `Int acc.autonomous_turns
          ; ( "modes"
            , `Assoc
                [ "tool_use", `Int acc.mode_tool_use
                ; "text_response", `Int acc.mode_text_response
                ; "skip_text", `Int acc.mode_skip_text
                ; "noop", `Int acc.mode_noop
                ; "absent", `Int acc.mode_absent
                ] )
          ; ( "outcomes"
            , `Assoc
                [ "success", `Int acc.outcome_success
                ; "checkpoint", `Int acc.outcome_checkpoint
                ; "input_required", `Int acc.outcome_input_required
                ; "error", `Int acc.outcome_error
                ] )
          ; "terminal_code_absent_on_error", `Int acc.terminal_code_absent_on_error
          ; "terminal_codes", label_list_json acc.terminal_codes
          ; "triggers", label_list_json acc.triggers
          ; ( "tools"
            , `Assoc
                [ "total_calls", `Int acc.tool_calls_total
                ; "by_name", label_list_json acc.tools
                ] )
          ; ( "latency_ms"
            , `Assoc
                [ "total", `Int acc.latency_ms_total
                ; "count", `Int acc.latency_ms_count
                ; "max", int_opt_json acc.latency_ms_max
                ] )
          ] )
    ]
;;

let summarize_keeper config (meta : Keeper_meta_contract.keeper_meta) ?(limit = 200) () =
  let limit = k2_feed_limit limit in
  let path = Keeper_types_support.keeper_decision_log_path config meta.name in
  if not (Fs_compat.file_exists path)
  then summarize_rows ~keeper_name:meta.name []
  else (
    let lines =
      Dashboard_http_helpers.keeper_tail_lines_or_empty
        ~site:"dashboard_keeper_practice"
        path
        ~max_bytes:500_000
        ~max_lines:limit
    in
    let rows =
      List.filter_map
        (fun line ->
          match Yojson.Safe.from_string line with
          | json -> Some json
          | exception (Yojson.Json_error _) -> None)
        lines
    in
    summarize_rows ~keeper_name:meta.name rows)
;;

let fleet_json config keepers ?(limit = 200) () =
  let now_ts = Time_compat.now () in
  let items =
    List.map (fun meta -> to_json (summarize_keeper config meta ~limit ())) keepers
  in
  `Assoc
    [ "keepers", `List items
    ; "limit", `Int (k2_feed_limit limit)
    ; "generated_at", `Float now_ts
    ]
;;

(** See [turn_mode_codec.mli] for documentation.

    RFC-0182 §3.1 cycle break: pure codec extracted from
    [Keeper_unified_metrics_support] so [Tool_agent_timeline] can parse
    keeper turn payloads without importing [lib/keeper], which previously
    formed a cycle with [Keeper_tool_in_process_runtime]. *)

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

let turn_mode_to_string = function
  | Tool_use -> "tool_use"
  | Text_response -> "text_response"
  | Skip_text -> "skip_text"
  | Noop -> "noop"

let turn_mode_of_string (raw : string) : turn_mode option =
  match String.trim raw with
  | "tool_use" -> Some Tool_use
  | "text_response" -> Some Text_response
  | "skip_text" -> Some Skip_text
  | "noop" -> Some Noop
  | _ -> None

let work_kind_of_turn_mode = function
  | Tool_use -> "tool_use"
  | Noop -> "noop"
  | Text_response | Skip_text -> "text_turn"

let turn_mode_of_json (json : Yojson.Safe.t) : turn_mode option =
  match Safe_ops.json_string_opt "turn_mode" json with
  | Some raw -> turn_mode_of_string raw
  | None ->
      (match Safe_ops.json_string_opt "selected_mode" json with
       | Some raw -> turn_mode_of_string raw
       | None ->
           match Safe_ops.json_string_opt "work_kind" json with
           | Some "tool_use" -> Some Tool_use
           | Some "noop" -> Some Noop
           | Some "text_turn" -> Some Text_response
           | _ -> None)

let work_kind_of_json (json : Yojson.Safe.t) : string option =
  match turn_mode_of_json json with
  | Some mode -> Some (work_kind_of_turn_mode mode)
  | None ->
      (match Safe_ops.json_string_opt "work_kind" json with
       | Some raw ->
           let value = String.trim raw in
           if value = "" then None else Some value
       | None -> None)

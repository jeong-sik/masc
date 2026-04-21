open! Core

type agent_brief =
  { agent_name : string
  ; display_name : string option
  ; is_live : bool option
  ; status : string option
  ; current_work : string option
  ; last_activity_at : string option
  ; last_activity_age_sec : float option
  ; signal_truth : string option
  ; evidence_source : string option
  ; recent_input_preview : string option
  ; recent_output_preview : string option
  ; recent_tool_names : string list
  ; latest_tool_names : string list
  ; latest_tool_call_count : int option
  ; tool_audit_source : string option
  ; tool_audit_at : string option
  }

type keeper_brief =
  { name : string
  ; agent_name : string option
  ; status : string option
  ; generation : int option
  ; context_ratio : float option
  ; last_turn_ago_s : float option
  ; current_work : string option
  ; last_autonomous_action_at : string option
  ; latest_tool_names : string list
  ; latest_tool_call_count : int option
  ; tool_audit_source : string option
  ; tool_audit_at : string option
  }

type response =
  { generated_at : string
  ; agent_briefs : agent_brief list
  ; keeper_briefs : keeper_brief list
  }

let fixture : response =
  { generated_at = ""; agent_briefs = []; keeper_briefs = [] }
;;

let string_field ?(default = "") json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | _ -> default
;;

let string_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `String s ->
    let trimmed = String.strip s in
    if String.is_empty trimmed then None else Some trimmed
  | _ -> None
;;

let int_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Some i
  | `Intlit s -> Option.try_with (fun () -> Int.of_string s)
  | _ -> None
;;

let float_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Float f -> Some f
  | `Int i -> Some (Float.of_int i)
  | `Intlit s -> Option.try_with (fun () -> Float.of_string s)
  | _ -> None
;;

let bool_opt_field json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Some b
  | _ -> None
;;

let string_list_field json key =
  match Yojson.Safe.Util.member key json with
  | `List xs ->
    List.filter_map xs ~f:(function
      | `String s ->
        let trimmed = String.strip s in
        if String.is_empty trimmed then None else Some trimmed
      | _ -> None)
  | _ -> []
;;

let list_field f json key =
  match Yojson.Safe.Util.member key json with
  | `List xs -> List.map xs ~f
  | _ -> []
;;

let agent_brief_of_yojson json =
  { agent_name = string_field json "agent_name"
  ; display_name = string_opt_field json "display_name"
  ; is_live = bool_opt_field json "is_live"
  ; status = string_opt_field json "status"
  ; current_work = string_opt_field json "current_work"
  ; last_activity_at = string_opt_field json "last_activity_at"
  ; last_activity_age_sec = float_opt_field json "last_activity_age_sec"
  ; signal_truth = string_opt_field json "signal_truth"
  ; evidence_source = string_opt_field json "evidence_source"
  ; recent_input_preview = string_opt_field json "recent_input_preview"
  ; recent_output_preview = string_opt_field json "recent_output_preview"
  ; recent_tool_names = string_list_field json "recent_tool_names"
  ; latest_tool_names = string_list_field json "latest_tool_names"
  ; latest_tool_call_count = int_opt_field json "latest_tool_call_count"
  ; tool_audit_source = string_opt_field json "tool_audit_source"
  ; tool_audit_at = string_opt_field json "tool_audit_at"
  }
;;

let keeper_brief_of_yojson json =
  { name = string_field json "name"
  ; agent_name = string_opt_field json "agent_name"
  ; status = string_opt_field json "status"
  ; generation = int_opt_field json "generation"
  ; context_ratio = float_opt_field json "context_ratio"
  ; last_turn_ago_s = float_opt_field json "last_turn_ago_s"
  ; current_work = string_opt_field json "current_work"
  ; last_autonomous_action_at = string_opt_field json "last_autonomous_action_at"
  ; latest_tool_names = string_list_field json "latest_tool_names"
  ; latest_tool_call_count = int_opt_field json "latest_tool_call_count"
  ; tool_audit_source = string_opt_field json "tool_audit_source"
  ; tool_audit_at = string_opt_field json "tool_audit_at"
  }
;;

let response_of_yojson json =
  { generated_at = string_field json "generated_at"
  ; agent_briefs = list_field agent_brief_of_yojson json "agent_briefs"
  ; keeper_briefs = list_field keeper_brief_of_yojson json "keeper_briefs"
  }
;;

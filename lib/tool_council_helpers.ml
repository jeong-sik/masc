(** Council tools — helpers and parsers for Governance V2. *)

open Yojson.Safe.Util
open Tool_args

module GV2 = Council.Governance_v2

type context = {
  base_path : string;
  agent_name : string;
  room_config : Room.config option;
}

type result = bool * string

let gen_id prefix =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "%s-%d-%06x" prefix ts hash

let room_config_of_ctx (ctx : context) =
  match ctx.room_config with
  | Some config -> config
  | None -> Room.default_config ctx.base_path |> Room.config_with_resolved_scope

let ensure_room_ready (ctx : context) =
  let config = room_config_of_ctx ctx in
  (if not (Room.is_initialized config) then
    let (_init_msg : string) = Room.init config ~agent_name:(Some ctx.agent_name) in
    ());
  config

let contains_text haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= hay_len
    && ((String.sub haystack idx needle_len = needle) || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let extract_task_id text =
  let len = String.length text in
  let rec seek idx =
    if idx + 5 > len then None
    else if String.sub text idx 5 = "task-" then
      let stop = ref (idx + 5) in
      while
        !stop < len
        &&
        match text.[!stop] with
        | '0' .. '9' -> true
        | _ -> false
      do
        incr stop
      done;
      if !stop > idx + 5 then Some (String.sub text idx (!stop - idx))
      else seek (idx + 1)
    else seek (idx + 1)
  in
  seek 0

let first_some = Dashboard_utils.first_some

let supported_execution_action_types =
  [
    "add_task";
    "start_operation";
    "set_param";
    "release_task";
    "restart_keeper";
    "flag_post";
  ]

let resolve_target_id ?payload ~prefix (case_ : GV2.case_record)
    (request : GV2.action_request) =
  let payload_target =
    match payload with
    | Some payload ->
        payload |> member "target_id" |> to_string_option
        |> fun value -> first_some value (payload |> member "task_id" |> to_string_option)
        |> fun value -> first_some value (payload |> member "post_id" |> to_string_option)
        |> fun value -> first_some value (payload |> member "keeper_name" |> to_string_option)
    | None -> None
  in
  let from_source_refs =
    case_.GV2.source_refs
    |> List.find_map (fun ref_ ->
           if String.starts_with ~prefix ref_ && String.length ref_ > String.length prefix
           then
             Some
               (String.sub ref_ (String.length prefix)
                  (String.length ref_ - String.length prefix))
           else None)
  in
  request.GV2.target_id |> fun value -> first_some value payload_target
  |> fun value -> first_some value from_source_refs

let parse_requested_action args =
  match member "requested_action" args with
  | `Null -> Ok None
  | (`Assoc _ as value) -> (
      match member "action_type" value with
      | `Null | `String "" ->
          Error "requested_action.action_type is required"
      | `String s when String.trim s = "" ->
          Error "requested_action.action_type is required"
      | `String _ -> (
          match GV2.action_request_of_yojson value with
          | Error msg -> Error ("requested_action: " ^ msg)
          | Ok request ->
              let action_type = String.trim request.GV2.action_type in
              if
                not
                  (List.mem
                     (String.lowercase_ascii action_type)
                     supported_execution_action_types)
              then
                Error
                  (Printf.sprintf
                     "unsupported requested_action.action_type: %s"
                     action_type)
              else
                Ok (Some { request with action_type }))
      | _ -> Error "requested_action.action_type must be a string")
  | _ -> Error "requested_action must be an object"

let high_risk_action_types =
  [
    "delete";
    "reset";
    "merge";
    "room_pause";
    "room_resume";
    "team_stop";
    "keeper_recover";
  ]

let derive_risk_class args requested_action =
  match get_string args "risk_class" "" |> String.lowercase_ascii with
  | "low" -> Ok GV2.Low
  | "high" -> Ok GV2.High
  | "" -> (
      match requested_action with
      | Some request
        when List.mem
               (String.lowercase_ascii request.GV2.action_type)
               high_risk_action_types ->
          Ok GV2.High
      | _ -> Ok GV2.Low)
  | value -> Error (Printf.sprintf "invalid risk_class: %s" value)

let parse_stance args =
  match get_string args "stance" "support" |> String.lowercase_ascii with
  | "support" -> Ok GV2.Support
  | "oppose" -> Ok GV2.Oppose
  | "neutral" -> Ok GV2.Neutral
  | value -> Error (Printf.sprintf "invalid stance: %s" value)

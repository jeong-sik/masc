open Tool_args
include Operator_control_snapshot
type 'a context = 'a Tool_operator.context

open Result.Syntax

let judgment_surface_enums =
  [ "command.namespace"; "intervene" ]

let normalize_judgment_surface value =
  let normalized = String.trim value |> String.lowercase_ascii in
  match normalized with
  | "command.namespace" -> Ok "command.namespace"
  | "intervene" -> Ok normalized
  | _ -> Error "surface must be one of command.namespace, intervene"

let normalize_judgment_target_type value =
  let normalized = String.trim value |> String.lowercase_ascii in
  match Operator_judgment.target_type_of_string normalized with
  | Some target_type ->
      Ok (Operator_judgment.target_type_to_string target_type, target_type)
  | None -> Error Operator_action_constants.workspace_target_type_error

let default_fresh_ttl_sec surface =
  match surface with
  | "command.namespace" -> 60
  | "intervene" -> 300
  | _ -> 120

let judgment_write_json (ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  let summary = get_string args "summary" "" |> String.trim in
  if summary = "" then Error "summary is required"
  else
    let now_unix = Unix.gettimeofday () in
    let generated_at = Masc_domain.iso8601_of_unix_seconds now_unix in
    let fresh_ttl_sec =
      let default = default_fresh_ttl_sec surface in
      max 1 (get_int args "fresh_ttl_sec" default)
    in
    let fresh_until_unix = now_unix +. float_of_int fresh_ttl_sec in
    let fresh_until = Masc_domain.iso8601_of_unix_seconds fresh_until_unix in
    let confidence = get_float args "confidence" 0.5 in
    let keeper_name =
      match get_string_opt args "keeper_name" with
      | Some raw ->
          let trimmed = String.trim raw in
          if trimmed <> "" then trimmed
          else normalized_actor ~context_actor:ctx.agent_name None
      | None -> normalized_actor ~context_actor:ctx.agent_name None
    in
    let evidence_refs = Json_util.get_string_list args "evidence_refs"
    in
    let recommended_action = Json_util.get_object args "recommended_action" in
    let judgment =
      Operator_judgment.record ctx.config ~surface
        ~target_type:judgment_target_type ~target_id ~summary ~confidence
        ?model_name:(get_string_opt args "model_name")
        ?runtime_name:(get_string_opt args "runtime_name")
        ?recommended_action ~evidence_refs
        ~fallback_used:(get_bool args "fallback_used" false)
        ~disagreement_with_truth:
          (get_bool args "disagreement_with_truth" false)
        ~generated_at ~generated_at_unix:now_unix ~fresh_until ~fresh_until_unix
        ~keeper_name ()
    in
    Ok
      (Tool_args.ok_assoc
         [ ("judgment", Operator_judgment.to_yojson judgment) ])

let judgment_latest_json (_ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  let require_fresh = get_bool args "require_fresh" true in
  let judgment =
    match
      Operator_judgment.latest_active _ctx.config ~surface
        ~target_type:judgment_target_type ~target_id
    with
    | Some value when (not require_fresh) || Operator_judgment.is_fresh value ->
        Some value
    | _ -> None
  in
  Ok
    (Tool_args.ok_assoc
       [
         ( "judgment",
           match judgment with
           | Some value -> Operator_judgment.to_yojson value
           | None -> `Null );
       ])

type action_request = {
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
}

let canonical_action_type action_type = action_type

let normalize_action_target_type target_type =
  let normalized = String.trim target_type |> String.lowercase_ascii in
  if String.equal normalized ""
  then Ok ""
  else
    match Operator_action_constants.target_type_of_string normalized with
    | Some target_type ->
        Ok (Operator_action_constants.target_type_to_string target_type)
    | None -> Error Operator_action_constants.invalid_target_type_message

let default_target_type_for action_type =
  match action_type with
  | "broadcast" | "namespace_pause" | "namespace_resume" | "task_inject" | "social_sweep"
    -> Operator_action_constants.workspace_target_type
  | action when String.equal action Operator_action_constants.goal_completion_decision ->
    Operator_action_constants.goal_target_type
  | "keeper_message" | "keeper_probe" -> Operator_action_constants.keeper_target_type
  | action when String.equal action Operator_action_constants.keeper_recover ->
      Operator_action_constants.keeper_target_type
  | _ -> ""

let generate_confirm_token ~(clock : _ Eio.Time.clock) config =
  let max_attempts = 10 in
  let rec loop attempts =
    if attempts >= max_attempts then
      Error (Printf.sprintf
        "failed to generate unique confirm token after %d attempts \
         (token space may be exhausted; %d pending confirms)"
        max_attempts
        (List.length (raw_pending_confirms config)))
    else
      let token = "opc_" ^ String.sub (Auth.generate_token ()) 0 32 in
      let exists =
        raw_pending_confirms config
        |> List.exists (fun entry -> String.equal entry.token token)
      in
      if exists then begin
        (* Exponential backoff: 1ms, 2ms, 4ms, ... up to ~512ms *)
        let backoff_s = float_of_int (1000 * (1 lsl (min attempts 9))) /. 1_000_000.0 in
        Eio.Time.sleep clock backoff_s;
        loop (attempts + 1)
      end else Ok token
  in
  loop 0

let resolved_actor_for_args ?actor_hint (ctx : 'a context) args =
  let payload_actor = get_string_opt args "actor" |> Option.map String.trim in
  let hinted_actor = actor_hint |> Option.map String.trim in
  Ok
    (normalized_actor ~context_actor:ctx.agent_name
       (match hinted_actor with
       | Some actor when actor <> "" -> Some actor
       | _ -> payload_actor))

let action_request_of_args ?actor_hint (ctx : 'a context) args =
  let action_type =
    get_string args "action_type" "" |> String.trim |> String.lowercase_ascii
    |> canonical_action_type
  in
  let raw_target_type =
    get_string args "target_type" "" |> String.trim |> String.lowercase_ascii
  in
  let* actor = resolved_actor_for_args ?actor_hint ctx args in
  Ok
    {
      actor;
      action_type;
      target_type =
        if raw_target_type <> "" then raw_target_type
        else default_target_type_for action_type;
      target_id = get_string_opt args "target_id";
      payload = get_payload args;
    }

let normalize_request_target_type (request : action_request) =
  let* target_type =
    if request.target_type <> "" then normalize_action_target_type request.target_type
    else Ok (default_target_type_for request.action_type)
  in
  Ok { request with target_type }

(** Resolve the public operator entry point for a registered action type. *)
let delegated_tool_for action_type =
  match
    List.find_opt
      (fun (a : Operator_pending_confirm.available_action) ->
        String.equal a.action_type action_type)
      Operator_pending_confirm.available_actions
  with
  | Some action -> Ok action.tool_name
  | None -> Error (Printf.sprintf "unregistered operator action type: %s" action_type)

let confirm_required = Operator_approval.confirm_required

let preview_of_action (request : action_request) =
  let base =
    [
      ("actor", `String request.actor);
      ("action_type", `String request.action_type);
      ("target_type", `String request.target_type);
      ("target_id", Json_util.string_opt_to_json request.target_id);
    ]
  in
  let payload_fields =
    match request.payload with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base @ [ ("payload", `Assoc payload_fields) ])

let validate_target_type expected request =
  match Operator_action_constants.target_type_of_string request.target_type with
  | Some actual when actual = expected -> Ok ()
  | Some _ | None ->
    Error
      (Printf.sprintf
         "invalid target_type for %s (expected %s)"
         request.action_type
         (Operator_action_constants.target_type_to_string expected))

let require_target_id request =
  match request.target_id with
  | Some target_id -> Ok target_id
  | None -> Error "target_id is required"

let require_payload_field payload key error_message =
  match get_string_opt payload key with
  | Some value -> Ok value
  | None -> Error error_message

(* parse_turn_kind removed — team session turn types deleted. *)

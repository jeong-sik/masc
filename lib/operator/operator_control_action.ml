open Tool_args
include Operator_control_snapshot

open Result_syntax

let judgment_surface_enums =
  [ "command.namespace"; "command.swarm"; "intervene" ]

let normalize_judgment_surface value =
  let normalized = String.trim value |> String.lowercase_ascii in
  match normalized with
  | "command.namespace" -> Ok "command.namespace"
  | "command.swarm" | "intervene" -> Ok normalized
  | _ -> Error "surface must be one of command.namespace, command.swarm, intervene"

let normalize_judgment_target_type value =
  let normalized = String.trim value |> String.lowercase_ascii in
  match normalized with
  | "room" | "namespace" -> Ok ("namespace", Operator_judgment.Room)
  | "team_session" -> Ok ("team_session", Operator_judgment.Team_session)
  | _ -> Error "target_type must be namespace or team_session"

let default_fresh_ttl_sec surface =
  match surface with
  | "command.namespace" -> 60
  | "command.swarm" | "intervene" -> 300
  | _ -> 120

let judgment_write_json (ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  let summary = get_string args "summary" "" |> String.trim in
  if summary = "" then Error "summary is required"
  else if
    judgment_target_type = Operator_judgment.Team_session && Option.is_none target_id
  then
    Error "target_id is required when target_type=team_session"
  else
    let now_unix = Unix.gettimeofday () in
    let generated_at = iso_of_unix now_unix in
    let fresh_ttl_sec =
      let default = default_fresh_ttl_sec surface in
      max 1 (get_int args "fresh_ttl_sec" default)
    in
    let fresh_until_unix = now_unix +. float_of_int fresh_ttl_sec in
    let fresh_until = iso_of_unix fresh_until_unix in
    let confidence = get_float args "confidence" 0.5 in
    let keeper_name =
      match get_string_opt args "keeper_name" with
      | Some raw when String.trim raw <> "" -> String.trim raw
      | _ -> normalized_actor ~context_actor:ctx.agent_name None
    in
    let evidence_refs =
      match U.member "evidence_refs" args with
      | `List items -> List.filter_map U.to_string_option items
      | _ -> []
    in
    let recommended_action =
      match U.member "recommended_action" args with
      | `Assoc _ as value -> Some value
      | _ -> None
    in
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
      (`Assoc
        [
          ("status", `String "ok");
          ("judgment", Operator_judgment.to_yojson judgment);
        ])

let judgment_latest_json (_ctx : 'a context) args =
  let* surface = normalize_judgment_surface (get_string args "surface" "") in
  let* _, judgment_target_type =
    normalize_judgment_target_type (get_string args "target_type" "")
  in
  let target_id = get_string_opt args "target_id" in
  if
    judgment_target_type = Operator_judgment.Team_session && Option.is_none target_id
  then
    Error "target_id is required when target_type=team_session"
  else
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
      (`Assoc
        [
          ("status", `String "ok");
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

let canonical_action_type action_type =
  match action_type with
  | "autonomy_tick" -> "social_sweep"
  | "room_pause" | "namespace_pause" -> "namespace_pause"
  | "room_resume" | "namespace_resume" -> "namespace_resume"
  | "social_sweep" -> "social_sweep"
  | "team_turn" -> "team_turn"
  | "team_note" -> "team_note"
  | "team_broadcast" -> "team_broadcast"
  | "team_task_inject" -> "team_task_inject"
  | "team_worker_spawn_batch" -> "team_worker_spawn_batch"
  | "keeper_msg" -> "keeper_message"
  | "keeper_message" -> "keeper_message"
  | "keeper_probe" -> "keeper_probe"
  | "keeper_recover" -> "keeper_recover"
  | "review_resolve" -> "review_resolve"
  | "review_defer" -> "review_defer"
  | other -> other

let normalize_action_target_type target_type =
  match String.trim target_type |> String.lowercase_ascii with
  | "room" | "namespace" -> Ok "namespace"
  | "team_session" | "keeper" | "review_item" as value -> Ok value
  | "" -> Ok ""
  | _ -> Error "target_type must be namespace, team_session, keeper, or review_item"

let default_target_type_for action_type =
  match action_type with
  | "broadcast" | "namespace_pause" | "namespace_resume" | "task_inject" | "social_sweep" -> "namespace"
  | "team_turn" | "team_note" | "team_broadcast" | "team_task_inject"
  | "team_worker_spawn_batch" | "team_stop" ->
      "team_session"
  | "keeper_message" | "keeper_probe" | "keeper_recover" -> "keeper"
  | "review_resolve" | "review_defer" -> "review_item"
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

let resolved_actor_for_args ?actor_hint ctx args =
  let payload_actor = get_string_opt args "actor" |> Option.map String.trim in
  let hinted_actor = actor_hint |> Option.map String.trim in
  match (payload_actor, hinted_actor) with
  | Some payload, Some hinted
    when payload <> "" && hinted <> "" && not (String.equal payload hinted) ->
      Error "actor mismatch: payload actor must match authenticated actor"
  | _ ->
      Ok
        (normalized_actor ~context_actor:ctx.agent_name
           (match hinted_actor with
           | Some actor when actor <> "" -> Some actor
           | _ -> payload_actor))

let action_request_of_args ?actor_hint ctx args =
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

(** Resolve tool name for an action_type. Looks up available_actions first,
    falls back to legacy mapping for unlisted actions. *)
let delegated_tool_for action_type =
  match
    List.find_opt
      (fun (a : Operator_pending_confirm.available_action) ->
        String.equal a.action_type action_type)
      Operator_pending_confirm.available_actions
  with
  | Some action -> action.tool_name
  | None ->
    (match action_type with
     | "team_turn" -> "masc_operator_action"
     | "review_resolve" | "review_defer" -> "review_state"
     | _ -> "unknown")

let confirm_required = Operator_approval.confirm_required

let preview_of_action (request : action_request) =
  let base =
    [
      ("actor", `String request.actor);
      ("action_type", `String request.action_type);
      ("target_type", `String request.target_type);
      ("target_id", string_option_to_json request.target_id);
    ]
  in
  let payload_fields =
    match request.payload with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base @ [ ("payload", `Assoc payload_fields) ])

let validate_target_type expected request =
  if String.equal request.target_type expected then Ok ()
  else
    Error
      (Printf.sprintf "invalid target_type for %s (expected %s)"
         request.action_type expected)

let require_target_id request =
  match request.target_id with
  | Some target_id -> Ok target_id
  | None -> Error "target_id is required"

let require_payload_field payload key error_message =
  match get_string_opt payload key with
  | Some value -> Ok value
  | None -> Error error_message

(* parse_turn_kind removed — team session turn types deleted. *)

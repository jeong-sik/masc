(** Runtime-status alignment helpers for operator_control snapshot,
    extracted from [operator_control_snapshot.ml]. Pure derivations over
    diagnostic + agent-status JSON that decide when to override the
    surface status with a live-signal-backed runtime status, plus small
    context-derivation helpers. *)

open Operator_pending_confirm

let remote_confirm_ttl_seconds = 900.0

let runtime_status_from_live_signal (agent_status_json : Yojson.Safe.t) =
  let runtime_status =
    (* Mirror the keeper_status_runtime typed parse: the agent-status blob's
       "status" field only ever holds active|busy|listening|inactive, so match
       the closed ADT and drop the dead "idle" arm the compiler can now reject. *)
    match Keeper_status_runtime.agent_runtime_status_opt agent_status_json with
    | Some ((Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening) as s) ->
        Some (Masc_domain.string_of_agent_status s)
    | Some Masc_domain.Inactive | None -> None
  in
  let has_live_signal =
    Keeper_status_runtime.agent_runtime_has_live_signal agent_status_json
  in
  let is_zombie = Safe_ops.json_bool ~default:false "is_zombie" agent_status_json in
  match runtime_status, has_live_signal, is_zombie with
  | Some status, true, false -> Some status
  | _ -> None
;;

let health_state_allows_runtime_status_override (diagnostic : Yojson.Safe.t) =
  let kh =
    Safe_ops.json_string ~default:"offline" "health_state" diagnostic
    |> Keeper_status_runtime.keeper_health_of_string_opt
    |> Option.value ~default:Keeper_types.KH_offline
  in
  match kh with
  | Keeper_types.KH_stale | KH_degraded | KH_zombie | KH_dead -> false
  | KH_healthy | KH_idle | KH_offline -> true
;;

let align_keeper_runtime_status
      ~(surface_status : string)
      ~(diagnostic : Yojson.Safe.t)
      ~(agent_status_json : Yojson.Safe.t)
      ~(keepalive_running : bool)
  : string
  =
  if not keepalive_running
  then surface_status
  else (
    let normalized_surface = String.lowercase_ascii (String.trim surface_status) in
    let runtime_status =
      if health_state_allows_runtime_status_override diagnostic
      then runtime_status_from_live_signal agent_status_json
      else None
    in
    match normalized_surface, runtime_status with
    | ("inactive" | "offline"), Some status -> status
    | _ -> surface_status)
;;

let remote_client_type_of_context (ctx : 'a context) =
  match ctx.mcp_session_id with
  | Some _ -> "mcp_remote"
  | None -> "local_api"
;;

let max_turns_override_source = function
  | Some n
    when n >= Keeper_runtime_resolved.max_turns_per_call_min
         && n <= Keeper_runtime_resolved.max_turns_per_call_max -> "override"
  | Some _ -> "override_invalid"
  | None -> "env"
;;

let operator_server_profile_json =
  `Assoc
    [ "name", `String "operator_remote_v1"
    ; "transport", `String "mcp_streamable_http"
    ; "auth", `String "bearer_token"
    ; "confirm_ttl_seconds", `Float remote_confirm_ttl_seconds
    ; "curated_tool_count", `Int 4
    ]
;;

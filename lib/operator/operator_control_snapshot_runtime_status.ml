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
  match runtime_status, has_live_signal with
  | Some status, true -> Some status
  | _ -> None
;;

(* [keeper_diagnostic_json] always emits "health_state", so a missing or
   unparseable field means the blob did not come from that producer. Deny the
   override in that case: this gate exists to stop a non-healthy keeper from
   being displayed as live, and the previous two-step defaulting
   (~default:"offline" then ~default:KH_offline) landed on KH_offline, which is
   in the allow set — so an absent or corrupt field granted the override. *)
let health_state_allows_runtime_status_override (diagnostic : Yojson.Safe.t) =
  match
    Json_util.get_string diagnostic "health_state"
    |> Option.map Keeper_status_runtime.keeper_health_of_string_opt
  with
  | None | Some None -> false
  | Some (Some kh) ->
    (match kh with
     | Keeper_types.KH_stale | KH_degraded | KH_zombie | KH_dead -> false
     | KH_healthy | KH_idle | KH_offline -> true)
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
    let runtime_status =
      if health_state_allows_runtime_status_override diagnostic
      then runtime_status_from_live_signal agent_status_json
      else None
    in
    (* RFC-0089: override only when the surface status is inactive/offline.
       Classify via the typed surface_status SSOT instead of string literals. *)
    match Keeper_status_runtime.surface_status_of_string_opt surface_status, runtime_status with
    | Some (Keeper_status_runtime.Surface_inactive | Keeper_status_runtime.Surface_offline), Some status ->
      status
    | _ -> surface_status)
;;

let remote_client_type_of_context (ctx : 'a context) =
  match ctx.mcp_session_id with
  | Some _ -> "mcp_remote"
  | None -> "local_api"
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

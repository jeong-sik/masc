(** Tool permission filter.

    DEPRECATED: The pre-hook installed by [install] is no longer registered
    in the authorization hot path. Admin tool checking is now handled by
    [Tool_access_role.policy_for_role] via [Auth.authorize_tool_v2].
    This module is retained only for backward compatibility with tests.
    See #4381 Phase 0. *)

(* Derived from Tool_catalog surface SSOT.
   team_session_stop intentionally stays outside this list:
   owner/intruder authorization is enforced per session in the team
   session handlers and contract tests exercise that path directly. *)
let admin_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Admin

let admin_set : (string, unit) Hashtbl.t = Hashtbl.create 20

let () =
  List.iter (fun name -> Hashtbl.replace admin_set name ()) admin_tools

let requires_admin tool_name =
  Hashtbl.mem admin_set tool_name

(** Capability checker callback type.
    [has_cap agent_name capability] returns true if the agent has the cap. *)
type capability_checker = string -> string -> bool

(** Default checker: always denies (safe default). *)
let default_checker : capability_checker ref = ref (fun _agent _cap -> false)

let set_capability_checker (checker : capability_checker) =
  default_checker := checker

let check ~agent_name ~tool_name =
  if not (requires_admin tool_name) then
    Ok ()
  else if !default_checker agent_name "admin" then
    Ok ()
  else
    Error (Printf.sprintf
      "agent '%s' lacks 'admin' capability for tool '%s'"
      agent_name tool_name)

let install ~get_agent_name =
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    if not (requires_admin name) then
      None  (* Unrestricted tool — proceed *)
    else
      let agent_name_opt =
        match get_agent_name () with
        | Some _ as agent -> agent
        | None ->
            (match Safe_ops.json_string_opt "agent_name" args with
             | Some value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | None -> None)
      in
      match agent_name_opt with
      | None ->
        Some { Tool_result.success = false
             ; data = `String "permission denied: no agent identity"
             ; tool_name = name
             ; duration_ms = 0.0
             }
      | Some agent_name ->
        (match check ~agent_name ~tool_name:name with
         | Ok () -> None  (* Allowed — proceed *)
         | Error reason ->
           Some { Tool_result.success = false
                ; data = `String reason
                ; tool_name = name
                ; duration_ms = 0.0
                }))

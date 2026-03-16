(** Tool permission filter *)

let admin_tools =
  [ "masc_gardener_execute_spawn"
  ; "masc_gardener_execute_retire"
  ; "masc_gardener_reset_circuit"
  ]

let admin_set : (string, unit) Hashtbl.t = Hashtbl.create 8

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
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    if not (requires_admin name) then
      None  (* Unrestricted tool — proceed *)
    else
      match get_agent_name () with
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

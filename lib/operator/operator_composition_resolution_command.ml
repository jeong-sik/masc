module Journal = Keeper_tool_execution_journal
open Result.Syntax

type target =
  { keeper_name : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; request_id : string }

type t = Observe of target
  | Resolve of
      { target : target; expected_version : string
      ; decision : Journal.resolution_decision; reason : string }

type outcome = Observed of Journal.resolution_observation | Resolved of Journal.resolution_report

let parse_tool_command args =
  let* fields = Agent_core.Execution_json.object_fields ~context:"composition resolution command"
      ~required:["command";"keeper_name";"composition_run_id";"request_id"]
      ~optional:["expected_version";"reason"] args in
  let text name = match List.assoc_opt name fields with
    | Some (`String value) when String.trim value <> "" -> Ok value
    | Some _ | None -> Error (name ^ " must be a nonblank string") in
  let identity name =
    let* value = text name in
    if String.equal value (String.trim value) then Ok value
    else Error (name ^ " must be an exact identity") in
  let* keeper_name = identity "keeper_name" in
  let* request_id = identity "request_id" in
  let* run_id = identity "composition_run_id" in
  let* composition_run_id = Keeper_tool_plan.Composition_run_id.of_string run_id
    |> Result.map_error (function Keeper_tool_plan.Composition_run_id.Invalid_uuid_v7 detail -> detail) in
  let target = {keeper_name;composition_run_id;request_id} in
  let* command = identity "command" in
  match command with
  | "observe" when List.mem_assoc "expected_version" fields || List.mem_assoc "reason" fields ->
    Error "observe does not accept a decision version or reason"
  | "observe" -> Ok (Observe target)
  | "reject" | "cancel" ->
    let* expected_version = identity "expected_version" in
    let* () = if String.length expected_version = 64 && String.for_all
        (function '0'..'9' | 'a'..'f' -> true | _ -> false) expected_version
      then Ok () else Error "expected_version must be the opaque SHA256 from observe" in
    let* reason = text "reason" in
    Ok (Resolve {target;expected_version;decision=(if command = "reject" then Journal.Reject else Journal.Cancel);reason})
  | _ -> Error "command must be observe, reject or cancel"

let execute ~base_path ~actor ~now = function
  | Observe target ->
    Journal.observe_resolution ~base_path ~keeper_name:target.keeper_name
      ~composition_run_id:target.composition_run_id ~request_id:target.request_id
    |> Result.map (fun observation -> Observed observation)
  | Resolve {target;expected_version;decision;reason} ->
    Journal.resolve_continuation ~base_path ~keeper_name:target.keeper_name
      ~composition_run_id:target.composition_run_id ~request_id:target.request_id
      ~expected_version ~decision ~requested_by:actor ~reason ~now
    |> Result.map (fun report -> Resolved report)

let outcome_to_json = function
  | Observed observation -> Journal.resolution_observation_to_json observation
  | Resolved report -> Journal.resolution_report_to_json report

(** Tool_verification - MCP tool handlers for cross-agent verification

    Provides:
    - masc_verify_register: Register verification criteria for a task
    - masc_verify_request: Request verification of task output
    - masc_verify_submit: Submit verification verdict
    - masc_verify_status: Check verification status
    - masc_verify_pending: List pending verifications for current agent
    - masc_verify_auto: Auto-verify using automated criteria
*)

open Yojson.Safe.Util
open Tool_args

type tool_result = bool * string

(** masc_verify_request: Create a verification request *)
let handle_request config agent_name args =
  let task_id = get_string args "task_id" "" in
  let output = match args |> member "output" with
    | `Null -> `Null
    | j -> j
  in
  let criteria = match args |> member "criteria" with
    | `List l ->
        List.filter_map (fun j ->
          match Verification.criterion_of_yojson j with
          | Ok c -> Some c
          | Error _ -> None
        ) l
    | _ -> []
  in
  let verifier = match args |> member "verifier" with
    | `String s -> Some s
    | _ -> None
  in
  if String.length task_id = 0 then
    (false, "task_id is required")
  else
    let base_path = Room_utils.masc_dir config in
    match Verification.create_request ~base_path ~task_id ~output ~criteria
        ~worker:agent_name ?verifier () with
    | Ok req ->
        let json = Verification.request_to_yojson req in
        (true, Yojson.Safe.to_string json)
    | Error e -> (false, e)

(** masc_verify_submit: Submit verdict for a verification *)
let handle_submit config agent_name args =
  let req_id = get_string args "verification_id" "" in
  let verdict_str = get_string args "verdict" "" in
  let reason = get_string args "reason" "" in
  let score = match args |> member "score" with
    | `Float f -> Some f
    | `Int n -> Some (Float.of_int n)
    | _ -> None
  in
  if String.length req_id = 0 then
    (false, "verification_id is required")
  else if String.length verdict_str = 0 then
    (false, "verdict is required (pass/fail/partial)")
  else
    let verdict = match verdict_str with
      | "pass" -> Verification.Pass
      | "fail" -> Verification.Fail reason
      | "partial" ->
          let s = Option.value ~default:0.5 score in
          Verification.Partial (s, reason)
      | _ -> Verification.Fail (Printf.sprintf "unknown verdict: %s" verdict_str)
    in
    let base_path = Room_utils.masc_dir config in
    match Verification.submit_verdict ~base_path ~req_id ~verifier:agent_name ~verdict with
    | Ok req ->
        let json = Verification.request_to_yojson req in
        (true, Yojson.Safe.to_string json)
    | Error e -> (false, e)

(** masc_verify_status: Check verification status *)
let handle_status config _agent_name args =
  let req_id = get_string args "verification_id" "" in
  if String.length req_id = 0 then
    (false, "verification_id is required")
  else
    let base_path = Room_utils.masc_dir config in
    match Verification.load_request base_path req_id with
    | Ok req ->
        let json = Verification.request_to_yojson req in
        (true, Yojson.Safe.to_string json)
    | Error e -> (false, e)

(** masc_verify_pending: List pending verifications for agent *)
let handle_pending config agent_name _args =
  let base_path = Room_utils.masc_dir config in
  let pending = Verification.pending_for_agent ~base_path ~agent:agent_name in
  let json = `List (List.map Verification.request_to_yojson pending) in
  (true, Printf.sprintf "%d pending verification(s)\n%s"
     (List.length pending)
     (Yojson.Safe.pretty_to_string json))

(** masc_verify_auto: Auto-verify using automated criteria *)
let handle_auto config _agent_name args =
  let req_id = get_string args "verification_id" "" in
  if String.length req_id = 0 then
    (false, "verification_id is required")
  else
    let base_path = Room_utils.masc_dir config in
    match Verification.auto_verify ~base_path ~req_id with
    | Ok req ->
        let json = Verification.request_to_yojson req in
        (true, Yojson.Safe.to_string json)
    | Error e -> (false, e)

(** Dispatch tool calls *)
let dispatch config agent_name tool_name args : tool_result =
  match tool_name with
  | "masc_verify_request" -> handle_request config agent_name args
  | "masc_verify_submit" -> handle_submit config agent_name args
  | "masc_verify_status" -> handle_status config agent_name args
  | "masc_verify_pending" -> handle_pending config agent_name args
  | "masc_verify_auto" -> handle_auto config agent_name args
  | _ -> (false, Printf.sprintf "Unknown verification tool: %s" tool_name)

(** Approval queue handlers for inline-dispatched approval tools. *)

let inline_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let inline_err_workflow ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg
;;

let arg_get_string args key default =
  Safe_ops.json_string ~default key args
;;

let handle ~tool_name ~start_time args : Tool_result.result =
  match tool_name with
  | "masc_approval_pending" ->
    let json = Keeper_approval_queue.list_pending_json () in
    inline_ok ~tool_name ~start_time (Yojson.Safe.to_string json)
  | "masc_approval_get" ->
    let id = arg_get_string args "id" "" in
    if String.equal id ""
    then inline_err_workflow ~tool_name ~start_time "id is required"
    else (
      match Keeper_approval_queue.get_pending_json ~id with
      | Some json ->
        inline_ok ~tool_name ~start_time (Yojson.Safe.to_string json)
      | None ->
        inline_err_workflow
          ~tool_name
          ~start_time
          (Printf.sprintf
             "approval %s is no longer pending or was not found. Refresh with \
              masc_approval_pending before approving/rejecting."
             id))
  | "masc_approval_resolve" ->
    let id = arg_get_string args "id" "" in
    let decision_str = arg_get_string args "decision" "approve" in
    if String.equal id ""
    then inline_err_workflow ~tool_name ~start_time "id is required"
    else
      let decision =
        match String.lowercase_ascii decision_str with
        | "approve" -> Agent_sdk.Hooks.Approve
        | "reject" ->
          let reason = arg_get_string args "reason" "operator rejected" in
          Agent_sdk.Hooks.Reject reason
        | _ ->
          Agent_sdk.Hooks.Reject
            (Printf.sprintf "unknown decision: %s" decision_str)
      in
      (match Keeper_approval_queue.resolve ~id ~decision with
       | Ok () ->
         inline_ok
           ~tool_name
           ~start_time
           (Printf.sprintf
              "{\"resolved\":\"%s\",\"decision\":\"%s\"}"
              id
              decision_str)
       | Error err ->
         inline_err_workflow
           ~tool_name
           ~start_time
           (Keeper_approval_queue.resolve_error_to_string err))
  | _ ->
    inline_err_workflow
      ~tool_name
      ~start_time
      (Printf.sprintf "unsupported approval tool: %s" tool_name)
;;

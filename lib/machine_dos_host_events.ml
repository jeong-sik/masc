(** Host effects used by the DOS machine implementation. *)
let relay ~author content =
  try
    let result =
      Board_tool_dispatch.handle_tool ~result_boundary:Tool_output.Sent_to_client
        (Tool_name.Board_name.to_string Tool_name.Board_name.Board_post)
        (`Assoc
          [ ("title", `String "DOS 아케이드")
          ; ("content", `String content)
          ; ("author", `String author)
          ; ("post_kind", `String "automation")
          ])
    in
    if not (Tool_result.is_success result) then
      Log.DosLog.warn "arcade relay: board post refused, the machine is unaffected: %s"
        (Tool_result.message result)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | e ->
    Log.DosLog.warn "arcade relay: board post raised, the machine is unaffected: %s"
      (Printexc.to_string e)
;;


let parse_controller value =
  match Board_types.Agent_id.parse value with
  | Ok id -> Ok (Board_types.Agent_id.to_string id)
  | Error _ -> Error "invalid Keeper name"

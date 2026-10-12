(** Host-owned publication of machine events. The worker tool layer receives
    this effect explicitly and does not depend on the MASC Board dispatcher. *)
let relay ~author content =
  try
    let result =
      Board_tool_dispatch.handle_tool ~result_boundary:Tool_output.Sent_to_client
        (Tool_name.Board_name.to_string Tool_name.Board_name.Board_post)
        (`Assoc
          [ ("title", `String "MSX 아케이드")
          ; ("content", `String content)
          ; ("author", `String author)
          ; ("post_kind", `String "automation")
          ])
    in
    if not (Tool_result.is_success result) then
      Log.MsxLog.warn
        "arcade relay: board post refused, the load itself is unaffected: %s"
        (Tool_result.message result)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | e ->
    Log.MsxLog.warn
      "arcade relay: board post raised, the load itself is unaffected: %s"
      (Printexc.to_string e)
;;

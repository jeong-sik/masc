let emit_one (diagnostic : Board_content_json.diagnostic) =
  match diagnostic with
  | Board_content_json.Invalid_post_kind { post_id } ->
    Log.BoardLog.warn
      "dropping persisted board post %s: missing or invalid post_kind"
      post_id
  | Board_content_json.Invalid_agent_id { raw } ->
    ignore (Board_types.Agent_id.of_string raw)

let emit diagnostics = List.iter emit_one diagnostics

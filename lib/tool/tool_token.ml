(** Tool_token — parse-once proof that a tool name exists in a dispatch table.

    See [tool_token.mli] for API documentation. *)

type t = { name : string }

let mint_with ~validate ~name =
  if validate name then
    Ok { name }
  else
    Error (Printf.sprintf "not in current tool set: %s" name)



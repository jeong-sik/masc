(** Tool_token — parse-once proof that a tool name exists in a dispatch table.

    See [tool_token.mli] for API documentation. *)

type t =
  { name : string
  ; minted_at : float
  }

let mint_with ~validate ~name =
  if validate name
  then Ok { name; minted_at = Unix.gettimeofday () }
  else Error (Printf.sprintf "not in current tool set: %s" name)
;;

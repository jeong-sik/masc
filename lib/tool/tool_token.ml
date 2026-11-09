(** Tool_token — parse-once proof that a tool name exists in a dispatch table.

    See [tool_token.mli] for API documentation. *)

type t = { name : string }

let mint_map ~resolve ~name =
  match resolve name with
  | Some value -> Ok (value, { name })
  | None -> Error (Printf.sprintf "not in current tool set: %s" name)

let mint_with ~validate ~name =
  mint_map ~resolve:(fun n -> if validate n then Some () else None) ~name
  |> Result.map snd



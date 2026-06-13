(** Low-dependency public alias projection for tool-name set logic. *)

type public_alias =
  { public_name : string
  ; internal_name : string
  }

let public_aliases =
  [ { public_name = "Execute"; internal_name = "tool_execute" }
  ; { public_name = "Edit"; internal_name = "tool_edit_file" }
  ; { public_name = "WebFetch"; internal_name = "masc_web_fetch" }
  ; { public_name = "Read"; internal_name = "tool_read_file" }
  ; { public_name = "Grep"; internal_name = "tool_search_files" }
  ; { public_name = "Search"; internal_name = "tool_search_files" }
  ; { public_name = "search_files"; internal_name = "tool_search_files" }
  ; { public_name = "WebSearch"; internal_name = "masc_web_search" }
  ; { public_name = "Write"; internal_name = "tool_write_file" }
  ]
;;

let legacy_internal_aliases : (string * string) list = []

let primary_internal_name internal_name =
  match List.assoc_opt internal_name legacy_internal_aliases with
  | Some primary -> primary
  | None -> internal_name
;;

let public_names () =
  List.map (fun alias -> alias.public_name) public_aliases
;;

let internal_name_of_public public_name =
  public_aliases
  |> List.find_opt (fun alias -> String.equal alias.public_name public_name)
  |> Option.map (fun alias -> alias.internal_name)
;;

let public_name_for_internal internal_name =
  let internal_name = primary_internal_name internal_name in
  public_aliases
  |> List.find_opt (fun alias -> String.equal alias.internal_name internal_name)
  |> Option.map (fun alias -> alias.public_name)
;;

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

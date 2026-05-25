(** Low-dependency public alias projection for tool-name set logic. *)

type public_alias =
  { public_name : string
  ; internal_name : string
  }

let public_aliases =
  [ { public_name = "Execute"; internal_name = "keeper_bash" }
  ; { public_name = "EditFile"; internal_name = "keeper_fs_edit" }
  ; { public_name = "FetchWeb"; internal_name = "masc_web_fetch" }
  ; { public_name = "ReadFile"; internal_name = "keeper_fs_read" }
  ; { public_name = "SearchFiles"; internal_name = "keeper_shell" }
  ; { public_name = "SearchWeb"; internal_name = "masc_web_search" }
  ; { public_name = "WriteFile"; internal_name = "keeper_fs_edit" }
  ]
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
  public_aliases
  |> List.find_opt (fun alias -> String.equal alias.internal_name internal_name)
  |> Option.map (fun alias -> alias.public_name)
;;

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

let canonical_required_tool_name name =
  let stripped = strip_mcp_masc_prefix name in
  match internal_name_of_public stripped with
  | Some internal -> internal
  | None -> stripped
;;

(** Low-dependency public alias projection for tool-name set logic. *)

type public_alias =
  { public_name : string
  ; internal_name : string
  }

type public_tool =
  | Execute
  | Edit
  | Web_fetch
  | Read
  | Grep
  | Web_search
  | Write

let all = [ Execute; Edit; Web_fetch; Read; Grep; Web_search; Write ]

let preferred_name = function
  | Execute -> "Execute"
  | Edit -> "Edit"
  | Web_fetch -> "WebFetch"
  | Read -> "Read"
  | Grep -> "Grep"
  | Web_search -> "WebSearch"
  | Write -> "Write"
;;

let internal_name = function
  | Execute -> "tool_execute"
  | Edit -> "tool_edit_file"
  | Web_fetch -> "masc_web_fetch"
  | Read -> "tool_read_file"
  | Grep -> "tool_search_files"
  | Web_search -> "masc_web_search"
  | Write -> "tool_write_file"
;;

let compatibility_names = function
  | Grep -> [ "Search"; "search_files" ]
  | Execute | Edit | Web_fetch | Read | Web_search | Write -> []
;;

let public_aliases =
  all
  |> List.concat_map (fun tool ->
    let internal_name = internal_name tool in
    (preferred_name tool :: compatibility_names tool)
    |> List.map (fun public_name -> { public_name; internal_name }))
;;

let public_tool_of_name name =
  List.find_opt
    (fun tool ->
      String.equal name (preferred_name tool)
      || List.exists (String.equal name) (compatibility_names tool))
    all
;;

let legacy_internal_aliases : (string * string) list = []

let primary_internal_name internal_name =
  match List.assoc_opt internal_name legacy_internal_aliases with
  | Some primary -> primary
  | None -> internal_name
;;

let public_names () =
  List.map preferred_name all
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

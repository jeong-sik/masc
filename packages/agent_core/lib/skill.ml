(** Markdown skill loading with lightweight frontmatter support.
    Parses YAML-like frontmatter (---/--- delimited) into key-value pairs
    and extracts the body for prompt composition. *)

type scope =
  | Project
  | User
  | Local
  | Custom of string
[@@deriving show]

type t =
  { name : string
  ; description : string option
  ; body : string
  ; path : string option
  ; scope : scope option
  ; allowed_tools : string list
  ; argument_hint : string option
  ; model : string option
  ; supporting_files : string list
  ; metadata : (string * string list) list
  }
[@@deriving show]

(* --- String helpers --- *)

let trim = String.trim

let strip_quotes s =
  let s = trim s in
  let len = String.length s in
  if len >= 2
  then (
    let first = s.[0]
    and last = s.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'')
    then String.sub s 1 (len - 2)
    else s)
  else s
;;

let split_csv s =
  let s = trim s in
  let inner =
    if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']'
    then String.sub s 1 (String.length s - 2)
    else s
  in
  inner |> String.split_on_char ',' |> List.map strip_quotes |> Util.filter_non_empty
;;

let replace_all ~pattern ~replacement text =
  let plen = String.length pattern in
  if plen = 0
  then text
  else (
    let buf = Buffer.create (String.length text) in
    let tlen = String.length text in
    let rec loop i =
      if i > tlen - plen
      then (
        Buffer.add_substring buf text i (tlen - i);
        Buffer.contents buf)
      else if String.sub text i plen = pattern
      then (
        Buffer.add_string buf replacement;
        loop (i + plen))
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1))
    in
    if tlen < plen then text else loop 0)
;;

(* --- Frontmatter parser --- *)

let assoc_replace key values pairs =
  let without = List.remove_assoc key pairs in
  (key, values) :: without
;;

let parse_frontmatter markdown =
  let drop_leading_blank lines =
    let rec aux = function
      | [] -> []
      | line :: rest when trim line = "" -> aux rest
      | lines -> lines
    in
    aux lines
  in
  let lines =
    String.split_on_char '\n' markdown
    |> List.map (fun line ->
      if String.ends_with ~suffix:"\r" line
      then String.sub line 0 (String.length line - 1)
      else line)
    |> drop_leading_blank
  in
  match lines with
  | "---" :: rest ->
    let rec consume current_key acc = function
      | [] -> List.rev acc, ""
      | "---" :: remaining -> List.rev acc, String.concat "\n" remaining |> trim
      | line :: remaining ->
        let line = trim line in
        if line = "" || String.starts_with ~prefix:"#" line
        then consume current_key acc remaining
        else if String.starts_with ~prefix:"- " line
        then (
          let item = String.sub line 2 (String.length line - 2) |> strip_quotes in
          match current_key with
          | Some key ->
            let existing =
              match List.assoc_opt key acc with
              | Some vs -> vs
              | None -> []
            in
            consume current_key (assoc_replace key (existing @ [ item ]) acc) remaining
          | None -> consume current_key acc remaining)
        else (
          match String.index_opt line ':' with
          | None -> consume current_key acc remaining
          | Some idx ->
            let key = String.sub line 0 idx |> trim |> String.lowercase_ascii in
            let raw = String.sub line (idx + 1) (String.length line - idx - 1) |> trim in
            let values = if raw = "" then [] else split_csv raw in
            consume (Some key) (assoc_replace key values acc) remaining)
    in
    consume None [] rest
  | _ -> [], trim markdown
;;

let frontmatter_value fm key =
  match List.assoc_opt key fm with
  | Some (v :: _) -> Some v
  | _ -> None
;;

let frontmatter_values fm key =
  match List.assoc_opt key fm with
  | Some vs -> vs
  | None -> []
;;

(* --- Constructors --- *)

let scope_of_string = function
  | "project" -> Project
  | "user" -> User
  | "local" -> Local
  | s -> Custom s
;;

let of_markdown ?path ?scope markdown =
  let fm, body = parse_frontmatter markdown in
  let name =
    match frontmatter_value fm "name", path with
    | Some v, _ -> v
    | None, Some p -> p |> Filename.basename |> Filename.remove_extension
    | None, None -> "skill"
  in
  { name
  ; description = frontmatter_value fm "description"
  ; body
  ; path
  ; scope =
      (match frontmatter_value fm "scope", scope with
       | Some v, _ -> Some (scope_of_string v)
       | None, v -> v)
  ; allowed_tools =
      frontmatter_values fm "allowed-tools" @ frontmatter_values fm "allowed_tools"
  ; argument_hint =
      (match frontmatter_value fm "argument-hint" with
       | Some _ as v -> v
       | None -> frontmatter_value fm "argument_hint")
  ; model = frontmatter_value fm "model"
  ; supporting_files =
      frontmatter_values fm "supporting-files" @ frontmatter_values fm "supporting_files"
  ; metadata = fm
  }
;;

let load ?scope path =
  match Fs_result.read_file path with
  | Error _ as err -> err
  | Ok content -> Ok (of_markdown ~path ?scope content)
;;

let load_dir ?scope dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name ->
    Filename.check_suffix name ".md" && not (String.starts_with ~prefix:"." name))
  |> List.sort String.compare
  |> List.filter_map (fun name ->
    match load ?scope (Filename.concat dir name) with
    | Ok skill -> Some skill
    | Error _ -> None)
;;

let render_prompt ?arguments skill =
  match arguments with
  | None -> skill.body
  | Some args ->
    skill.body
    |> replace_all ~pattern:"$ARGUMENTS" ~replacement:args
    |> replace_all ~pattern:"{{arguments}}" ~replacement:args
;;

let supporting_file_paths skill =
  match skill.path with
  | None -> skill.supporting_files
  | Some p ->
    let base = Filename.dirname p in
    List.map
      (fun f -> if Filename.is_relative f then Filename.concat base f else f)
      skill.supporting_files
;;

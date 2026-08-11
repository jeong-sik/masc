type token_source =
  | Keyring
  | Environment of string
  | Config_default
  | Other_source of string

type outcome =
  | Logged_in
  | Login_failed

type entry =
  { outcome : outcome
  ; host : string
  ; account : string option
  ; source : token_source
  ; active : bool option
  ; scopes : string list option
  }

type verdict =
  | Authenticated
  | Unauthenticated
  | Shadowed
  | Unknown

type t =
  { entries : entry list
  ; verdict : verdict
  }

let logged_in_mark = "\xe2\x9c\x93 "
let failed_mark = "X "
let no_hosts_sentence = "You are not logged into any GitHub hosts"
let logged_in_prefix = "Logged in to "
let failed_prefix = "Failed to log in to "
let account_keyword = "account"
let using_token_keyword = "using"
let active_account_label = "Active account:"
let token_scopes_label = "Token scopes:"

let verdict_to_string = function
  | Authenticated -> "authenticated"
  | Unauthenticated -> "unauthenticated"
  | Shadowed -> "shadowed"
  | Unknown -> "unknown"
;;

let token_source_to_string = function
  | Keyring -> "keyring"
  | Environment name -> name
  | Config_default -> "default"
  | Other_source label -> label
;;

(* The recognised set is explicit so a label gh adds later becomes
   [Other_source] and stays visible, rather than collapsing into one of the
   sources the verdict depends on. *)
let token_source_of_label label =
  match label with
  | "keyring" -> Keyring
  | "default" -> Config_default
  | "GH_TOKEN" | "GITHUB_TOKEN" | "GH_ENTERPRISE_TOKEN" | "GITHUB_ENTERPRISE_TOKEN" ->
    Environment label
  | _ -> Other_source label
;;

(* gh closes an entry line with the source in parentheses. Read the last pair
   so an account name containing parentheses cannot capture the label. *)
let split_trailing_parens text =
  let length = String.length text in
  if length = 0 || text.[length - 1] <> ')'
  then None
  else (
    let rec find_open index =
      if index < 0
      then None
      else if text.[index] = '('
      then Some index
      else find_open (index - 1)
    in
    match find_open (length - 2) with
    | None -> None
    | Some open_index ->
      let head = String.trim (String.sub text 0 open_index) in
      let label = String.sub text (open_index + 1) (length - open_index - 2) in
      Some (head, label))
;;

let words text =
  String.split_on_char ' ' text |> List.filter (fun word -> word <> "")
;;

(* "github.com account jeong-sik" -> host and account.
   "github.com using token"       -> host, no account. *)
let host_and_account head =
  match words head with
  | [] -> None
  | host :: rest ->
    let account =
      match rest with
      | keyword :: name :: _ when String.equal keyword account_keyword -> Some name
      | keyword :: _ when String.equal keyword using_token_keyword -> None
      | [] -> None
      | _ -> None
    in
    Some (host, account)
;;

let parse_entry_line line =
  let trimmed = String.trim line in
  let outcome, body =
    if String.starts_with ~prefix:logged_in_mark trimmed
    then
      ( Some Logged_in
      , String.sub
          trimmed
          (String.length logged_in_mark)
          (String.length trimmed - String.length logged_in_mark) )
    else if String.starts_with ~prefix:failed_mark trimmed
    then
      ( Some Login_failed
      , String.sub
          trimmed
          (String.length failed_mark)
          (String.length trimmed - String.length failed_mark) )
    else None, ""
  in
  match outcome with
  | None -> None
  | Some outcome ->
    let remainder =
      if String.starts_with ~prefix:logged_in_prefix body
      then
        Some
          (String.sub
             body
             (String.length logged_in_prefix)
             (String.length body - String.length logged_in_prefix))
      else if String.starts_with ~prefix:failed_prefix body
      then
        Some
          (String.sub
             body
             (String.length failed_prefix)
             (String.length body - String.length failed_prefix))
      else None
    in
    (match remainder with
     | None -> None
     | Some remainder ->
       (match split_trailing_parens remainder with
        | None -> None
        | Some (head, label) ->
          (match host_and_account head with
           | None -> None
           | Some (host, account) ->
             Some
               { outcome
               ; host
               ; account
               ; source = token_source_of_label label
               ; active = None
               ; scopes = None
               })))
;;

let parse_detail_line line =
  let trimmed = String.trim line in
  if not (String.starts_with ~prefix:"- " trimmed)
  then None
  else (
    let body =
      String.trim (String.sub trimmed 2 (String.length trimmed - 2))
    in
    if String.starts_with ~prefix:active_account_label body
    then (
      let value =
        String.trim
          (String.sub
             body
             (String.length active_account_label)
             (String.length body - String.length active_account_label))
      in
      match value with
      | "true" -> Some (`Active true)
      | "false" -> Some (`Active false)
      | _ -> None)
    else if String.starts_with ~prefix:token_scopes_label body
    then (
      let value =
        String.trim
          (String.sub
             body
             (String.length token_scopes_label)
             (String.length body - String.length token_scopes_label))
      in
      let scopes =
        String.split_on_char ',' value
        |> List.map (fun scope ->
          String.trim scope
          |> String.to_seq
          |> Seq.filter (fun c -> c <> '\'')
          |> String.of_seq
          |> String.trim)
        |> List.filter (fun scope -> scope <> "")
      in
      Some (`Scopes scopes))
    else None)
;;

let apply_detail entry detail =
  match detail with
  | `Active value -> { entry with active = Some value }
  | `Scopes scopes -> { entry with scopes = Some scopes }
;;

let collect_entries lines =
  let flush current acc =
    match current with
    | None -> acc
    | Some entry -> entry :: acc
  in
  let rec walk lines current acc =
    match lines with
    | [] -> List.rev (flush current acc)
    | line :: rest ->
      (match parse_entry_line line with
       | Some entry -> walk rest (Some entry) (flush current acc)
       | None ->
         (match current, parse_detail_line line with
          | Some entry, Some detail -> walk rest (Some (apply_detail entry detail)) acc
          | _, _ -> walk rest current acc))
  in
  walk lines None []
;;

let is_environment_source = function
  | Environment _ -> true
  | Keyring | Config_default | Other_source _ -> false
;;

let verdict_of_entries entries =
  let active_environment =
    List.exists
      (fun entry ->
         is_environment_source entry.source
         &&
         match entry.active with
         | Some true -> true
         | Some false | None -> false)
      entries
  in
  let has_non_environment =
    List.exists (fun entry -> not (is_environment_source entry.source)) entries
  in
  let has_logged_in =
    List.exists
      (fun entry ->
         match entry.outcome with
         | Logged_in -> true
         | Login_failed -> false)
      entries
  in
  if active_environment && has_non_environment
  then Shadowed
  else if has_logged_in
  then Authenticated
  else Unauthenticated
;;

let parse output =
  let lines = String.split_on_char '\n' output in
  let entries = collect_entries lines in
  match entries with
  | _ :: _ -> { entries; verdict = verdict_of_entries entries }
  | [] ->
    if List.exists
         (fun line -> String_util.contains_substring line no_hosts_sentence)
         lines
    then { entries = []; verdict = Unauthenticated }
    else { entries = []; verdict = Unknown }
;;

type request =
  { page : string option
  ; kind : string option
  ; limit : int option
  ; cursor : string option
  }

type problem =
  | Unknown_kind of string
  | Bad_limit
  | Bad_cursor of string

let problem_to_string = function
  | Unknown_kind kind ->
    Printf.sprintf
      "kind %S is not one of: %s"
      kind
      (String.concat ", " Wiki_lint.all_kinds)
  | Bad_limit -> "limit must be a whole number from 1"
  | Bad_cursor cursor ->
    Printf.sprintf "cursor %S is not a cursor this tool returned" cursor
;;

let schema = "masc.wiki_lint.v1"
let default_limit = 50
let max_limit = 200
let byte_budget = 12_000
let cursor_prefix = "o:"

let finding_to_json (finding : Wiki_lint.finding) : Yojson.Safe.t =
  let kind = `String (Wiki_lint.kind finding) in
  match finding with
  | Wiki_lint.Broken_link { page; line; target } ->
    `Assoc [ "kind", kind; "page", `String page; "line", `Int line; "target", `String target ]
  | Wiki_lint.Unsupported_link { page; line; form; target } ->
    `Assoc
      [ "kind", kind
      ; "page", `String page
      ; "line", `Int line
      ; "form", `String form
      ; "target", `String target
      ]
  | Wiki_lint.Orphan { page }
  | Wiki_lint.Orphan_unconfirmed { page }
  | Wiki_lint.Missing_sources { page }
  | Wiki_lint.Hearsay_only { page } -> `Assoc [ "kind", kind; "page", `String page ]
  | Wiki_lint.Unreadable_page { file; reason } ->
    `Assoc [ "kind", kind; "file", `String file; "reason", `String reason ]
;;

let parse_cursor raw =
  match raw with
  | None -> Ok 0
  | Some cursor ->
    let prefix_length = String.length cursor_prefix in
    if String.length cursor > prefix_length
       && String.equal (String.sub cursor 0 prefix_length) cursor_prefix
    then (
      match int_of_string_opt (String.sub cursor prefix_length (String.length cursor - prefix_length)) with
      | Some offset when offset >= 0 -> Ok offset
      | Some _ | None -> Error (Bad_cursor cursor))
    else Error (Bad_cursor cursor)
;;

let about_page page (finding : Wiki_lint.finding) =
  let subject = Wiki_lint.subject finding in
  String.equal subject page || String.equal subject (page ^ ".md")
;;

let rec take_within_budget ~limit ~budget acc = function
  | [] -> List.rev acc, []
  | finding :: rest as remaining ->
    if limit <= 0
    then List.rev acc, remaining
    else (
      let json = finding_to_json finding in
      let size = String.length (Yojson.Safe.to_string json) in
      if acc <> [] && size > budget
      then List.rev acc, remaining
      else take_within_budget ~limit:(limit - 1) ~budget:(budget - size) ((finding, json) :: acc) rest)
;;

let render ~pages_total ~pages_unreadable ~findings request =
  let ( let* ) = Result.bind in
  let* () =
    match request.kind with
    | None -> Ok ()
    | Some kind ->
      if List.exists (String.equal kind) Wiki_lint.all_kinds
      then Ok ()
      else Error (Unknown_kind kind)
  in
  let* limit =
    match request.limit with
    | None -> Ok default_limit
    | Some limit -> if limit >= 1 then Ok (min limit max_limit) else Error Bad_limit
  in
  let* offset = parse_cursor request.cursor in
  let selected =
    findings
    |> List.filter (fun finding ->
      match request.kind with
      | None -> true
      | Some kind -> String.equal (Wiki_lint.kind finding) kind)
    |> List.filter (fun finding ->
      match request.page with
      | None -> true
      | Some page -> about_page page finding)
  in
  let after_offset = List.filteri (fun index _ -> index >= offset) selected in
  let shown, rest = take_within_budget ~limit ~budget:byte_budget [] after_offset in
  let next_offset = offset + List.length shown in
  let truncated = rest <> [] in
  Ok
    (`Assoc
        [ "schema", `String schema
        ; "pages_total", `Int pages_total
        ; "pages_unreadable", `Int pages_unreadable
        ; ( "counts"
          , `Assoc
              (List.map (fun (kind, count) -> kind, `Int count) (Wiki_lint.counts findings)) )
        ; "matched", `Int (List.length selected)
        ; "findings", `List (List.map snd shown)
        ; "truncated", `Bool truncated
        ; ( "next_cursor"
          , if truncated then `String (cursor_prefix ^ string_of_int next_offset) else `Null )
        ])
;;

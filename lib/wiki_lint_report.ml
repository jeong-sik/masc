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
  | Stale_cursor

let problem_to_string = function
  | Unknown_kind kind ->
    Printf.sprintf
      "kind %S is not one of: %s"
      kind
      (String.concat ", " Wiki_lint.all_kinds)
  | Bad_limit -> "limit must be a whole number from 1"
  | Bad_cursor cursor ->
    Printf.sprintf "cursor %S is not a cursor this tool returned" cursor
  | Stale_cursor ->
    "the findings behind that cursor changed (the wiki changed, or `kind`/`page` differ \
     from the call that issued it); call again without cursor to read the findings from \
     the start"
;;

let schema = "masc.wiki_lint.v1"
let default_limit = 50
let max_limit = 200
let byte_budget = 12_000

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
  | Wiki_lint.Revision_log_gap { page; log_revision; page_revision } ->
    `Assoc
      [ "kind", kind
      ; "page", `String page
      ; "log_revision", `Int log_revision
      ; "page_revision", `Int page_revision
      ]
  | Wiki_lint.Revision_log_hole { page; missing } ->
    `Assoc [ "kind", kind; "page", `String page; "missing", `Int missing ]
  | Wiki_lint.Unreadable_page { file; reason } ->
    `Assoc [ "kind", kind; "file", `String file; "reason", `String reason ]
;;

(* A cursor is [o:<offset>:<fingerprint>]. The fingerprint names the filtered
   list the offset counts into, so a cursor from before the wiki changed or from
   a different [kind]/[page] filter is refused instead of silently skipping or
   repeating findings. *)
let fingerprint_length = 12

let fingerprint selected =
  selected
  |> List.map (fun finding -> Yojson.Safe.to_string (finding_to_json finding))
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex
  |> fun hex -> String.sub hex 0 fingerprint_length
;;

let parse_cursor raw =
  match raw with
  | None -> Ok None
  | Some cursor ->
    let bad = Error (Bad_cursor cursor) in
    (match String.split_on_char ':' cursor with
     | [ "o"; offset; print ] when String.length print = fingerprint_length ->
       (match int_of_string_opt offset with
        | Some offset when offset >= 0 -> Ok (Some (offset, print))
        | Some _ | None -> bad)
     | _ -> bad)
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
      if (match acc with [] -> false | _ :: _ -> true) && size > budget
      then List.rev acc, remaining
      else take_within_budget ~limit:(limit - 1) ~budget:(budget - size) ((finding, json) :: acc) rest)
;;

let render ~pages_total ~pages_unreadable ~log ~findings request =
  let open Result.Syntax in
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
  let* cursor = parse_cursor request.cursor in
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
  let print = fingerprint selected in
  let* offset =
    match cursor with
    | None -> Ok 0
    | Some (offset, issued_for) ->
      if String.equal issued_for print then Ok offset else Error Stale_cursor
  in
  let after_offset = List.filteri (fun index _ -> index >= offset) selected in
  let shown, rest = take_within_budget ~limit ~budget:byte_budget [] after_offset in
  let next_offset = offset + List.length shown in
  let truncated = (match rest with [] -> false | _ :: _ -> true) in
  Ok
    (`Assoc
        [ "schema", `String schema
        ; "pages_total", `Int pages_total
        ; "pages_unreadable", `Int pages_unreadable
        ; ( "counts"
          , `Assoc
              (List.map (fun (kind, count) -> kind, `Int count) (Wiki_lint.counts findings)) )
        (* The log's own unread parts, counted so that a line the parser could
           not read is not the same answer as a log with nothing wrong (§7). *)
        ; "log_unknown_action", `Int log.Wiki_log.unknown_action
        ; "log_unreadable_line", `Int log.Wiki_log.unreadable_line
        (* A dropped line above zero turns the hole check off, so a caller
           cannot read an empty revision_log_hole list as "no holes". *)
        ; "revision_log_hole_suppressed", `Bool (Wiki_lint.log_hole_suppressed log)
        ; "matched", `Int (List.length selected)
        ; "findings", `List (List.map snd shown)
        ; "truncated", `Bool truncated
        ; ( "next_cursor"
          , if truncated then `String (Printf.sprintf "o:%d:%s" next_offset print) else `Null )
        ])
;;

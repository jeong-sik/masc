(* One reader for the `---` block at the top of a markdown file.

   Three hand-rolled copies read the same files with different rules: two
   matched the delimiter line exactly, so a file written with CRLF had no
   frontmatter as far as they were concerned, while the third trimmed it and
   read the same file fine. A document's metadata depended on which consumer
   opened it. *)

type t =
  { fields : (string * string) list
  ; body : string
  }

type block =
  | Absent
  | Unclosed
  | Closed of t

let empty content = { fields = []; body = content }

let read content =
  let lines = String.split_on_char '\n' content in
  match lines with
  | first :: rest when String.equal (String.trim first) "---" ->
    let rec collect acc = function
      | [] -> Unclosed
      | line :: remaining when String.equal (String.trim line) "---" ->
        Closed { fields = List.rev acc; body = String.concat "\n" remaining }
      | line :: remaining ->
        let acc =
          match String.index_opt line ':' with
          | Some i ->
            let key = String.trim (String.sub line 0 i) in
            let value =
              String.trim (String.sub line (i + 1) (String.length line - i - 1))
            in
            if String.equal key "" then acc else (key, value) :: acc
          | None -> acc
        in
        collect acc remaining
    in
    collect [] rest
  | _ -> Absent
;;

(* A block that never closes is not frontmatter. Reading it as one threw the
   whole document away: every line became a field candidate and the body came
   back empty, so a prompt with a typo in its closing delimiter loaded as blank
   (#26599). Hand the content back unread instead; a reader that must tell the
   two apart asks [read]. *)
let parse content =
  match read content with
  | Closed parsed -> parsed
  | Absent | Unclosed -> empty content
;;

let field t name =
  match List.assoc_opt name t.fields with
  | Some value -> value
  | None -> ""
;;

(* `tags: [a, b, c]` and `tags: a, b, c` both appeared among the readers this
   replaced. Accept either: dropping the unbracketed form would silently lose
   tags that one of them used to return. *)
let list_field t name =
  let raw = String.trim (field t name) in
  let len = String.length raw in
  let inner =
    if len >= 2 && Char.equal raw.[0] '[' && Char.equal raw.[len - 1] ']'
    then String.sub raw 1 (len - 2)
    else raw
  in
  inner
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> not (String.equal s ""))
;;

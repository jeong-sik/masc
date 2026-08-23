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

let empty content = { fields = []; body = content }

let parse content =
  let lines = String.split_on_char '\n' content in
  match lines with
  | first :: rest when String.equal (String.trim first) "---" ->
    let rec collect acc = function
      | [] -> { fields = List.rev acc; body = "" }
      | line :: remaining when String.equal (String.trim line) "---" ->
        { fields = List.rev acc; body = String.concat "\n" remaining }
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
  | _ -> empty content
;;

let has_frontmatter content =
  match String.split_on_char '\n' content with
  | first :: _ -> String.equal (String.trim first) "---"
  | [] -> false
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

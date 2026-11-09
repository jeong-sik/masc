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
  let len = String.length content in
  if len < 3 then Absent
  else
    let c0 = String.unsafe_get content 0 in
    if c0 <> '-' && c0 <> ' ' && c0 <> '\t' && c0 <> '\r' then Absent
    else
      let next_line start =
        match String.index_from_opt content start '\n' with
        | Some idx -> idx, idx + 1
        | None -> len, len
      in
      let eol1, start_rest = next_line 0 in
      let first = String.sub content 0 eol1 in
      if not (String.equal (String.trim first) "---") then Absent
      else
        let rec collect acc start =
          if start >= len then Unclosed
          else
            let eol, next_start = next_line start in
            let line = String.sub content start (eol - start) in
            if String.equal (String.trim line) "---" then
              let body =
                if next_start >= len then ""
                else String.sub content next_start (len - next_start)
              in
              Closed { fields = List.rev acc; body }
            else
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
              collect acc next_start
        in
        collect [] start_rest
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

(* `tags: [a, b, c]` and `tags: a, b, c` both appeared among the readers this
   replaced. Accept either: dropping the unbracketed form would silently lose
   tags that one of them used to return.

   This takes the value, not the field name. The caller has already looked
   the field up, and whether a missing field is an error or an empty list is
   its call; answering [""] for an absent field here was the third silent
   default this file used to carry. *)
let list_value value =
  let raw = String.trim value in
  let len = String.length raw in
  if len = 0 || String.equal raw "[]" then []
  else
    let inner =
      if len >= 2 && Char.equal (String.unsafe_get raw 0) '[' && Char.equal (String.unsafe_get raw (len - 1)) ']'
      then String.sub raw 1 (len - 2)
      else raw
    in
    match String.index_opt inner ',' with
    | None ->
      let single = String.trim inner in
      if String.equal single "" then [] else [ single ]
    | Some _ ->
      inner
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun s -> not (String.equal s ""))
;;

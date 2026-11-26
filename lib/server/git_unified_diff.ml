type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  section : string option;
}

type row =
  | Hunk of hunk
  | Context of { old_line : int; new_line : int; text : string }
  | Added of { new_line : int; text : string }
  | Deleted of { old_line : int; text : string }

let hunk_open = "@@ "
let hunk_close = " @@"

(* "-12,4" or "+12" (a missing count means one line). *)
let parse_range ~sign token =
  let n = String.length token in
  if n < 2 || token.[0] <> sign then None
  else
    match String.split_on_char ',' (String.sub token 1 (n - 1)) with
    | [ start ] -> Option.map (fun start -> (start, 1)) (int_of_string_opt start)
    | [ start; count ] -> (
        match (int_of_string_opt start, int_of_string_opt count) with
        | Some start, Some count -> Some (start, count)
        | _ -> None)
    | _ -> None

let rec find_sub s ~sub ~from =
  let n = String.length s and m = String.length sub in
  if from + m > n then None
  else if String.equal (String.sub s from m) sub then Some from
  else find_sub s ~sub ~from:(from + 1)

(* "@@ -a,b +c,d @@ section" *)
let parse_hunk_header line =
  let open_len = String.length hunk_open in
  match find_sub line ~sub:hunk_close ~from:open_len with
  | None -> None
  | Some close_at -> (
      let ranges = String.sub line open_len (close_at - open_len) in
      let after = close_at + String.length hunk_close in
      let section =
        if after >= String.length line then None
        else
          (* git separates the context from the closing marker with one space. *)
          match String.sub line (after + 1) (String.length line - after - 1) with
          | "" -> None
          | text -> Some text
      in
      match String.split_on_char ' ' ranges with
      | [ old_range; new_range ] -> (
          match (parse_range ~sign:'-' old_range, parse_range ~sign:'+' new_range) with
          | Some (old_start, old_count), Some (new_start, new_count) ->
              Some { old_start; old_count; new_start; new_count; section }
          | _ -> None)
      | _ -> None)

type state =
  | Between_hunks
  | In_hunk of { old_line : int; new_line : int; old_left : int; new_left : int }

let body_text line = String.sub line 1 (String.length line - 1)

let parse lines =
  let rec go state acc = function
    | [] -> (
        match state with
        | Between_hunks | In_hunk { old_left = 0; new_left = 0; _ } -> Ok (List.rev acc)
        | In_hunk { old_left; new_left; _ } ->
            Error
              (Printf.sprintf "git diff ended with %d old and %d new hunk lines unread"
                 old_left new_left))
    | line :: rest -> (
        match state with
        | In_hunk { old_left = 0; new_left = 0; _ } -> go Between_hunks acc (line :: rest)
        | Between_hunks ->
            if String.starts_with ~prefix:hunk_open line then
              match parse_hunk_header line with
              | None -> Error "malformed hunk header"
              | Some h ->
                  go
                    (In_hunk
                       { old_line = h.old_start; new_line = h.new_start;
                         old_left = h.old_count; new_left = h.new_count })
                    (Hunk h :: acc) rest
            else
              (* File headers: diff --git, index, mode, ---, +++, Binary. *)
              go Between_hunks acc rest
        | In_hunk { old_line; new_line; old_left; new_left } -> (
            match line.[0] with
            | ' ' when old_left > 0 && new_left > 0 ->
                go
                  (In_hunk
                     { old_line = old_line + 1; new_line = new_line + 1;
                       old_left = old_left - 1; new_left = new_left - 1 })
                  (Context { old_line; new_line; text = body_text line } :: acc)
                  rest
            | '-' when old_left > 0 ->
                go
                  (In_hunk
                     { old_line = old_line + 1; new_line; old_left = old_left - 1; new_left })
                  (Deleted { old_line; text = body_text line } :: acc)
                  rest
            | '+' when new_left > 0 ->
                go
                  (In_hunk
                     { old_line; new_line = new_line + 1; old_left; new_left = new_left - 1 })
                  (Added { new_line; text = body_text line } :: acc)
                  rest
            (* "\ No newline at end of file" belongs to the line before it. *)
            | '\\' -> go state acc rest
            | _ ->
                (* The message never quotes the line: it is file content. *)
                Error
                  (Printf.sprintf
                     "diff line without a matching marker with %d old and %d new lines left"
                     old_left new_left)))
  in
  go Between_hunks [] lines

let row_to_json = function
  | Hunk { old_start; old_count; new_start; new_count; section } ->
      `Assoc
        ([ ("kind", `String "hunk"); ("oldStart", `Int old_start);
           ("oldCount", `Int old_count); ("newStart", `Int new_start);
           ("newCount", `Int new_count) ]
        @ match section with Some s -> [ ("section", `String s) ] | None -> [])
  | Context { old_line; new_line; text } ->
      `Assoc
        [ ("kind", `String "context"); ("oldLine", `Int old_line);
          ("newLine", `Int new_line); ("text", `String text) ]
  | Added { new_line; text } ->
      `Assoc
        [ ("kind", `String "add"); ("oldLine", `Null);
          ("newLine", `Int new_line); ("text", `String text) ]
  | Deleted { old_line; text } ->
      `Assoc
        [ ("kind", `String "delete"); ("oldLine", `Int old_line);
          ("newLine", `Null); ("text", `String text) ]

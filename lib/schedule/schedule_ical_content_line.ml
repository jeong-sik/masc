(* See .mli for the contract. RFC 5545 §3.1 content lines. *)

type param = { name : string; values : string list }
type t = { name : string; params : param list; value : string }

type parse_error =
  | Lone_carriage_return of { position : int }
  | Orphan_continuation of { line : int }
  | Empty_name of { line : int }
  | Invalid_name_char of { line : int; name : string }
  | Missing_colon of { line : int }
  | Invalid_param_name_char of { line : int; name : string }
  | Missing_param_equals of { line : int; param : string }
  | Unterminated_quoted_string of { line : int; param : string }
  | Control_character of { line : int; position : int; code : int }

let parse_error_to_string = function
  | Lone_carriage_return { position } ->
    Printf.sprintf "lone CR at byte %d (CR must be followed by LF)" position
  | Orphan_continuation { line } ->
    Printf.sprintf "line %d: folded continuation with no preceding line" line
  | Empty_name { line } -> Printf.sprintf "line %d: empty property name" line
  | Invalid_name_char { line; name } ->
    Printf.sprintf "line %d: invalid property name %S" line name
  | Missing_colon { line } ->
    Printf.sprintf "line %d: content line has no value separator (:)" line
  | Invalid_param_name_char { line; name } ->
    Printf.sprintf "line %d: invalid parameter name %S" line name
  | Missing_param_equals { line; param } ->
    Printf.sprintf "line %d: parameter %S has no = separator" line param
  | Unterminated_quoted_string { line; param } ->
    Printf.sprintf "line %d: parameter %S has an unterminated quoted-string"
      line param
  | Control_character { line; position; code } ->
    Printf.sprintf "line %d: control character 0x%02X at byte %d" line code
      position

(* ---------------------------------------------------------------- *)
(* Unfold                                                           *)
(* ---------------------------------------------------------------- *)

(* Physical lines: CRLF or bare LF delimited; a lone CR is an error. *)
let split_physical input =
  let n = String.length input in
  let rec loop start i acc line_no =
    if i >= n then
      let last = String.sub input start (i - start) in
      Ok (List.rev ((last, line_no) :: acc))
    else
      match input.[i] with
      | '\r' ->
        if i + 1 < n && input.[i + 1] = '\n' then
          loop (i + 2) (i + 2)
            ((String.sub input start (i - start), line_no) :: acc)
            (line_no + 1)
        else Error (Lone_carriage_return { position = i })
      | '\n' ->
        loop (i + 1) (i + 1)
          ((String.sub input start (i - start), line_no) :: acc)
          (line_no + 1)
      | _ -> loop start (i + 1) acc line_no
  in
  loop 0 0 [] 1

(* §3.1 unfolding: a physical line beginning with SPACE/HTAB continues the
   previous logical line (the leading whitespace is removed). Empty physical
   lines carry no content and are skipped. Each returned logical line keeps
   the physical line number it started on for error reporting. *)
let unfold_numbered input =
  match split_physical input with
  | Error _ as error -> error
  | Ok physical ->
    let rec join acc current = function
      | [] -> (
        match current with
        | None -> Ok (List.rev acc)
        | Some pair -> Ok (List.rev (pair :: acc)))
      | (line, line_no) :: rest ->
        if String.length line = 0 then join acc current rest
        else if line.[0] = ' ' || line.[0] = '\t' then (
          let fragment = String.sub line 1 (String.length line - 1) in
          match current with
          | None -> Error (Orphan_continuation { line = line_no })
          | Some (text, start_line) ->
            join acc (Some (text ^ fragment, start_line)) rest)
        else
          let acc =
            match current with
            | None -> acc
            | Some pair -> pair :: acc
          in
          join acc (Some (line, line_no)) rest
    in
    join [] None physical

let unfold input =
  match unfold_numbered input with
  | Error _ as error -> error
  | Ok numbered -> Ok (List.map fst numbered)

(* ---------------------------------------------------------------- *)
(* Parse one logical line                                           *)
(* ---------------------------------------------------------------- *)

let is_name_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  || c = '-'

let valid_name s =
  let n = String.length s in
  n > 0 &&
  let rec loop i = i >= n || (is_name_char s.[i] && loop (i + 1)) in
  loop 0

let is_control c =
  let code = Char.code c in
  (code < 0x20 && c <> '\t') || code = 0x7F

let reject_control ~line text =
  let n = String.length text in
  let rec loop i =
    if i >= n then Ok ()
    else if is_control text.[i] then
      Error (Control_character { line; position = i; code = Char.code text.[i] })
    else loop (i + 1)
  in
  loop 0

(* Index of the first occurrence of [target] outside a quoted-string.
   QSAFE-CHAR excludes DQUOTE, so a quote always toggles quote state. *)
let index_outside_quotes text target =
  let n = String.length text in
  let rec loop i in_quote =
    if i >= n then None
    else
      match text.[i] with
      | '"' -> loop (i + 1) (not in_quote)
      | c when c = target && not in_quote -> Some i
      | _ -> loop (i + 1) in_quote
  in
  loop 0 false

(* Split on [sep] outside quoted-strings, preserving empties. *)
let split_outside_quotes text sep =
  let n = String.length text in
  let rec loop start i in_quote acc =
    if i >= n then List.rev (String.sub text start (i - start) :: acc)
    else
      match text.[i] with
      | '"' -> loop start (i + 1) (not in_quote) acc
      | c when c = sep && not in_quote ->
        loop (i + 1) (i + 1) false (String.sub text start (i - start) :: acc)
      | _ -> loop start (i + 1) in_quote acc
  in
  loop 0 0 false []

let parse_param_value ~line ~param_name raw =
  let n = String.length raw in
  if n > 0 && raw.[0] = '"' then
    if n >= 2 && raw.[n - 1] = '"' then
      Ok (String.sub raw 1 (n - 2))
    else Error (Unterminated_quoted_string { line; param = param_name })
  else Ok raw

let parse_param ~line raw =
  match String.index_opt raw '=' with
  | None -> Error (Missing_param_equals { line; param = raw })
  | Some eq ->
    let name = String.sub raw 0 eq in
    if not (valid_name name) then
      Error (Invalid_param_name_char { line; name })
    else
      let values_raw = String.sub raw (eq + 1) (String.length raw - eq - 1) in
      let pieces = split_outside_quotes values_raw ',' in
      let rec values acc = function
        | [] -> Ok (List.rev acc)
        | piece :: rest -> (
          match parse_param_value ~line ~param_name:name piece with
          | Error _ as error -> error
          | Ok value -> values (value :: acc) rest)
      in
      (match values [] pieces with
       | Error _ as error -> error
       | Ok values -> Ok { name = String.uppercase_ascii name; values })

let parse ~line text =
  match reject_control ~line text with
  | Error _ as error -> error
  | Ok () -> (
    match index_outside_quotes text ':' with
    | None -> Error (Missing_colon { line })
    | Some colon ->
      let head = String.sub text 0 colon in
      let value = String.sub text (colon + 1) (String.length text - colon - 1) in
      let segments = split_outside_quotes head ';' in
      (match segments with
       | [] -> Error (Empty_name { line })
       | name_raw :: params_raw ->
         if String.length name_raw = 0 then Error (Empty_name { line })
         else if not (valid_name name_raw) then
           Error (Invalid_name_char { line; name = name_raw })
         else
           let rec params acc = function
             | [] -> Ok (List.rev acc)
             | raw :: rest -> (
               match parse_param ~line raw with
               | Error _ as error -> error
               | Ok param -> params (param :: acc) rest)
           in
           (match params [] params_raw with
            | Error _ as error -> error
            | Ok params ->
              Ok { name = String.uppercase_ascii name_raw; params; value })))

let parse_many input =
  match unfold_numbered input with
  | Error _ as error -> error
  | Ok lines ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (text, line_no) :: rest -> (
        match parse ~line:line_no text with
        | Error _ as error -> error
        | Ok content_line -> loop (content_line :: acc) rest)
    in
    loop [] lines

let find_param ~name params =
  let upper = String.uppercase_ascii name in
  List.find_opt (fun (p : param) -> String.equal p.name upper) params

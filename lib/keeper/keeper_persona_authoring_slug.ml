(** Persona handle slug generation. *)

let ascii_slug_char = function
  | 'A' .. 'Z' as c -> Some (Char.lowercase_ascii c)
  | 'a' .. 'z' as c -> Some c
  | '0' .. '9' as c -> Some c
  | ('.' | '_' | '-') as c -> Some c
  | ' ' | '\t' | '\n' | '\r' -> Some '-'
  | _ -> None
;;

let collapse_dashes raw =
  let b = Buffer.create (String.length raw) in
  let last_dash = ref false in
  String.iter
    (fun c ->
      if Char.equal c '-'
      then (
        if not !last_dash then Buffer.add_char b c;
        last_dash := true)
      else (
        Buffer.add_char b c;
        last_dash := false))
    raw;
  Buffer.contents b
;;

let trim_dashes raw =
  let len = String.length raw in
  let rec left i =
    if i >= len then len else if Char.equal raw.[i] '-' then left (i + 1) else i
  in
  let rec right i =
    if i < 0 then -1 else if Char.equal raw.[i] '-' then right (i - 1) else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if l > r then "" else String.sub raw l (r - l + 1)
;;

(* TEL-OK: pure slug normalizer; persona authoring callers own action telemetry. *)
let handle_from_concept concept =
  let b = Buffer.create (String.length concept) in
  String.iter
    (fun c ->
      match ascii_slug_char c with
      | Some normalized -> Buffer.add_char b normalized
      | None -> ())
    concept;
  let candidate = Buffer.contents b |> collapse_dashes |> trim_dashes in
  let candidate =
    if String.length candidate > 48 then String.sub candidate 0 48 |> trim_dashes else candidate
  in
  if Keeper_config.validate_name candidate
  then candidate
  else "persona-" ^ String.sub (Digest.to_hex (Digest.string concept)) 0 8
;;

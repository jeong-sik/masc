(** Shared JSON helpers for the llm_provider library. *)

let max_json_nesting_depth = 256

type depth_scan_state =
  | Normal
  | In_string of { escaped : bool }
  | In_line_comment
  | In_block_comment

let check_nesting_depth ?(max_depth = max_json_nesting_depth) raw =
  let len = String.length raw in
  let rec loop i state depth =
    if i >= len
    then Ok ()
    else (
      let ch = raw.[i] in
      match state with
      | In_string { escaped = true } ->
        loop (i + 1) (In_string { escaped = false }) depth
      | In_string { escaped = false } ->
        if Char.equal ch '\\'
        then loop (i + 1) (In_string { escaped = true }) depth
        else if Char.equal ch '"'
        then loop (i + 1) Normal depth
        else loop (i + 1) state depth
      | In_line_comment ->
        (* Yojson terminates [//] comments strictly at ['\n'], not ['\r']. *)
        if Char.equal ch '\n'
        then loop (i + 1) Normal depth
        else loop (i + 1) In_line_comment depth
      | In_block_comment ->
        if Char.equal ch '*' && i + 1 < len && Char.equal raw.[i + 1] '/'
        then loop (i + 2) Normal depth
        else loop (i + 1) In_block_comment depth
      | Normal ->
        (match ch with
         | '/' when i + 1 < len && Char.equal raw.[i + 1] '/' ->
           loop (i + 2) In_line_comment depth
         | '/' when i + 1 < len && Char.equal raw.[i + 1] '*' ->
           loop (i + 2) In_block_comment depth
         | '"' -> loop (i + 1) (In_string { escaped = false }) depth
         | '{' | '[' ->
           let next_depth = depth + 1 in
           if next_depth > max_depth
           then
             Error
               (Printf.sprintf "JSON nesting depth exceeds maximum (%d)" max_depth)
           else loop (i + 1) Normal next_depth
         | '}' | ']' ->
           let next_depth = if depth > 0 then depth - 1 else 0 in
           loop (i + 1) Normal next_depth
         | _ -> loop (i + 1) Normal depth))
  in
  loop 0 Normal 0
;;

let from_string_bounded ?max_depth raw =
  match check_nesting_depth ?max_depth raw with
  | Error _ as err -> err
  | Ok () ->
    (try Ok (Yojson.Safe.from_string raw) with
     | Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
     | Stack_overflow -> Error "JSON nesting depth exceeded parser stack limit")
;;

let from_string_bounded_exn ?max_depth raw =
  match check_nesting_depth ?max_depth raw with
  | Error msg -> raise (Yojson.Json_error msg)
  | Ok () ->
    (try Yojson.Safe.from_string raw with
     | Stack_overflow ->
       raise (Yojson.Json_error "JSON nesting depth exceeded parser stack limit"))
;;

let clamp_non_negative n = if n < 0 then 0 else n

let saturating_add_non_negative a b =
  let a = clamp_non_negative a in
  let b = clamp_non_negative b in
  if a > Int.max_int - b then Int.max_int else a + b
;;

let assoc_member_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let json_type_name = function
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `String _ -> "string"
  | `Int _ | `Intlit _ | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `Null -> "null"
;;

let decode_json_with decoder raw =
  match from_string_bounded raw with
  | Error _ as err -> err
  | Ok json ->
    (try Ok (decoder json) with
     | Yojson.Safe.Util.Type_error (detail, offending) ->
       Error
         (Printf.sprintf
            "unexpected JSON shape: %s (got %s)"
            detail
            (json_type_name offending))
     | Yojson.Safe.Util.Undefined (detail, offending) ->
       Error
         (Printf.sprintf
            "unexpected JSON shape: %s (got %s)"
            detail
            (json_type_name offending)))
;;

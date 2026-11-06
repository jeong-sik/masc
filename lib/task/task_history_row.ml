open Task_history_types
open Task_history_reader

let is_whitespace = function
  | ' ' | '\x0c' | '\n' | '\r' | '\t' -> true
  | _ -> false

let rec is_blank_slice_loop s stop i =
  if i = stop then true
  else if is_whitespace (String.unsafe_get s i) then is_blank_slice_loop s stop (i + 1)
  else false

let is_blank_slice s ~pos ~len =
  is_blank_slice_loop s (pos + len) pos

let is_nonempty_trimmed s =
  let len = String.length s in
  len > 0 && not (is_whitespace s.[0]) && not (is_whitespace s.[len - 1])

let rec small_keys_unique = function
  | [] | [ _ ] -> true
  | (k1, _) :: rest ->
    not (List.exists (fun (k2, _) -> String.equal k1 k2) rest) && small_keys_unique rest

let keys_unique fields =
  let rec is_small n = function
    | [] -> true
    | _ :: rest -> if n >= 16 then false else is_small (n + 1) rest
  in
  if is_small 0 fields then small_keys_unique fields
  else
    let rec check seen = function
      | [] -> true
      | (k, _) :: rest ->
        if String_set.mem k seen then false else check (String_set.add k seen) rest
    in
    check String_set.empty fields

let valid_intlit value =
  try
    match Yojson.Safe.from_string value with
    | `Int _ | `Intlit _ -> true
    | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ -> false
  with Yojson.Json_error _ -> false

let rec valid_json_depth depth json =
  if depth > 64 then
    Result.is_ok (Agent_core.Execution_json.validate ~context:"Task history event" json)
  else
    match json with
    | `Null | `Bool _ | `Int _ | `String _ -> true
    | `Float value -> Float.is_finite value
    | `Intlit value -> valid_intlit value
    | `List values -> List.for_all (valid_json_depth (depth + 1)) values
    | `Assoc fields ->
      keys_unique fields
      && List.for_all (fun (_, value) -> valid_json_depth (depth + 1) value) fields

let valid_json json = valid_json_depth 0 json

let parse_entity = function
  | `Null -> Some None
  | `Assoc [ ("kind", `String kind); ("id", `String id) ]
  | `Assoc [ ("id", `String id); ("kind", `String kind) ] ->
    if is_nonempty_trimmed kind && is_nonempty_trimmed id then Some (Some (kind, id))
    else None
  | _ -> None

let valid_activity_int = function
  | `Int _ -> true
  | other -> Option.is_some (Safe_ops.json_int_opt "k" (`Assoc [ "k", other ]))

let extract_activity_identities fields =
  let rec loop mask subject_id payload_id context_id = function
    | [] ->
      if mask <> 0xff then None
      else
        let acc = match context_id with Some v -> [ v ] | None -> [] in
        let acc = match payload_id with Some v -> v :: acc | None -> acc in
        let acc = match subject_id with Some v -> v :: acc | None -> acc in
        Some acc
    | (key, value) :: rest ->
      (match key with
       | "seq" ->
         if valid_activity_int value then loop (mask lor 1) subject_id payload_id context_id rest
         else None
       | "ts_ms" ->
         if valid_activity_int value then loop (mask lor 2) subject_id payload_id context_id rest
         else None
       | "ts_iso" ->
         (match value with
          | `String _ -> loop (mask lor 4) subject_id payload_id context_id rest
          | _ -> None)
       | "kind" ->
         (match value with
          | `String _ -> loop (mask lor 8) subject_id payload_id context_id rest
          | _ -> None)
       | "actor" ->
         (match parse_entity value with
          | Some _ -> loop (mask lor 16) subject_id payload_id context_id rest
          | None -> None)
       | "subject" ->
         (match parse_entity value with
          | Some (Some ("task", id)) ->
            loop (mask lor 32) (Some (`String id)) payload_id context_id rest
          | Some (Some _ | None) ->
            loop (mask lor 32) subject_id payload_id context_id rest
          | None -> None)
       | "payload" ->
         let pid =
           match value with
           | `Assoc pf -> List.assoc_opt "task_id" pf
           | _ -> None
         in
         loop (mask lor 64) subject_id pid context_id rest
       | "tags" ->
         (match value with
          | `List tags when List.for_all (function `String _ -> true | _ -> false) tags ->
            loop (mask lor 128) subject_id payload_id context_id rest
          | _ -> None)
       | "context" ->
         (match value with
          | `Assoc cf ->
            loop mask subject_id payload_id (List.assoc_opt "task_id" cf) rest
          | _ -> None)
       | _ -> None)
  in
  loop 0 None None None fields

let extract_audit_identities fields =
  match List.assoc_opt "task" fields, List.assoc_opt "task_id" fields with
  | None, None -> []
  | Some v1, None -> [ v1 ]
  | None, Some v2 -> [ v2 ]
  | Some v1, Some v2 -> [ v1; v2 ]

type row_outcome =
  | Row_unrelated
  | Row_task of { task_id : string; json : Yojson.Safe.t }
  | Row_conflicting of { string_ids : string list }
  | Row_invalid

let classify_identities ~json = function
  | [] | [ `Null ] | [ `Null; `Null ] -> Row_unrelated
  | [ `String id ] when is_nonempty_trimmed id -> Row_task { task_id = id; json }
  | [ `String id1; `String id2 ] when is_nonempty_trimmed id1 && String.equal id1 id2 ->
    Row_task { task_id = id1; json }
  | identities ->
    let string_ids =
      List.filter_map
        (function `String id when is_nonempty_trimmed id -> Some id | _ -> None)
        identities
    in
    (match string_ids with
     | [] -> Row_unrelated
     | id0 :: _ ->
       if List.for_all (function `String id -> String.equal id id0 | _ -> false) identities then
         Row_task { task_id = id0; json }
       else
         Row_conflicting { string_ids = List.sort_uniq String.compare string_ids })

let classify_row ~source line =
  match Yojson.Safe.from_string line with
  | `Assoc fields as json ->
    if not (valid_json json) then Row_invalid
    else
      (match source with
       | Audit -> classify_identities ~json (extract_audit_identities fields)
       | Activity ->
         (match extract_activity_identities fields with
          | None -> Row_invalid
          | Some identities -> classify_identities ~json identities))
  | _ -> Row_invalid
  | exception Yojson.Json_error _ -> Row_invalid

(** Keeper tool-usage map and persistence helpers. *)

open Keeper_registry_types

let record usage ~tool_name ~success ~now =
  let entry =
    match StringMap.find_opt tool_name usage with
    | Some entry -> entry
    | None -> { count = 0; successes = 0; failures = 0; last_used_at = 0.0 }
  in
  let updated =
    { count = entry.count + 1
    ; successes = (if success then entry.successes + 1 else entry.successes)
    ; failures = (if success then entry.failures else entry.failures + 1)
    ; last_used_at = now
    }
  in
  StringMap.add tool_name updated usage
;;

let sorted usage =
  StringMap.fold (fun name entry acc -> (name, entry) :: acc) usage []
  |> List.sort (fun (_, left) (_, right) -> Int.compare right.count left.count)
;;

let path ~base_path name =
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers/tool_usage"
  in
  Filename.concat dir (name ^ ".json")
;;

let json_of_snapshot ~name ~flushed_at usage =
  let items =
    StringMap.fold
      (fun tool_name (entry : Keeper_types.tool_call_entry) acc ->
         `Assoc
           [ "tool", `String tool_name
           ; "count", `Int entry.count
           ; "successes", `Int entry.successes
           ; "failures", `Int entry.failures
           ; "last_used_at", `Float entry.last_used_at
           ]
         :: acc)
      usage
      []
  in
  `Assoc
    [ "keeper", `String name
    ; "flushed_at", `Float flushed_at
    ; "tools", `List items
    ]
;;

let save ~base_path ~name ~flushed_at usage =
  let path = path ~base_path name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path (Yojson.Safe.to_string (json_of_snapshot ~name ~flushed_at usage) ^ "\n")
;;

let tool_items_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "tools" fields with
     | Some (`List items) -> items
     | _ -> [])
  | _ -> []
;;

let entry_of_json item =
  match
    ( Safe_ops.json_string_opt "tool" item
    , Safe_ops.json_int_opt "count" item
    , Safe_ops.json_int_opt "successes" item
    , Safe_ops.json_int_opt "failures" item
    , Safe_ops.json_float_opt "last_used_at" item )
  with
  | Some tool_name, Some count, Some successes, Some failures, Some last_used_at
    when tool_name <> "" ->
    Some (tool_name, { count; successes; failures; last_used_at })
  | _ -> None
;;

let load ~base_path ~name =
  let path = path ~base_path name in
  if not (Fs_compat.file_exists path)
  then []
  else
    Fs_compat.load_file path
    |> Yojson.Safe.from_string
    |> tool_items_of_json
    |> List.filter_map entry_of_json
;;

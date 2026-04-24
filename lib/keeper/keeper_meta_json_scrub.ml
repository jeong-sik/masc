(** Keeper meta JSON legacy scrub helpers.

    Kept below the codec/parser facade so persisted runtime JSON can be
    migrated before strict [keeper_meta] decoding. *)

open Keeper_types_profile
open Keeper_meta_contract

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | _ -> json
;;

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error (Printf.sprintf "removed keeper meta fields: %s" (String.concat ", " fields))
;;

let legacy_keeper_meta_tool_policy_key_names =
  [ "tool_preset"; "tool_also_allow"; "tool_custom_allowlist"; "tool_allowlist" ]
;;

let legacy_keeper_meta_key_names =
  "allowed_providers" :: legacy_keeper_meta_tool_policy_key_names
;;

let reject_legacy_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper meta fields require scrub via read_meta_file_path: %s"
         (String.concat ", " fields))
;;

let legacy_tool_access_kind_needs_scrub (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Assoc _ as access_json ->
    (match
       Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
     with
     | Some "restricted" | Some "unrestricted" -> true
     | _ -> false)
  | _ -> false
;;

let scrub_legacy_tool_policy_meta_json (json : Yojson.Safe.t)
  : Yojson.Safe.t * string list
  =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  let missing_tool_access = not (json_member_present "tool_access" json) in
  let legacy_tool_access_kind = legacy_tool_access_kind_needs_scrub json in
  let needs_tool_access_rewrite =
    present <> [] || missing_tool_access || legacy_tool_access_kind
  in
  if not needs_tool_access_rewrite
  then json, []
  else (
    match legacy_tool_access_of_meta_json json with
    | Error _ ->
      let dropped =
        present |> List.filter (fun key -> String.equal key "allowed_providers")
      in
      if dropped = [] then json, [] else drop_assoc_keys dropped json, dropped
    | Ok tool_access ->
      let rewrite_reasons =
        (if missing_tool_access then [ "tool_access(defaulted)" ] else [])
        @ (if legacy_tool_access_kind then [ "tool_access(legacy-kind)" ] else [])
        @ present
      in
      let base = drop_assoc_keys legacy_keeper_meta_key_names json in
      let scrubbed =
        match base with
        | `Assoc fields ->
          `Assoc
            (("tool_access", tool_access_to_json tool_access)
             :: List.remove_assoc "tool_access" fields)
        | _ -> base
      in
      scrubbed, rewrite_reasons)
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  let json, legacy_tool_policy_rewrites = scrub_legacy_tool_policy_meta_json json in
  match json with
  | `Assoc fields ->
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key removed_keeper_meta_key_names then Some key else None)
    in
    if removed_present = [] && legacy_tool_policy_rewrites = []
    then json, false
    else (
      let migrate_legacy_disabled_keepalive =
        (match List.assoc_opt "presence_keepalive" fields with
         | Some (`Bool false) -> true
         | _ -> false)
        && not (List.mem_assoc "paused" fields)
      in
      let scrubbed =
        let base = drop_assoc_keys removed_keeper_meta_key_names json in
        match base with
        | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
          `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
        | _ -> base
      in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed legacy keeper meta fields for %s: %s%s"
           path
           (String.concat ", " (legacy_tool_policy_rewrites @ removed_present))
           (if migrate_legacy_disabled_keepalive
            then " (migrated presence_keepalive=false to paused=true)"
            else "")
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn
           "failed to scrub removed keeper meta fields for %s: %s"
           path
           (Printexc.to_string exn));
      scrubbed, true)
  | _ -> json, false
;;

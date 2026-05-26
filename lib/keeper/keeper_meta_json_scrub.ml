(** Keeper meta JSON removed-field scrub helpers.

    Kept below the codec/parser facade so persisted runtime JSON can be
    normalized before strict [keeper_meta] decoding. *)

open Keeper_types_profile
open Keeper_meta_contract

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ as j -> j
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
  [ "allowed_providers"; "last_blocker_class"; "github_identity" ]
  @ legacy_keeper_meta_tool_policy_key_names
;;

let persisted_retired_keeper_meta_key_names =
  [
    "github_identity";
    "last_work_discovery_ts";
    "work_discovery_count";
    "work_discovery_enabled";
    "work_discovery_sources";
    "work_discovery_interval_sec";
    "work_discovery_guidance";
  ]
;;

let reject_legacy_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper meta fields are no longer supported: %s"
         (String.concat ", " fields))
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  match json with
  | `Assoc fields ->
    let scrub_candidate_key_names =
      removed_keeper_meta_key_names @ persisted_retired_keeper_meta_key_names
    in
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key scrub_candidate_key_names then Some key else None)
    in
    let removed_to_scrub =
      removed_present
      |> List.filter (fun key ->
        (not (List.mem key legacy_keeper_meta_key_names))
        || List.mem key persisted_retired_keeper_meta_key_names)
    in
    if removed_to_scrub = []
    then json, false
    else (
      let migrate_legacy_disabled_keepalive =
        (match List.assoc_opt "presence_keepalive" fields with
         | Some (`Bool false) -> true
         | Some _ | None -> false)
        && not (List.mem_assoc "paused" fields)
      in
      let scrubbed =
        let base = drop_assoc_keys removed_to_scrub json in
        match base with
        | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
          `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
        | `Assoc _ -> base
        | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> base
      in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed legacy keeper meta fields for %s: %s%s"
           path
           (String.concat ", " removed_to_scrub)
           (if migrate_legacy_disabled_keepalive
            then " (migrated presence_keepalive=false to paused=true)"
            else "")
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_meta_json_failures
           ~labels:[("site", "scrub")]
           ();
         Log.Keeper.warn
           "failed to scrub removed keeper meta fields for %s: %s"
           path
           (Printexc.to_string exn));
      scrubbed, true)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ as j -> j, false
;;

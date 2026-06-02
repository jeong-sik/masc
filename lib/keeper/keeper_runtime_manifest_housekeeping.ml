(** Keeper_runtime_manifest_housekeeping — Retention pruning and completeness validation.

    Extracted from [keeper_runtime_manifest.ml] during godfile decomposition.
    Pure housekeeping: old file pruning and structural completeness checks. *)

include Keeper_runtime_manifest_types

(* ═══════════════════════════════════════════════════════════════════════════════
   Retention pruning
   ═══════════════════════════════════════════════════════════════════════════════ *)

let retention_days () =
  (* Opt-in: see lib/keeper_tool_call_log.ml retention_days. *)
  match Sys.getenv_opt "MASC_RUNTIME_MANIFEST_RETENTION_DAYS" with
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some days when days > 0 -> Some days
     | _ -> None)
  | None -> None

let prune_mu = Stdlib.Mutex.create ()
let last_prune_day_by_base_dir : (string, string) Hashtbl.t = Hashtbl.create 64

let today_key () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let is_runtime_manifest_file name =
  String.ends_with ~suffix:".jsonl" name
  && not (String.equal name ".jsonl")
  && String.equal (Filename.basename name) name

let prune_old_trace_files ~base_dir ~days =
  if days <= 0 || not (Sys.file_exists base_dir) then 0
  else (
    let cutoff = Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day) in
    let deleted = ref 0 in
    let entries =
      try Sys.readdir base_dir with
      | Sys_error _ -> [||]
    in
    Array.iter
      (fun name ->
         if is_runtime_manifest_file name
         then (
           let path = Filename.concat base_dir name in
           try
             let st = Unix.stat path in
             if st.Unix.st_kind = Unix.S_REG && st.Unix.st_mtime < cutoff
             then (
               Sys.remove path;
               incr deleted)
           with
           | Unix.Unix_error _ | Sys_error _ -> ()))
      entries;
    !deleted)

let maybe_prune_retention ~base_dir =
  match retention_days () with
  | None -> ()
  | Some days ->
    let today = today_key () in
    let should_prune =
      Stdlib.Mutex.protect prune_mu (fun () ->
        match Hashtbl.find_opt last_prune_day_by_base_dir base_dir with
        | Some day when String.equal day today -> false
        | _ ->
          Hashtbl.replace last_prune_day_by_base_dir base_dir today;
          true)
    in
    if should_prune then ignore (prune_old_trace_files ~base_dir ~days : int)

(* ═══════════════════════════════════════════════════════════════════════════════
   F8: Lane-level mandatory event sets and turn completeness policy.
   ═══════════════════════════════════════════════════════════════════════════════ *)

(** For each event kind, the clock_refs keys that MUST be present for the
    manifest to be considered structurally complete at that lane. *)
let mandatory_clock_refs_for_event = function
  | Turn_started ->
    [ "edge_id"; "lane" ]
  | Provider_attempt_started ->
    [ "edge_id"; "lane"; "provider_attempt_id" ]
  | Provider_attempt_finished ->
    [ "edge_id"; "lane"; "provider_attempt_id"; "elapsed_ms" ]
  | Tool_surface_selected ->
    [ "edge_id"; "lane"; "tool_batch_id" ]
  | Provider_lane_resolved ->
    [ "edge_id"; "lane"; "tool_batch_id" ]
  | Context_compacted ->
    [ "edge_id"; "lane"; "compaction_id"; "compaction_source" ]
  | Checkpoint_saved ->
    [ "edge_id"; "lane"; "checkpoint_id" ]
  | Memory_injected | Memory_flushed ->
    [ "edge_id"; "lane"; "memory_injection_id" ]
  | Receipt_appended ->
    [ "edge_id"; "lane" ]
  | Turn_finished ->
    [ "edge_id"; "lane" ]
  | _ ->
    [ "edge_id"; "lane" ]

let clock_refs_has_keys keys clock_refs_json =
  match clock_refs_json with
  | `Assoc fields ->
    List.for_all
      (fun key -> List.exists (fun (k, _) -> String.equal k key) fields)
      keys
  | _ -> false

let validate_manifest_completeness manifest =
  let required_keys = mandatory_clock_refs_for_event manifest.event in
  match manifest.decision with
  | `Assoc fields ->
    (match List.assoc_opt "clock_refs" fields with
    | Some clock_refs ->
      if clock_refs_has_keys required_keys clock_refs then
        Ok ()
      else
        Error
          (Printf.sprintf
             "manifest for %s missing mandatory clock_refs keys: [%s]"
             (event_kind_to_string manifest.event)
             (String.concat ", "
                (List.filter
                   (fun key -> not (clock_refs_has_keys [ key ] clock_refs))
                   required_keys)))
    | None ->
      Error
        (Printf.sprintf "manifest for %s missing clock_refs entirely"
           (event_kind_to_string manifest.event)))
  | _ ->
    Error
      (Printf.sprintf "manifest for %s has non-assoc decision"
         (event_kind_to_string manifest.event))

(** A turn is "finished" when a [Turn_finished] event exists.
    A turn is "complete" when it is finished AND has both a receipt link
    and a checkpoint link, meaning all mandatory lane artifacts are present. *)
let is_finished_turn manifests =
  List.exists
    (fun m -> m.event = Turn_finished)
    manifests

let is_complete_turn manifests =
  is_finished_turn manifests
  && List.exists
       (fun m ->
         m.event = Receipt_appended
         && Option.is_some m.links.receipt_path)
       manifests
  && List.exists
       (fun m ->
         m.event = Checkpoint_saved
         && Option.is_some m.links.checkpoint_path)
       manifests

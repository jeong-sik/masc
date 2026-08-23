(** Issue #28844: keeper meta invalid-value recovery.

    Feature tests for the 2026-08-16 incident where one non-canonical
    [last_proactive_outcome] value (["\"\"​"]) bricked a keeper: the strict
    parser demanded "runtime reset required", the keepalive scan re-logged the
    same WARN every iteration, and the keeper dropped out of the keepalive
    set until an external rewrite fixed the file.

    Two behaviors are pinned here at the scan/store level:
    1. A non-canonical enumerated field with a canonical default is
       auto-repaired in place through the normal serializer, so the keeper
       rejoins the keepalive set without operator intervention.
    2. The parse-failure WARN is emitted on state transitions (new failure,
       changed reason, recovery) — not on every periodic iteration. *)

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let with_temp_workspace f =
  let base_path = Filename.temp_dir "keeper-meta-invalid-recovery" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None);
      f config)
;;

let write_keeper_toml config name =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    "[keeper]\ninstructions = \"test keeper\"\nsandbox_profile = \"local\"\n"
;;

let keeper_meta_path config name =
  Keeper_types_profile.keeper_meta_path config name
;;

let replace_field field value json =
  match json with
  | `Assoc fields -> `Assoc ((field, value) :: List.remove_assoc field fields)
  | _ -> fail "keeper meta fixture must be a JSON object"
;;

let write_corrupted_meta config name ~field ~value =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name () |> replace_field field value
  in
  let path = keeper_meta_path config name in
  write_file path (Yojson.Safe.pretty_to_string json);
  path
;;

(* [Log.Ring] is the typed in-process log sink; filtering on the unique
   keeper name keeps assertions exact without scraping stderr. *)
let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> 0
;;

let keeper_entries_since seq =
  Log.Ring.recent ~limit:1000 ~since_seq:seq ~module_filter:"Keeper" ~order:`Oldest_first ()
;;

let entries_about needle entries =
  List.filter
    (fun (entry : Log.Ring.entry) ->
       Astring.String.is_infix ~affix:needle entry.message)
    entries
;;

let warns entries =
  List.filter (fun (entry : Log.Ring.entry) -> entry.level = Log.Warn) entries
;;

let infos entries =
  List.filter (fun (entry : Log.Ring.entry) -> entry.level = Log.Info) entries
;;

let test_auto_repair_unbricks_keepalive () =
  with_temp_workspace @@ fun config ->
  let name = "meta-repair-canary" in
  write_keeper_toml config name;
  let path =
    write_corrupted_meta config name ~field:"last_proactive_outcome" ~value:(`String "")
  in
  (* Sentinel values prove the repair rewrites only the offending field. *)
  let corrupted =
    Yojson.Safe.from_string (Masc_test_deps.read_file path)
    |> replace_field "instructions" (`String "keep me")
    |> replace_field "total_turns" (`Int 41)
  in
  write_file path (Yojson.Safe.pretty_to_string corrupted);
  let base_seq = latest_seq () in
  (* The keepalive scan is the path that dropped the keeper in the incident. *)
  let names = Keeper_meta_store.keepalive_keeper_names config in
  check
    (list string)
    "keeper rejoins keepalive set after auto-repair"
    [ name ]
    names;
  (* The file was rewritten through the normal serializer: the offending
     field carries its canonical default, every other field survives. *)
  (match Yojson.Safe.from_string (Masc_test_deps.read_file path) with
   | `Assoc fields ->
     check
       string
       "last_proactive_outcome reset to canonical default"
       "never_started"
       (match List.assoc "last_proactive_outcome" fields with
        | `String value -> value
        | other -> Yojson.Safe.to_string other);
     check
       string
       "instructions preserved"
       "keep me"
       (match List.assoc "instructions" fields with
        | `String value -> value
        | other -> Yojson.Safe.to_string other);
     check
       int
       "total_turns preserved"
       41
       (match List.assoc "total_turns" fields with
        | `Int value -> value
        | _ -> -1)
   | _ -> fail "repaired meta file is not a JSON object");
  (* The read path serves the repaired meta. *)
  (match Keeper_meta_store.read_meta config name with
   | Ok (Some meta) ->
     check
       int
       "read_meta returns repaired snapshot"
       41
       meta.Keeper_meta_contract.runtime.usage.total_turns
   | Ok None -> fail "read_meta lost the keeper after repair"
   | Error detail -> failf "read_meta still rejects repaired meta: %s" detail);
  (* Exactly one repair WARN; a second scan of the now-healthy file is
     silent. *)
  let first_scan_entries = entries_about name (keeper_entries_since base_seq) in
  check
    int
    "one auto-repair WARN per repair"
    1
    (List.length
       (warns first_scan_entries
        |> List.filter (fun (entry : Log.Ring.entry) ->
             Astring.String.is_infix ~affix:"auto-repaired" entry.message)));
  let second_seq = latest_seq () in
  let names = Keeper_meta_store.keepalive_keeper_names config in
  check (list string) "keeper stays in keepalive set" [ name ] names;
  check
    int
    "second scan of repaired file logs nothing"
    0
    (List.length (entries_about name (keeper_entries_since second_seq)))
;;

let test_scan_warns_on_state_transitions_only () =
  with_temp_workspace @@ fun config ->
  let name = "meta-dedupe-canary" in
  write_keeper_toml config name;
  (* A zero generation is non-enumerated corruption: no canonical default
     exists, so the file stays unreadable and the WARN state persists. *)
  let path = write_corrupted_meta config name ~field:"generation" ~value:(`Int 0) in
  let base_seq = latest_seq () in
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  let first_episode =
    warns (entries_about name (keeper_entries_since base_seq))
  in
  (* #29610 fail-open: the unreadable meta is treated as absent and the loss
     is named in a single WARN from the reader; the keepalive scan itself no
     longer adds a second one. *)
  check int "first failure is logged" 1 (List.length first_episode);
  (* Repeated scans of the same (path, failure-reason) state are silent. *)
  let repeat_seq = latest_seq () in
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  check
    int
    "repeated scans of an unchanged failure log nothing"
    0
    (List.length (entries_about name (keeper_entries_since repeat_seq)));
  (* Recovery is a transition: the keeper rejoins the set and the recovery
     is logged once. *)
  let valid = Masc_test_deps.current_meta_json_fixture ~name () in
  write_file path (Yojson.Safe.pretty_to_string valid);
  let recovery_seq = latest_seq () in
  let names = Keeper_meta_store.keepalive_keeper_names config in
  check (list string) "keeper rejoins keepalive set after external fix" [ name ] names;
  let recovery_entries = entries_about name (keeper_entries_since recovery_seq) in
  check int "recovery emits no WARN" 0 (List.length (warns recovery_entries));
  check int "recovery is logged once" 1 (List.length (infos recovery_entries));
  (* A later identical failure is a new state (the previous one cleared), so
     it is logged again — dedupe is state-based, not a time-based rate
     limiter that would still be suppressing it. #29610 fail-open: the reader
     emits one WARN naming the loss, as on the first episode. *)
  ignore (write_corrupted_meta config name ~field:"generation" ~value:(`Int 0));
  let relapse_seq = latest_seq () in
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  check
    int
    "identical failure after recovery logs again"
    1
    (List.length (warns (entries_about name (keeper_entries_since relapse_seq))))
;;

let test_non_enumerated_corruption_fails_open_as_absent () =
  with_temp_workspace @@ fun config ->
  let name = "meta-fail-open-canary" in
  write_keeper_toml config name;
  let path = write_corrupted_meta config name ~field:"generation" ~value:(`Int 0) in
  let before = Masc_test_deps.read_file path in
  let base_seq = latest_seq () in
  (* #29610 fail-open: an unreadable meta is an absent meta, not a dead
     keeper. The read returns Ok(None) and the loss is named in a single
     WARN; the file is left untouched so the evidence survives. *)
  (match Keeper_meta_store.read_meta config name with
   | Ok None -> ()
   | Ok (Some _) -> fail "non-enumerated corruption was silently accepted as a valid meta"
   | Error detail ->
     failf "non-enumerated corruption must be absent, not a fatal error: %s" detail);
  check string "corrupt file is not rewritten" before (Masc_test_deps.read_file path);
  let episode = warns (entries_about name (keeper_entries_since base_seq)) in
  check int "unreadable meta loss is named in one WARN" 1 (List.length episode)
;;

let test_recognized_misspelling_repairs_to_canonical_spelling () =
  with_temp_workspace @@ fun config ->
  let name = "meta-spelling-canary" in
  write_keeper_toml config name;
  (* Both of_string parsers trim and lowercase, so these are recognized
     values with a spelling defect — the operator intent is unambiguous and
     repair must keep it, not reset to the field default. *)
  let path =
    write_corrupted_meta config name ~field:"multimodal_policy" ~value:(`String "DELEGATE")
  in
  let corrupted =
    Yojson.Safe.from_string (Masc_test_deps.read_file path)
    |> replace_field "last_proactive_outcome" (`String "SILENT")
  in
  write_file path (Yojson.Safe.pretty_to_string corrupted);
  (match Keeper_meta_store.read_meta config name with
   | Ok (Some meta) ->
     check
       string
       "multimodal_policy keeps recognized intent"
       "delegate"
       (Keeper_types_profile.multimodal_policy_to_string
          meta.Keeper_meta_contract.multimodal_policy);
     check
       string
       "last_proactive_outcome keeps recognized intent"
       "silent"
       (Keeper_meta_contract.proactive_cycle_outcome_to_string
          meta.runtime.proactive_rt.last_outcome)
   | Ok None -> fail "read_meta lost the keeper"
   | Error detail -> failf "recognized misspelling was rejected: %s" detail);
  (match Yojson.Safe.from_string (Masc_test_deps.read_file path) with
   | `Assoc fields ->
     check
       string
       "persisted policy is the canonical spelling"
       "delegate"
       (match List.assoc "multimodal_policy" fields with
        | `String value -> value
        | other -> Yojson.Safe.to_string other);
     check
       string
       "persisted outcome is the canonical spelling"
       "silent"
       (match List.assoc "last_proactive_outcome" fields with
        | `String value -> value
        | other -> Yojson.Safe.to_string other)
   | _ -> fail "repaired meta file is not a JSON object")
;;

let () =
  run
    "keeper_meta_invalid_recovery"
    [ ( "issue-28844"
      , [ test_case
            "non-canonical enumerated field is auto-repaired and keeper rejoins keepalive"
            `Quick
            test_auto_repair_unbricks_keepalive
        ; test_case
            "recognized misspelling repairs to its canonical spelling"
            `Quick
            test_recognized_misspelling_repairs_to_canonical_spelling
        ; test_case
            "scan WARN is emitted on state transitions only"
            `Quick
            test_scan_warns_on_state_transitions_only
        ; test_case
            "non-enumerated corruption fails open as absent"
            `Quick
            test_non_enumerated_corruption_fails_open_as_absent
        ] )
    ]
;;

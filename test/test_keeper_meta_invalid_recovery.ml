(** Issue #28844: keeper meta invalid-value recovery.

    Feature tests for the 2026-08-16 incident where one non-canonical
    [last_proactive_outcome] value (["\"\"​"]) bricked a keeper: the strict
    parser demanded "runtime reset required", the keepalive scan re-logged the
    same WARN every iteration, and the keeper dropped out of the keepalive
    set until an external rewrite fixed the file.

    Two behaviors are pinned here at the scan/store level:
    1. A reader decodes and never writes: a non-canonical enumerated value
       reads as not current and the file keeps its bytes and mtime, and the
       Owner's writer persists only values the exact decoder reads back.
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
    "[keeper]\ninstructions = \"test keeper\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n"
;;

let keeper_meta_path config name =
  Keeper_types_profile.keeper_meta_path config name
;;

let replace_field field value json =
  match json with
  | `Assoc fields -> `Assoc ((field, value) :: List.remove_assoc field fields)
  | _ -> fail "keeper meta fixture must be a JSON object"
;;

let remove_field field json =
  match json with
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
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

(* Spellings [proactive_cycle_outcome_of_string] does not read back: the
   empty value of the 2026-08-16 incident, labels in another case or with
   surrounding whitespace, and a value that names no outcome. *)
let non_canonical_outcomes = [ ""; "SILENT"; " UNKNOWN"; "not-an-outcome" ]

(* A past mtime no write can keep: a rewrite, atomic or in place, stamps the
   file with the current time. *)
let pinned_mtime = 1_000_000_000.0

let file_mtime path = (Unix.stat path).Unix.st_mtime

(* A reader decodes and never writes. A non-canonical enumerated value is a
   file this binary does not decode as current: it reads as not current with
   the decoder's own detail, and the file keeps its bytes and mtime through
   the direct read and through the periodic scans that read the same file. *)
let test_non_canonical_outcome_is_read_without_writing () =
  List.iteri
    (fun index raw ->
       with_temp_workspace
       @@ fun config ->
       let name = Printf.sprintf "meta-read-only-%d" index in
       write_keeper_toml config name;
       let path =
         write_corrupted_meta
           config
           name
           ~field:"last_proactive_outcome"
           ~value:(`String raw)
       in
       Unix.utimes path pinned_mtime pinned_mtime;
       let before = Masc_test_deps.read_file path in
       let decoder_detail =
         match Keeper_meta_json.meta_of_json (Yojson.Safe.from_string before) with
         | Error detail -> detail
         | Ok _ -> failf "%S decoded as a current outcome" raw
       in
       (match Keeper_meta_store.read_meta_file_path_presence path with
        | Ok (Keeper_meta_store.Meta_not_current detail) ->
          check string (Printf.sprintf "%S: the decoder's detail" raw) decoder_detail detail
        | Ok (Keeper_meta_store.Meta_present _) ->
          failf "%S: a non-canonical outcome was served as current" raw
        | Ok Keeper_meta_store.Meta_absent -> failf "%S: the file was not seen" raw
        | Error detail -> failf "%S: the read was refused: %s" raw detail);
       ignore (Keeper_meta_store.keepalive_keeper_names config);
       ignore (Keeper_meta_store.persistent_agent_names config);
       (match Keeper_meta_store.read_meta config name with
        | Ok None -> ()
        | Ok (Some _) -> failf "%S: read_meta served a non-current meta" raw
        | Error detail -> failf "%S: read_meta refused instead of reading as absent: %s" raw detail);
       check string (Printf.sprintf "%S: bytes unchanged" raw) before
         (Masc_test_deps.read_file path);
       check (float 0.) (Printf.sprintf "%S: mtime unchanged" raw) pinned_mtime
         (file_mtime path))
    non_canonical_outcomes
;;

(* The writer side of the same rule: every outcome the Owner persists through
   [replace_snapshot] comes back from the exact decoder, so no file this binary
   writes is one a reader has to turn away. *)
let test_every_persisted_outcome_decodes_exactly () =
  with_temp_workspace
  @@ fun config ->
  let name = "meta-writer-canary" in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ ("name", `String name) ]) with
    | Ok meta -> meta
    | Error detail -> failf "fixture meta: %s" detail
  in
  let path = keeper_meta_path config name in
  List.iter
    (fun outcome ->
       let label = Keeper_meta_contract.proactive_cycle_outcome_to_string outcome in
       let written =
         { meta with
           Keeper_meta_contract.runtime =
             { meta.Keeper_meta_contract.runtime with
               Keeper_meta_contract.proactive_rt =
                 { meta.Keeper_meta_contract.runtime.proactive_rt with
                   Keeper_meta_contract.last_outcome = outcome
                 }
             }
         }
       in
       (match Keeper_meta_store.replace_snapshot config written with
        | Ok () -> ()
        | Error detail -> failf "%s: the Owner write failed: %s" label detail);
       match
         Keeper_meta_json.meta_of_json
           (Yojson.Safe.from_string (Masc_test_deps.read_file path))
       with
       | Ok read ->
         check
           bool
           (label ^ ": the persisted outcome reads back as itself")
           true
           (read.Keeper_meta_contract.runtime.proactive_rt.last_outcome = outcome)
       | Error detail ->
         failf "%s: the Owner wrote a meta the exact decoder refuses: %s" label detail)
    Keeper_meta_contract.all_proactive_cycle_outcomes
;;


let test_scan_warns_on_state_transitions_only () =
  with_temp_workspace @@ fun config ->
  let name = "meta-dedupe-canary" in
  write_keeper_toml config name;
  (* [generation] is a field this binary no longer writes (#29590), so the
     file is undecodable. Since #29610 the reader fails open — one WARN names the loss and the meta
     reads as absent — and that WARN is deduped on the (path, detail)
     state. *)
  let path = write_corrupted_meta config name ~field:"generation" ~value:(`Int 0) in
  let base_seq = latest_seq () in
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  let first_episode =
    warns (entries_about name (keeper_entries_since base_seq))
  in
  check int "first failure is logged once" 1 (List.length first_episode);
  check
    bool
    "the WARN says the meta is being treated as absent"
    true
    (List.exists
       (fun (entry : Log.Ring.entry) ->
          Astring.String.is_infix ~affix:"treating as absent" entry.message)
       first_episode);
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
     limiter that would still be suppressing it. *)
  ignore (write_corrupted_meta config name ~field:"generation" ~value:(`Int 0));
  let relapse_seq = latest_seq () in
  ignore (Keeper_meta_store.keepalive_keeper_names config);
  check
    int
    "identical failure after recovery logs again"
    1
    (List.length (warns (entries_about name (keeper_entries_since relapse_seq))))
;;

(* #29610: a meta this binary cannot decode reads as absent instead of
   refusing the keeper. The loss is named in a WARN, the corrupt file is left
   for the operator, and nothing is silently rewritten. *)
let test_non_enumerated_corruption_reads_as_absent () =
  with_temp_workspace @@ fun config ->
  let name = "meta-fail-open-canary" in
  write_keeper_toml config name;
  let path = write_corrupted_meta config name ~field:"generation" ~value:(`Int 0) in
  let before = Masc_test_deps.read_file path in
  let base_seq = latest_seq () in
  (match Keeper_meta_store.read_meta config name with
   | Ok None -> ()
   | Ok (Some _) -> fail "undecodable meta was served as a keeper"
   | Error detail -> failf "undecodable meta was refused instead of read as absent: %s" detail);
  let episode = warns (entries_about name (keeper_entries_since base_seq)) in
  check int "the loss is logged once" 1 (List.length episode);
  check
    bool
    "the WARN carries the decode detail"
    true
    (List.exists
       (fun (entry : Log.Ring.entry) ->
          Astring.String.is_infix ~affix:"treating as absent" entry.message
          && Astring.String.is_infix ~affix:"generation" entry.message)
       episode);
  check string "corrupt file is not rewritten" before (Masc_test_deps.read_file path)
;;

(* The deployment gate and the runtime read share one decode
   ([Keeper_meta_json.meta_of_json]); this pins that the
   gate passes a file exactly when the runtime would serve it, names a
   rejection in the words the runtime logs, and never writes. The corpus is
   derived from the writer's current field set, so a schema change reshapes it
   instead of silently leaving a stale literal behind. *)
let test_gate_verdict_matches_runtime_read () =
  with_temp_workspace @@ fun config ->
  let name = "meta-gate-twin-canary" in
  write_keeper_toml config name;
  let path = keeper_meta_path config name in
  let current () = Masc_test_deps.current_meta_json_fixture ~name () in
  let write_json json = write_file path (Yojson.Safe.pretty_to_string json) in
  let runtime_read () = Keeper_meta_store.read_meta_file_path path in
  let expect_accepted label =
    let before = Masc_test_deps.read_file path in
    (match Keeper_meta_store.validate_current_meta_file_result path with
     | Ok () -> ()
     | Error (Keeper_meta_store.Unreadable detail)
     | Error (Keeper_meta_store.Not_current detail) ->
       failf "%s: gate rejected a meta the runtime serves: %s" label detail);
    check string (label ^ ": gate left the file untouched") before
      (Masc_test_deps.read_file path);
    match runtime_read () with
    | Ok (Some _) -> ()
    | Ok None -> failf "%s: runtime read as absent a meta the gate passed" label
    | Error detail -> failf "%s: runtime refused a meta the gate passed: %s" label detail
  in
  let expect_not_current label =
    let gate_detail =
      match Keeper_meta_store.validate_current_meta_file_result path with
      | Error (Keeper_meta_store.Not_current detail) -> detail
      | Error (Keeper_meta_store.Unreadable detail) ->
        failf "%s: gate classed decodable JSON as unreadable: %s" label detail
      | Ok () -> failf "%s: gate passed a meta the runtime discards" label
    in
    let base_seq = latest_seq () in
    (match runtime_read () with
     | Ok None -> ()
     | Ok (Some _) -> failf "%s: runtime served a meta the gate rejected" label
     | Error detail -> failf "%s: runtime refused instead of reading as absent: %s" label detail);
    check
      bool
      (label ^ ": the gate detail is the runtime's fail-open detail")
      true
      (List.exists
         (fun (entry : Log.Ring.entry) ->
            Astring.String.is_infix ~affix:"treating as absent" entry.message
            && Astring.String.is_infix ~affix:gate_detail entry.message)
         (warns (entries_about name (keeper_entries_since base_seq))))
  in
  write_json (current ());
  expect_accepted "current meta";
  write_json (current () |> replace_field "generation" (`Int 0));
  expect_not_current "retired field";
  List.iter
    (fun key ->
       write_json (current () |> remove_field key);
       expect_not_current ("missing " ^ key))
    Keeper_meta_json.current_field_names;
  (* The issue #28844 shape: the runtime reads it as absent and leaves it in
     place, so the gate rejects it in the runtime's words. *)
  write_json
    (current () |> replace_field "last_proactive_outcome" (`String "not-an-outcome"));
  expect_not_current "non-canonical enumerated value";
  (* Not JSON: the runtime read returns [Error] (the boot path refuses the
     keeper instead of re-materialising it), and the gate names that class. *)
  let pretty = Yojson.Safe.pretty_to_string (current ()) in
  write_file path (String.sub pretty 0 64);
  (match Keeper_meta_store.validate_current_meta_file_result path with
   | Error (Keeper_meta_store.Unreadable _) -> ()
   | Error (Keeper_meta_store.Not_current detail) ->
     failf "truncated JSON classed as a schema mismatch: %s" detail
   | Ok () -> fail "gate passed truncated JSON");
  match runtime_read () with
  | Error _ -> ()
  | Ok None -> fail "runtime read truncated JSON as absent instead of refusing it"
  | Ok (Some _) -> fail "runtime served truncated JSON"
;;

(* The parser reads a label back as its outcome only while every outcome has
   its own label: with two outcomes on one label, the second would read back
   as the first. *)
let test_every_outcome_label_reads_back_as_its_outcome () =
  List.iter
    (fun outcome ->
       let label = Keeper_meta_contract.proactive_cycle_outcome_to_string outcome in
       check
         bool
         (Printf.sprintf "%S reads back as its own outcome" label)
         true
         (Keeper_meta_contract.proactive_cycle_outcome_of_string label = Some outcome))
    Keeper_meta_contract.all_proactive_cycle_outcomes
;;

let () =
  run
    "keeper_meta_invalid_recovery"
    [ ( "outcome-labels"
      , [ test_case
            "every outcome label reads back as its outcome"
            `Quick
            test_every_outcome_label_reads_back_as_its_outcome
        ] )
    ; ( "issue-28844"
      , [ test_case
            "non-canonical enumerated field is read without writing"
            `Quick
            test_non_canonical_outcome_is_read_without_writing
        ; test_case
            "every persisted outcome decodes exactly"
            `Quick
            test_every_persisted_outcome_decodes_exactly
        ; test_case
            "scan WARN is emitted on state transitions only"
            `Quick
            test_scan_warns_on_state_transitions_only
        ; test_case
            "non-enumerated corruption reads as absent"
            `Quick
            test_non_enumerated_corruption_reads_as_absent
        ] )
    ; ( "deploy-gate-twin"
      , [ test_case
            "gate verdict matches the runtime read on the current-schema corpus"
            `Quick
            test_gate_verdict_matches_runtime_read
        ] )
    ]
;;

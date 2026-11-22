(** The in-server sweep counts the deletable blobs and records them, and
    deletes nothing. *)

module B = Tool_blob_store
module O = Tool_output
module S = Tool_blob_sweep
module Lane_addon_store = Masc.Lane_addon_store

let scope = Server_tool_blob_scope.scope

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_sweep_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* The touch ledger belongs to the process. Two rotations empty both
   generations, so each case starts from no marks. *)
let forget_marks () =
  B.rotate_touches ();
  B.rotate_touches ()

let put store bytes =
  let (O.Stored reference) = B.put store ~bytes ~mime:"text/plain" in
  reference

let blob_path store (reference : O.artifact_ref) =
  Filename.concat
    (Filename.concat (B.root_dir store) (String.sub reference.sha256 0 2))
    reference.sha256

let set_mtime store reference at = Unix.utimes (blob_path store reference) at at

(* One durable consumer: a Keeper session history line per reference. *)
let reference_in_history ~base_path references =
  let history =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "keepers/keeper-a/sessions/history.jsonl"
  in
  Fs_compat.mkdir_p (Filename.dirname history);
  Fs_compat.save_file
    history
    (String.concat
       ""
       (List.map
          (fun reference ->
             Yojson.Safe.to_string
               (`Assoc
                 [ "consumer", `String "Tool_bridge"
                 ; "output_ref", `String (O.encode_for_agent_core (O.Stored reference))
                 ])
             ^ "\n")
          references))

let observe_ok ~base_path =
  match S.observe ~base_path ~scope with
  | Ok report -> report
  | Error error -> Alcotest.failf "sweep failed: %s" (S.error_to_string error)

let fetch_exists store (reference : O.artifact_ref) =
  match B.fetch store ~sha256:reference.sha256 with
  | Ok value -> Option.is_some value
  | Error error -> Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let long_ago () = Unix.gettimeofday () -. (3.0 *. Masc_time_constants.day)

let test_first_scan_records_candidates_and_waits_a_day () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live = put store "first scan live output" in
      let dead = put store "first scan dead output" in
      reference_in_history ~base_path [ live ];
      forget_marks ();
      (match S.schedule ~base_path ~now:(Unix.gettimeofday ()) with
       | Ok S.Due -> ()
       | Ok (S.Next_at _) -> Alcotest.fail "no scan has opened, so a scan is due"
       | Error error -> Alcotest.fail (S.error_to_string error));
      let report = observe_ok ~base_path in
      Alcotest.(check int) "one live digest" 1 report.live_digests;
      Alcotest.(check int) "two blobs" 2 report.blobs;
      Alcotest.(check int) "one candidate" 1 report.candidates;
      Alcotest.(check int) "nothing deletable without a previous record" 0 report.deletable;
      (match report.previous with
       | S.No_previous_record -> ()
       | S.Previous_record_invalid _ | S.Compared_with_previous _ ->
         Alcotest.fail "the first scan has no previous record");
      Alcotest.(check bool) "record written" true (Sys.file_exists (S.record_path ~base_path));
      Alcotest.(check bool) "candidate still readable" true (fetch_exists store dead);
      let opened = report.scan_started_at in
      (match S.schedule ~base_path ~now:(opened +. 1.0) with
       | Ok (S.Next_at at) ->
         Alcotest.(check (float 0.001)) "next scan a day after this one opened"
           (opened +. Masc_time_constants.day) at
       | Ok S.Due -> Alcotest.fail "a scan opened a second ago"
       | Error error -> Alcotest.fail (S.error_to_string error));
      match S.schedule ~base_path ~now:(opened +. Masc_time_constants.day) with
      | Ok S.Due -> ()
      | Ok (S.Next_at _) -> Alcotest.fail "a day has passed since the scan opened"
      | Error error -> Alcotest.fail (S.error_to_string error))

let test_second_scan_leaves_out_marked_and_rewritten_blobs () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live = put store "second scan live output" in
      let stale = put store "second scan stale output" in
      let read_since = put store "second scan output read since" in
      let written_since = put store "second scan output written since" in
      reference_in_history ~base_path [ live ];
      List.iter (fun reference -> set_mtime store reference (long_ago ()))
        [ stale; read_since; written_since ];
      forget_marks ();
      let first = observe_ok ~base_path in
      Alcotest.(check int) "three candidates" 3 first.candidates;
      Alcotest.(check bool) "read marks the blob" true (fetch_exists store read_since);
      set_mtime store written_since (first.scan_started_at +. 1.0);
      let second = observe_ok ~base_path in
      Alcotest.(check int) "three candidates again" 3 second.candidates;
      Alcotest.(check int) "only the stale blob is deletable" 1 second.deletable;
      Alcotest.(check int) "its bytes" (String.length "second scan stale output")
        second.deletable_bytes;
      Alcotest.(check int) "every candidate was statable" 0 second.unstatable;
      Alcotest.(check bool) "layer one deletes nothing" true (fetch_exists store stale))

let test_previous_deletable_now_live_is_classified () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let put_again = put store "classified output put again" in
      let read_again = put store "classified output read again" in
      let left_alone = put store "classified output left alone" in
      let previous_deletable = [ put_again; read_again; left_alone ] in
      List.iter (fun reference -> set_mtime store reference (long_ago ())) previous_deletable;
      forget_marks ();
      let _first = observe_ok ~base_path in
      let second = observe_ok ~base_path in
      Alcotest.(check int) "all three deletable" 3 second.deletable;
      (* After the record names them deletable, a durable consumer takes all
         three, and the process touches two of them. *)
      reference_in_history ~base_path previous_deletable;
      let (_ : O.t) = B.put store ~bytes:"classified output put again" ~mime:"text/plain" in
      Alcotest.(check bool) "read" true (fetch_exists store read_again);
      let third = observe_ok ~base_path in
      match third.previous with
      | S.No_previous_record | S.Previous_record_invalid _ ->
        Alcotest.fail "the third scan compares with the second"
      | S.Compared_with_previous previous ->
        Alcotest.(check int) "previous deletable" 3 previous.previous_deletable;
        Alcotest.(check int) "one of them read" 1 previous.previous_deletable_read;
        Alcotest.(check int) "put again: the file would be written back" 1
          previous.now_live.rewritten;
        Alcotest.(check int) "read only: the fetch would fail" 1 previous.now_live.read_only;
        Alcotest.(check int) "left alone: a reference without its file" 1
          previous.now_live.untouched;
        Alcotest.(check int) "no candidates now" 0 third.candidates;
        let record = In_channel.with_open_bin (S.record_path ~base_path) In_channel.input_all in
        Alcotest.(check bool) "the record names the reference left without a file" true
          (List.mem ("u " ^ left_alone.sha256) (String.split_on_char '\n' record)))

let test_invalid_record_is_replaced_and_compares_nothing () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let stale = put store "output older than an invalid record" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let _first = observe_ok ~base_path in
      Fs_compat.save_file (S.record_path ~base_path) "not a candidate record\n";
      let replaced = observe_ok ~base_path in
      (match replaced.previous with
       | S.Previous_record_invalid { line; detail = _ } ->
         Alcotest.(check int) "the header line is the invalid one" 1 line
       | S.No_previous_record | S.Compared_with_previous _ ->
         Alcotest.fail "an invalid record is reported as invalid");
      Alcotest.(check int) "nothing deletable without a comparison" 0 replaced.deletable;
      let next = observe_ok ~base_path in
      match next.previous with
      | S.Compared_with_previous _ ->
        Alcotest.(check int) "the replaced record counts as the previous scan" 1 next.deletable
      | S.No_previous_record | S.Previous_record_invalid _ ->
        Alcotest.fail "the scan after a replacement compares with it")

let test_failed_scan_keeps_the_marks () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      forget_marks ();
      let marked = put store "output marked before a failed scan" in
      let _first = observe_ok ~base_path in
      (* A directory where the record belongs cannot be read or replaced. *)
      let record = S.record_path ~base_path in
      Sys.remove record;
      Unix.mkdir record 0o755;
      (match S.observe ~base_path ~scope with
       | Error (S.Record_unreadable _) -> ()
       | Error
           (( S.Scan_failed _ | S.Listing_failed _ | S.Record_write_failed _
            | S.Marker_failed _ ) as error) ->
         Alcotest.failf "expected an unreadable record: %s" (S.error_to_string error)
       | Ok _ -> Alcotest.fail "a directory is not a record");
      Alcotest.(check bool) "the mark survives the failed scan" true
        (Option.is_some (B.touch_of (B.observe_touches ()) ~sha256:marked.sha256)))

(* An entry the scope does not name may hold references the scan never
   reads, so the scan names it and marks nothing deletable. *)
let test_unclassified_entry_leaves_nothing_deletable () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let stale = put store "output older than an unclassified entry" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let _first = observe_ok ~base_path in
      let unlisted = "a-store-the-scope-does-not-name" in
      Unix.mkdir (Filename.concat (Common.masc_dir_from_base_path ~base_path) unlisted) 0o755;
      let second = observe_ok ~base_path in
      Alcotest.(check (list string)) "the entry is named" [ unlisted ] second.unclassified;
      Alcotest.(check int) "the stale blob is still a candidate" 1 second.candidates;
      Alcotest.(check int) "nothing deletable" 0 second.deletable)

(* A private JSONL store keeps a sibling lock that holds one ready marker
   byte. The gate journals are such stores, inside a store the scan reads. *)
let test_private_jsonl_lock_does_not_end_the_scan () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      forget_marks ();
      let kept = put store "output a gate journal row names" in
      let journal =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/late-approval.log.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname journal);
      let row =
        Yojson.Safe.to_string
          (`Assoc [ "output_ref", `String (O.encode_for_agent_core (O.Stored kept)) ])
        ^ "\n"
      in
      (match Fs_compat.append_private_jsonl_durable_stable_result journal row with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf "append failed: %s"
           (Fs_compat.private_jsonl_transaction_error_to_string error));
      Alcotest.(check bool) "the journal has its lock" true
        (Sys.file_exists (Fs_compat.private_jsonl_lock_path journal));
      let first = observe_ok ~base_path in
      Alcotest.(check int) "the named blob is live" 0 first.candidates)

(* 2026-11-06: twelve Finder files sat inside keepers/, traces/ and
   skill-composition-evidence-v1/. The scope excluded one only as a direct
   entry, so the scan read the ones below a store as records. *)
let test_finder_file_below_a_store_does_not_end_the_scan () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      forget_marks ();
      let kept = put store "output a gate journal row names" in
      let gate = Filename.concat (Common.masc_dir_from_base_path ~base_path) "gate" in
      let journal = Filename.concat gate "late-approval.log.jsonl" in
      Fs_compat.mkdir_p gate;
      let row =
        Yojson.Safe.to_string
          (`Assoc [ "output_ref", `String (O.encode_for_agent_core (O.Stored kept)) ])
        ^ "\n"
      in
      (match Fs_compat.append_private_jsonl_durable_stable_result journal row with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf "append failed: %s"
           (Fs_compat.private_jsonl_transaction_error_to_string error));
      Out_channel.with_open_bin
        (Filename.concat gate Tool_blob_maintenance.finder_metadata_name)
        (fun channel -> Out_channel.output_string channel "\000\000\000\001Bud1");
      let first = observe_ok ~base_path in
      Alcotest.(check int) "the named blob is live" 0 first.candidates)

let test_empty_sqlite_and_lane_addon_stores_leave_sweep_classified () =
  with_temp_dir (fun base_path ->
      Unix.chmod base_path 0o700;
      let masc = Common.masc_dir_from_base_path ~base_path in
      Fs_compat.mkdir_p masc;
      Unix.chmod masc 0o700;
      let store = B.create ~base_path in
      let stale = put store "stale output alongside empty sqlite and lane-addons" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let empty_db =
        Filename.concat masc "keepers/keeper-empty/chat-operations.sqlite3"
      in
      Fs_compat.mkdir_p (Filename.dirname empty_db);
      Unix.chmod (Filename.concat masc "keepers") 0o700;
      Unix.chmod (Filename.dirname empty_db) 0o700;
      Fs_compat.save_file empty_db "";
      Unix.chmod empty_db 0o600;
      List.iter
        (fun sub ->
           let dir = Filename.concat (Filename.concat masc "lane-addons") sub in
           Fs_compat.mkdir_p dir;
           Unix.chmod dir 0o700)
        [ "evidence"
        ; "sampling-evidence"
        ; "host-results"
        ; "sampling"
        ; "sampling-outcomes"
        ; "exact-requests"
        ; "tool-request-owners"
        ; "tool-request-bodies"
        ; "keeper-librarian-history-fences"
        ; "keeper-librarian-history-resolutions"
        ];
      let first = observe_ok ~base_path in
      Alcotest.(check (list string)) "all lane-addon subdirectories classified" []
        first.unclassified;
      let second = observe_ok ~base_path in
      Alcotest.(check int) "stale blob becomes deletable on second scan" 1
        second.deletable;
      let wal = empty_db ^ "-wal" in
      Fs_compat.save_file wal "uncheckpointed-or-corrupt-wal";
      Unix.chmod wal 0o600;
      (match S.observe ~base_path ~scope with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "0-byte sqlite with companion WAL must not bypass sqlite inspection"))

(* The folder of the persons of a multi-account installation is classified.
   Its files are not read. Bytes that are no JSON record end no scan, and a
   reference in them keeps no blob live, so the stale blob becomes deletable
   on the second scan. A scope that read the folder as records would stop at
   the first line, and one that read it as payloads would keep the blob. *)
let test_person_folder_leaves_sweep_classified () =
  with_temp_dir (fun base_path ->
      Unix.chmod base_path 0o700;
      let masc = Common.masc_dir_from_base_path ~base_path in
      Fs_compat.mkdir_p masc;
      Unix.chmod masc 0o700;
      let store = B.create ~base_path in
      let stale = put store "stale output beside the folder of the persons" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let person =
        Filename.concat (Filename.concat masc Runtime_account_home_layout.accounts_dir) "person-a"
      in
      let client_file = Filename.concat person "official-clients/claude/state.bin" in
      Fs_compat.mkdir_p (Filename.dirname client_file);
      Fs_compat.save_file client_file
        ("\000not a JSON record\n" ^ O.encode_for_agent_core (O.Stored stale) ^ "\n");
      let first = observe_ok ~base_path in
      Alcotest.(check (list string)) "the folder of the persons is classified" []
        first.unclassified;
      let second = observe_ok ~base_path in
      Alcotest.(check int) "the stale blob becomes deletable on the second scan" 1
        second.deletable)

let test_lane_addon_records_keep_embedded_tool_blobs_live () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let addon_root =
        Lane_addon_store.directory
          ~masc_dir:(Common.masc_dir_from_base_path ~base_path)
      in
      let directories =
        [ "evidence"
        ; "sampling-evidence"
        ; "host-results"
        ; "sampling"
        ; "sampling-outcomes"
        ; Lane_addon_store.exact_requests_directory
        ; Lane_addon_store.tool_request_owners_directory
        ; Lane_addon_store.tool_request_bodies_directory
        ; Lane_addon_store.history_fences_directory
        ; Lane_addon_store.history_resolutions_directory
        ]
      in
      let references =
        List.map
          (fun directory -> put store ("output retained only by " ^ directory))
          directories
      in
      List.iter (fun reference -> set_mtime store reference (long_ago ())) references;
      forget_marks ();
      let first = observe_ok ~base_path in
      Alcotest.(check int) "every blob initially unreferenced"
        (List.length references) first.candidates;
      List.iter2
        (fun directory reference ->
           let path = Filename.concat addon_root (directory ^ "/instance/retained.json") in
           Fs_compat.mkdir_p (Filename.dirname path);
           Fs_compat.save_file path
             (Yojson.Safe.to_string
                (`Assoc
                  [ "retained_input",
                    `Assoc
                      [ "output_ref",
                        `String (O.encode_for_agent_core (O.Stored reference))
                      ]
                  ])))
        directories references;
      let second = observe_ok ~base_path in
      Alcotest.(check (list string)) "all record namespaces classified" []
        second.unclassified;
      Alcotest.(check int) "each record namespace owns its embedded blob"
        (List.length references) second.live_digests;
      Alcotest.(check int) "new owners remove every previous candidate" 0 second.candidates;
      Alcotest.(check int) "no retained blob is deletable" 0 second.deletable)

let test_lane_addon_raw_evidence_keeps_tool_blobs_live () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let addon_root =
        Lane_addon_store.directory
          ~masc_dir:(Common.masc_dir_from_base_path ~base_path)
      in
      let addons = Lane_addon_store.create ~root:addon_root in
      let direct = put store "retained raw evidence output" in
      let recovery = put store "retained sampling recovery output" in
      let structured = put store "retained JSONL evidence output" in
      List.iter (fun reference -> set_mtime store reference (long_ago ()))
        [ direct; recovery; structured ];
      forget_marks ();
      let first = observe_ok ~base_path in
      Alcotest.(check int) "all raw payload blobs start as candidates" 3 first.candidates;
      let retain label = function
        | Ok _ -> ()
        | Error detail -> Alcotest.failf "%s: %s" label detail
      in
      let direct_bytes =
        "raw packet\000\n" ^ O.encode_for_agent_core (O.Stored direct) ^ "\nbody"
      in
      retain "write raw packet" (Lane_addon_store.write_blob addons direct_bytes);
      let recovery_bytes =
        "sampling output\n" ^ O.encode_for_agent_core (O.Stored recovery)
      in
      (* A directory at the canonical immutable address makes the production
         sampling writer retain the same bytes in its recovery namespace. *)
      let blocked_path =
        Filename.concat addon_root
          ("evidence/" ^ Lane_addon_store.digest recovery_bytes ^ ".json")
      in
      Fs_compat.mkdir_p blocked_path;
      retain "write recovery payload"
        (Lane_addon_store.write_sampling_blob addons recovery_bytes);
      retain "write JSONL payload"
        (Lane_addon_store.write_blob addons
           (Yojson.Safe.to_string (O.normalized_artifact_ref_to_json structured)
            ^ "\n{\"other\":true}\n"));
      let second = observe_ok ~base_path in
      Alcotest.(check (list string)) "raw payload stores are classified" []
        second.unclassified;
      Alcotest.(check int) "raw and JSONL payloads retain all blobs" 3 second.live_digests;
      Alcotest.(check int) "raw owners remove old candidates" 0 second.candidates;
      Alcotest.(check int) "no raw payload blob is deletable" 0 second.deletable;
      retain "write malformed reserved reference"
        (Lane_addon_store.write_blob addons
           ("raw packet\n" ^ O.marker_prefix ^ "sha256=garbage]"));
      (match S.observe ~base_path ~scope with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "malformed reserved marker in raw evidence must stop the scan"))

(* .masc/activity-events holds truncated 200-byte observability previews and its
   _seq counter; classifying it as Truncated_copies lets the sweep examine
   stale blobs without reading truncated previews back as live owners. *)
let test_activity_events_leaves_sweep_classified () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live = put store "live output owned by keeper history" in
      let stale = put store "stale output mentioned only in truncated activity preview" in
      reference_in_history ~base_path [ live ];
      set_mtime store stale (long_ago ());
      forget_marks ();
      let activity_dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "activity-events" in
      let day_file = Filename.concat activity_dir "2026-11/2026-11-20.jsonl" in
      Fs_compat.mkdir_p (Filename.dirname day_file);
      Fs_compat.save_file (Filename.concat activity_dir "_seq") "1\n";
      Fs_compat.save_file day_file
        (Yojson.Safe.to_string
           (`Assoc
               [ "kind", `String "tool.called"
               ; "payload", `Assoc [ "tool_args_preview", `String (O.encode_for_agent_core (O.Stored stale) ^ "...(truncated)") ]
               ])
         ^ "\n");
      let first = observe_ok ~base_path in
      Alcotest.(check (list string)) "activity-events is classified" []
        first.unclassified;
      Alcotest.(check int) "only stale blob becomes a candidate" 1 first.candidates;
      let second = observe_ok ~base_path in
      Alcotest.(check (list string)) "activity-events stays classified" []
        second.unclassified;
      Alcotest.(check int) "stale blob becomes deletable on second scan" 1
        second.deletable)

(* .masc/official-clients holds operator and Keeper vendor CLI homes, including
   caches, arbitrary state files, and symlinks; classifying it as
   Vendor_client_home keeps sweep unblocked without reading vendor files. *)
let test_official_clients_leaves_sweep_classified () =
  with_temp_dir (fun base_path ->
      let masc = Common.masc_dir_from_base_path ~base_path in
      Fs_compat.mkdir_p masc;
      let store = B.create ~base_path in
      let stale = put store "stale output beside official-clients home" in
      set_mtime store stale (long_ago ());
      forget_marks ();
      let clients_root = Filename.concat masc Runtime_account_home_layout.clients_dir in
      let codex_state = Filename.concat clients_root "codex/acct-1/state.bin" in
      let codex_link = Filename.concat clients_root "codex-workspaces/abc/link" in
      Fs_compat.mkdir_p (Filename.dirname codex_state);
      Fs_compat.mkdir_p (Filename.dirname codex_link);
      Fs_compat.save_file codex_state
        ("\000not a JSON record\n" ^ O.encode_for_agent_core (O.Stored stale) ^ "\n");
      Unix.symlink base_path codex_link;
      let first = observe_ok ~base_path in
      Alcotest.(check (list string)) "official-clients is classified" []
        first.unclassified;
      let second = observe_ok ~base_path in
      Alcotest.(check (list string)) "official-clients stays classified" []
        second.unclassified;
      Alcotest.(check int) "stale blob becomes deletable on second scan" 1
        second.deletable)

let reclaim_ok ?min_age_seconds ~base_path () =
  match S.reclaim ?min_age_seconds ~base_path ~scope () with
  | Ok report -> report
  | Error error -> Alcotest.failf "reclaim failed: %s" (S.error_to_string error)

let test_malformed_legacy_blob_pins_valid_sha256_and_allows_reclaim () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let pinned = put store "blob referenced by legacy malformed _blob wrapper" in
      let sibling_live = put store "blob referenced in sibling field beside _blob" in
      let dead_old = put store "genuinely unreferenced old blob" in
      let dead_fresh = put store "recently written unreferenced blob" in
      List.iter (fun r -> set_mtime store r (long_ago ())) [ pinned; sibling_live; dead_old ];
      let history =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-legacy/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname history);
      (* Legacy _blob missing preview/mime AND carrying a sibling field (live host failure shape). *)
      let legacy_line =
        Yojson.Safe.to_string
          (`Assoc
            [ "_blob", `Assoc [ "sha256", `String pinned.sha256; "bytes", `Int pinned.bytes ]
            ; "extra_sibling", `String (O.encode_for_agent_core (O.Stored sibling_live))
            ])
        ^ "\n"
      in
      Fs_compat.save_file history legacy_line;
      forget_marks ();
      let first = reclaim_ok ~base_path () in
      Alcotest.(check bool) "legacy malformed warning recorded" true (first.malformed_warnings <> []);
      Alcotest.(check int) "pinned and sibling live digests both kept" 2 first.live_digests;
      Alcotest.(check int) "first scan deletes nothing" 0 first.deleted;
      Alcotest.(check int) "two unreferenced candidates recorded" 2 first.candidates;
      let second = reclaim_ok ~min_age_seconds:Masc_time_constants.day ~base_path () in
      Alcotest.(check int) "only the aged unreferenced blob is deleted" 1 second.deleted;
      Alcotest.(check int) "no delete failures" 0 second.delete_failures;
      Alcotest.(check bool) "aged dead blob removed from disk" false (fetch_exists store dead_old);
      Alcotest.(check bool) "fresh dead blob preserved by 24h age barrier" true (fetch_exists store dead_fresh);
      Alcotest.(check bool) "pinned legacy _blob preserved" true (fetch_exists store pinned);
      Alcotest.(check bool) "sibling live blob preserved" true (fetch_exists store sibling_live))

let test_unpinnable_malformed_blob_blocks_deletion_fail_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let dead_old = put store "aged blob next to unpinnable malformed _blob" in
      set_mtime store dead_old (long_ago ());
      let history =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-bad/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname history);
      Fs_compat.save_file history "{\"_blob\":{\"sha256\":\"corrupt-not-64-hex\"}}\n";
      forget_marks ();
      let first = reclaim_ok ~base_path () in
      Alcotest.(check bool) "candidates-v2 still written despite unpinnable ref" true
        (Sys.file_exists (S.record_path ~base_path));
      Alcotest.(check bool) "unpinnable warning recorded" true
        (List.exists
           (function
             | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> true
             | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> false)
           first.malformed_warnings);
      let second = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "unpinnable ref keeps deletable at 0" 0 second.deletable;
      Alcotest.(check int) "unpinnable ref deletes nothing fail-closed" 0 second.deleted;
      Alcotest.(check bool) "blob stays on disk" true (fetch_exists store dead_old))

let test_reclaim_never_deletes_touched_or_unclassified_blobs () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let touched = put store "blob read between scans" in
      let dead = put store "blob beside unclassified dir" in
      List.iter (fun r -> set_mtime store r (long_ago ())) [ touched; dead ];
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      Alcotest.(check bool) "touch via fetch" true (fetch_exists store touched);
      let unclassified = Filename.concat (Common.masc_dir_from_base_path ~base_path) "mystery-dir" in
      Unix.mkdir unclassified 0o700;
      let blocked = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "unclassified dir blocks all deletion" 0 blocked.deleted;
      Alcotest.(check bool) "dead blob survives unclassified pass" true
        (Sys.file_exists (blob_path store dead));
      Unix.rmdir unclassified;
      let cleaned = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "only untouched dead blob is reclaimed" 1 cleaned.deleted;
      Alcotest.(check bool) "dead blob removed" false
        (Sys.file_exists (blob_path store dead));
      Alcotest.(check bool) "touched blob preserved by touch ledger" true (fetch_exists store touched))

let test_stringified_malformed_blob_siblings_and_duplicate_blob_keys () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob_a = put store "stringified malformed primary blob A" in
      let blob_b = put store "stringified malformed sibling marker blob B" in
      let blob_c = put store "duplicate key first blob C" in
      let blob_d = put store "duplicate key second blob D" in
      let dead_old = put store "unrelated expired dead blob" in
      List.iter (fun r -> set_mtime store r (long_ago ()))
        [ blob_a; blob_b; blob_c; blob_d; dead_old ];
      let masc_root = Common.masc_dir_from_base_path ~base_path in
      let history =
        Filename.concat
          masc_root
          "keepers/keeper-dup/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname history);
      (* Pre-lock .prep_atomic_*.tmp files (at root and inside a Tree store)
         must be classified as unpublished writes and skipped cleanly. *)
      Fs_compat.save_file (Filename.concat masc_root ".prep_atomic_root01.tmp") "{partial";
      Fs_compat.save_file
        (Filename.concat (Filename.dirname history) ".prep_atomic_tree02.tmp")
        "{partial";
      let marker_b = O.encode_for_agent_core (O.Stored blob_b) in
      let stringified_malformed =
        Yojson.Safe.to_string
          (`Assoc
             [ "_blob", `Assoc [ "sha256", `String blob_a.sha256; "bytes", `Int blob_a.bytes ]
             ; "extra", `String marker_b
             ])
      in
      let line1 = Yojson.Safe.to_string (`Assoc [ "payload", `String stringified_malformed ]) in
      let line2 =
        Printf.sprintf
          "{\"_blob\":{\"sha256\":\"%s\",\"bytes\":%d,\"mime\":\"text/plain\",\"preview\":\"\"},\"_blob\":{\"sha256\":\"%s\",\"bytes\":%d,\"mime\":\"text/plain\",\"preview\":\"\"}}"
          blob_c.sha256 blob_c.bytes blob_d.sha256 blob_d.bytes
      in
      Fs_compat.save_file history (line1 ^ "\n" ^ line2 ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let second = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "only unrelated dead blob reclaimed" 1 second.deleted;
      Alcotest.(check bool) "dead blob removed" false (Sys.file_exists (blob_path store dead_old));
      Alcotest.(check bool) "blob A pinned from stringified _blob" true
        (Sys.file_exists (blob_path store blob_a));
      Alcotest.(check bool) "sibling marker blob B preserved from stringified _blob" true
        (Sys.file_exists (blob_path store blob_b));
      Alcotest.(check bool) "duplicate _blob first key C preserved" true
        (Sys.file_exists (blob_path store blob_c));
      Alcotest.(check bool) "duplicate _blob second key D preserved" true
        (Sys.file_exists (blob_path store blob_d));
      (* Duplicate _blob keys where second key is unpinnable must fail closed. *)
      let dead_fail_closed = put store "aged blob next to unpinnable duplicate _blob" in
      set_mtime store dead_fail_closed (long_ago ());
      let line3 =
        Printf.sprintf
          "{\"_blob\":{\"sha256\":\"%s\",\"bytes\":%d},\"_blob\":{\"sha256\":\"not-hex\"}}"
          blob_c.sha256 blob_c.bytes
      in
      Fs_compat.save_file history (line1 ^ "\n" ^ line2 ^ "\n" ^ line3 ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let third = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "unpinnable duplicate _blob blocks deletion fail-closed" 0 third.deleted;
      Alcotest.(check bool) "aged blob preserved fail-closed" true
        (Sys.file_exists (blob_path store dead_fail_closed)))

let test_touch_ledger_overflow_blocks_reclaim_fail_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let dead_old = put store "aged blob during touch ledger overflow" in
      set_mtime store dead_old (long_ago ());
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      (* Exceed the 8,192-entry touch-ledger capacity via real [fetch] marks so
         FIFO eviction sets [current_evicted = true]. *)
      for i = 1 to 8_195 do
        let sha256 = Printf.sprintf "%064x" i in
        ignore (B.fetch store ~sha256)
      done;
      let overflow_current = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "current generation overflow reported" true
        overflow_current.touches.current_evicted;
      Alcotest.(check bool) "previous generation not overflowed yet" false
        overflow_current.touches.previous_evicted;
      Alcotest.(check int) "current overflow blocks deletable fail-closed" 0
        overflow_current.deletable;
      Alcotest.(check int) "current overflow deletes nothing" 0
        overflow_current.deleted;
      Alcotest.(check bool) "blob survives current-generation overflow" true
        (Sys.file_exists (blob_path store dead_old));
      (* Confirm the candidates-v2 header records eviction booleans. *)
      let record_header =
        In_channel.with_open_bin (S.record_path ~base_path) In_channel.input_line
        |> Option.value ~default:""
      in
      (match Yojson.Safe.from_string record_header with
       | `Assoc fields ->
         Alcotest.(check bool) "header records current_evicted=true" true
           (List.assoc_opt "current_evicted" fields = Some (`Bool true));
         Alcotest.(check bool) "header records previous_evicted=false" true
           (List.assoc_opt "previous_evicted" fields = Some (`Bool false))
       | _ -> Alcotest.fail "expected JSON object in candidates-v2 header");
      (* After one rotation, the overflowed generation is now [previous_evicted]. *)
      let overflow_previous = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "current generation clean after rotation" false
        overflow_previous.touches.current_evicted;
      Alcotest.(check bool) "previous generation overflow still blocks deletion" true
        overflow_previous.touches.previous_evicted;
      Alcotest.(check int) "previous overflow blocks deletable fail-closed" 0
        overflow_previous.deletable;
      Alcotest.(check int) "previous overflow deletes nothing" 0
        overflow_previous.deleted;
      Alcotest.(check bool) "blob survives previous-generation overflow" true
        (Sys.file_exists (blob_path store dead_old));
      (* After a second clean rotation, both generations are un-evicted and
         confirmed deletion resumes. *)
      let recovered = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "current clean on recovery" false
        recovered.touches.current_evicted;
      Alcotest.(check bool) "previous clean on recovery" false
        recovered.touches.previous_evicted;
      Alcotest.(check int) "dead blob reclaimed once both generations are clean" 1
        recovered.deleted;
      Alcotest.(check bool) "dead blob removed from disk" false
        (Sys.file_exists (blob_path store dead_old));
      (* Legacy 6-field candidates-v2 headers without eviction fields remain readable. *)
      let dead_legacy = put store "blob recorded in legacy 6-field candidates-v2" in
      set_mtime store dead_legacy (long_ago ());
      forget_marks ();
      let legacy_header =
        Yojson.Safe.to_string
          (`Assoc
             [ "schema_version", `Int 2
             ; "scan_started_at", `Float (Unix.gettimeofday () -. 60.0)
             ; "candidates", `Int 1
             ; "deletable", `Int 0
             ; "untouched_live", `Int 0
             ; "unclassified", `List []
             ])
      in
      Fs_compat.save_file (S.record_path ~base_path)
        (legacy_header ^ "\nc " ^ dead_legacy.sha256 ^ "\n");
      let from_legacy = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      (match from_legacy.previous with
       | S.Compared_with_previous _ -> ()
       | S.No_previous_record | S.Previous_record_invalid _ ->
         Alcotest.fail "legacy 6-field candidates-v2 header must remain parsable");
      Alcotest.(check int) "legacy 6-field record allows gated reclaim" 1 from_legacy.deleted)

let test_legacy_untyped_blob_manifest_expands_children_and_unreadable_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let child_stdout = put store "child stdout owned by untyped legacy manifest" in
      let child_stderr = put store "child stderr owned by untyped legacy manifest" in
      let child_bad_mime = put store "child owned by invalid-mime legacy manifest" in
      let child_empty_mime = put store "child owned by empty-mime legacy manifest" in
      let manifest_missing_mime =
        B.put_durable store
          ~mime:O.artifact_manifest_mime
          ~bytes:
            (O.artifact_manifest_to_json
               ~content:"legacy manifest without mime"
               ~structured_content:
                 (`Assoc
                    [ "stdout_artifact", O.normalized_artifact_ref_to_json child_stdout
                    ; "stderr_artifact", O.normalized_artifact_ref_to_json child_stderr
                    ])
             |> Yojson.Safe.to_string)
      in
      let manifest_invalid_mime =
        B.put_durable store
          ~mime:O.artifact_manifest_mime
          ~bytes:
            (O.artifact_manifest_to_json
               ~content:"legacy manifest with invalid mime"
               ~structured_content:
                 (`Assoc
                    [ "output_artifact", O.normalized_artifact_ref_to_json child_bad_mime ])
             |> Yojson.Safe.to_string)
      in
      let manifest_empty_mime =
        B.put_durable store
          ~mime:O.artifact_manifest_mime
          ~bytes:
            (O.artifact_manifest_to_json
               ~content:"legacy manifest with empty mime"
               ~structured_content:
                 (`Assoc
                    [ "output_artifact", O.normalized_artifact_ref_to_json child_empty_mime ])
             |> Yojson.Safe.to_string)
      in
      let dead_old = put store "unrelated aged dead blob beside legacy manifests" in
      List.iter (fun r -> set_mtime store r (long_ago ()))
        [ child_stdout
        ; child_stderr
        ; child_bad_mime
        ; child_empty_mime
        ; manifest_missing_mime
        ; manifest_invalid_mime
        ; manifest_empty_mime
        ; dead_old
        ];
      let history =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-legacy-manifest/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname history);
      let row_missing_mime =
        Yojson.Safe.to_string
          (`Assoc
             [ ( "_blob"
               , `Assoc
                   [ "sha256", `String manifest_missing_mime.sha256
                   ; "bytes", `Int manifest_missing_mime.bytes
                   ] )
             ])
      in
      let row_invalid_mime =
        Yojson.Safe.to_string
          (`Assoc
             [ ( "_blob"
               , `Assoc
                   [ "sha256", `String manifest_invalid_mime.sha256
                   ; "bytes", `Int manifest_invalid_mime.bytes
                   ; "mime", `Int 42
                   ] )
             ])
      in
      let row_empty_mime =
        Yojson.Safe.to_string
          (`Assoc
             [ ( "_blob"
               , `Assoc
                   [ "sha256", `String manifest_empty_mime.sha256
                   ; "bytes", `Int manifest_empty_mime.bytes
                   ; "mime", `String ""
                   ] )
             ])
      in
      Fs_compat.save_file history
        (row_missing_mime ^ "\n" ^ row_invalid_mime ^ "\n" ^ row_empty_mime ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let second = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "only unrelated dead blob deleted" 1 second.deleted;
      Alcotest.(check bool) "dead blob deleted" false
        (Sys.file_exists (blob_path store dead_old));
      Alcotest.(check bool) "missing-mime manifest preserved" true
        (Sys.file_exists (blob_path store manifest_missing_mime));
      Alcotest.(check bool) "stdout child expanded and preserved" true
        (Sys.file_exists (blob_path store child_stdout));
      Alcotest.(check bool) "stderr child expanded and preserved" true
        (Sys.file_exists (blob_path store child_stderr));
      Alcotest.(check bool) "invalid-mime manifest preserved" true
        (Sys.file_exists (blob_path store manifest_invalid_mime));
      Alcotest.(check bool) "invalid-mime child expanded and preserved" true
        (Sys.file_exists (blob_path store child_bad_mime));
      Alcotest.(check bool) "empty-mime manifest preserved" true
        (Sys.file_exists (blob_path store manifest_empty_mime));
      Alcotest.(check bool) "empty-mime child expanded and preserved" true
        (Sys.file_exists (blob_path store child_empty_mime));
      (* An absent missing-mime legacy _blob cannot prove non-manifest -> fail closed. *)
      let dead_if_absent = put store "aged blob beside absent untyped legacy _blob" in
      set_mtime store dead_if_absent (long_ago ());
      let absent_sha = String.make 64 'f' in
      let row_absent =
        Yojson.Safe.to_string
          (`Assoc [ "_blob", `Assoc [ "sha256", `String absent_sha; "bytes", `Int 10 ] ])
      in
      Fs_compat.save_file history (row_absent ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let blocked_absent = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "absent untyped legacy _blob emits unpinnable warning" true
        (List.exists
           (function
             | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> true
             | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> false)
           blocked_absent.malformed_warnings);
      Alcotest.(check int) "absent untyped legacy _blob keeps deletable at 0" 0
        blocked_absent.deletable;
      Alcotest.(check int) "absent untyped legacy _blob deletes nothing" 0
        blocked_absent.deleted;
      Alcotest.(check bool) "dead blob preserved when untyped ref is absent" true
        (Sys.file_exists (blob_path store dead_if_absent));
      (* A corrupt/unreadable missing-mime legacy _blob also fails closed. *)
      let corrupt_blob = put store "valid before corruption" in
      Fs_compat.save_file (blob_path store corrupt_blob) "corrupted bytes breaking sha256";
      let row_corrupt =
        Yojson.Safe.to_string
          (`Assoc
             [ "_blob", `Assoc [ "sha256", `String corrupt_blob.sha256; "bytes", `Int 10 ] ])
      in
      Fs_compat.save_file history (row_corrupt ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let blocked_corrupt = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "corrupt untyped legacy _blob emits unpinnable warning" true
        (List.exists
           (function
             | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> true
             | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> false)
           blocked_corrupt.malformed_warnings);
      Alcotest.(check int) "corrupt untyped legacy _blob deletes nothing" 0
        blocked_corrupt.deleted;
      Alcotest.(check bool) "dead blob preserved when untyped ref is corrupt" true
        (Sys.file_exists (blob_path store dead_if_absent)))

let test_reclaim_absent_invalid_record_and_delete_failure_reporting () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let dead_a = put store "reclaim candidate A" in
      let rec make_distinct_shard n =
        let candidate = put store (Printf.sprintf "reclaim candidate B-%d" n) in
        if not (String.equal (String.sub candidate.sha256 0 2) (String.sub dead_a.sha256 0 2))
        then candidate
        else (
          ignore (B.delete store ~sha256:candidate.sha256);
          make_distinct_shard (n + 1))
      in
      let dead_b = make_distinct_shard 0 in
      List.iter (fun r -> set_mtime store r (long_ago ())) [ dead_a; dead_b ];
      forget_marks ();
      (* Record_absent: first reclaim deletes nothing and records both candidates. *)
      let first = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      (match first.previous with
       | S.No_previous_record -> ()
       | S.Previous_record_invalid _ | S.Compared_with_previous _ ->
         Alcotest.fail "expected No_previous_record on fresh workspace");
      Alcotest.(check int) "first reclaim deletes nothing" 0 first.deleted;
      Alcotest.(check int) "first reclaim records both candidates" 2 first.candidates;
      (* Previous_record_invalid: corrupted candidates-v2 blocks deletion and is replaced. *)
      Fs_compat.save_file (S.record_path ~base_path) "not-a-valid-header\n";
      let after_corrupt = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      (match after_corrupt.previous with
       | S.Previous_record_invalid _ -> ()
       | S.No_previous_record | S.Compared_with_previous _ ->
         Alcotest.fail "expected Previous_record_invalid after corrupting candidates-v2");
      Alcotest.(check int) "invalid record deletes nothing" 0 after_corrupt.deleted;
      Alcotest.(check int) "invalid record still re-records candidates" 2 after_corrupt.candidates;
      Alcotest.(check bool) "dead_a survives invalid record" true
        (Sys.file_exists (blob_path store dead_a));
      Alcotest.(check bool) "dead_b survives invalid record" true
        (Sys.file_exists (blob_path store dead_b));
      (* Partial delete failure: read-only shard for dead_b surfaces delete_failures=1
         while dead_a succeeds and dead_b remains retained in candidates-v2. *)
      if Unix.geteuid () <> 0
      then (
        let shard_b = Filename.dirname (blob_path store dead_b) in
        Unix.chmod shard_b 0o500;
        let partial =
          Fun.protect
            ~finally:(fun () -> Unix.chmod shard_b 0o700)
            (fun () -> reclaim_ok ~min_age_seconds:0.0 ~base_path ())
        in
        Alcotest.(check int) "one blob deleted despite sibling failure" 1 partial.deleted;
        Alcotest.(check int) "delete failure counted" 1 partial.delete_failures;
        Alcotest.(check int) "failed blob retained as candidate" 1 partial.candidates;
        Alcotest.(check bool) "dead_a removed" false
          (Sys.file_exists (blob_path store dead_a));
        Alcotest.(check bool) "dead_b retained after unlink failure" true
          (Sys.file_exists (blob_path store dead_b)));
      (* Verify Record_write_failed preserves already-deleted counts in error_to_string. *)
      let rendered =
        S.error_to_string
          (S.Record_write_failed
             { path = "/tmp/candidates-v2"
             ; detail = "ENOSPC"
             ; deleted = 2
             ; deleted_bytes = 128
             ; delete_failures = 1
             })
      in
      let contains sub =
        let slen = String.length sub and rlen = String.length rendered in
        let rec loop i =
          if i + slen > rlen then false
          else if String.sub rendered i slen = sub then true
          else loop (i + 1)
        in
        loop 0
      in
      Alcotest.(check bool) "Record_write_failed logs deleted count" true (contains "deleted=2");
      Alcotest.(check bool) "Record_write_failed logs delete_failures count" true
        (contains "delete_failures=1"))

let test_duplicate_sha256_keys_in_malformed_blob_pin_all_or_fail_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob_a = put store "duplicate sha256 first blob A" in
      let blob_b = put store "duplicate sha256 second blob B" in
      let media_c = put store "duplicate sha256 stored media C" in
      let media_d = put store "duplicate sha256 stored media D" in
      let dead_old = put store "unrelated aged dead blob beside duplicate sha256 keys" in
      List.iter (fun r -> set_mtime store r (long_ago ()))
        [ blob_a; blob_b; media_c; media_d; dead_old ];
      let history =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-dup-sha/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname history);
      let dup_blob_row =
        Printf.sprintf
          "{\"_blob\":{\"sha256\":\"%s\",\"sha256\":\"%s\",\"bytes\":10,\"mime\":\"text/plain\",\"preview\":\"\"}}"
          blob_a.sha256 blob_b.sha256
      in
      let dup_media_row =
        Printf.sprintf
          "{\"type\":\"stored\",\"sha256\":\"%s\",\"sha256\":\"%s\",\"media_type\":123}"
          media_c.sha256 media_d.sha256
      in
      Fs_compat.save_file history (dup_blob_row ^ "\n" ^ dup_media_row ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let second = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "only unrelated dead blob deleted" 1 second.deleted;
      Alcotest.(check bool) "dead blob deleted" false
        (Sys.file_exists (blob_path store dead_old));
      Alcotest.(check bool) "first duplicate _blob sha256 preserved" true
        (Sys.file_exists (blob_path store blob_a));
      Alcotest.(check bool) "second duplicate _blob sha256 preserved" true
        (Sys.file_exists (blob_path store blob_b));
      Alcotest.(check bool) "first duplicate stored-media sha256 preserved" true
        (Sys.file_exists (blob_path store media_c));
      Alcotest.(check bool) "second duplicate stored-media sha256 preserved" true
        (Sys.file_exists (blob_path store media_d));
      (* Valid first sha256 paired with invalid second sha256 must fail closed. *)
      let dead_fail_closed = put store "aged blob beside valid+invalid duplicate sha256" in
      set_mtime store dead_fail_closed (long_ago ());
      let bad_dup_blob_row =
        Printf.sprintf
          "{\"_blob\":{\"sha256\":\"%s\",\"sha256\":\"not-hex\",\"bytes\":10,\"mime\":\"text/plain\",\"preview\":\"\"}}"
          blob_a.sha256
      in
      Fs_compat.save_file history (bad_dup_blob_row ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let blocked = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check bool) "invalid duplicate sha256 emits unpinnable warning" true
        (List.exists
           (function
             | Tool_blob_maintenance.Unpinnable_malformed_blob_ref _ -> true
             | Tool_blob_maintenance.Pinned_legacy_blob_ref _ -> false)
           blocked.malformed_warnings);
      Alcotest.(check int) "invalid duplicate sha256 keeps deletable at 0" 0 blocked.deletable;
      Alcotest.(check int) "invalid duplicate sha256 deletes nothing" 0 blocked.deleted;
      Alcotest.(check bool) "dead blob preserved fail-closed" true
        (Sys.file_exists (blob_path store dead_fail_closed));
      (* Same fail-closed check for Invalid_stored_source with valid + invalid sha256. *)
      let bad_dup_media_row =
        Printf.sprintf
          "{\"type\":\"stored\",\"sha256\":\"%s\",\"sha256\":\"not-hex\",\"media_type\":123}"
          media_c.sha256
      in
      Fs_compat.save_file history (bad_dup_media_row ^ "\n");
      forget_marks ();
      ignore (reclaim_ok ~base_path ());
      let blocked_media = reclaim_ok ~min_age_seconds:0.0 ~base_path () in
      Alcotest.(check int) "invalid duplicate stored-media sha256 deletes nothing" 0
        blocked_media.deleted;
      Alcotest.(check bool) "dead blob still preserved fail-closed" true
        (Sys.file_exists (blob_path store dead_fail_closed)))

let () =
  Alcotest.run "tool_blob_sweep"
    [ ( "sweep"
      , [ Alcotest.test_case "first scan records candidates and waits a day" `Quick
            test_first_scan_records_candidates_and_waits_a_day
        ; Alcotest.test_case "malformed legacy _blob pins valid sha256 and allows gated reclaim" `Quick
            test_malformed_legacy_blob_pins_valid_sha256_and_allows_reclaim
        ; Alcotest.test_case "unpinnable malformed _blob blocks deletion fail-closed" `Quick
            test_unpinnable_malformed_blob_blocks_deletion_fail_closed
        ; Alcotest.test_case "stringified malformed _blob siblings and duplicate _blob keys protect all blobs" `Quick
            test_stringified_malformed_blob_siblings_and_duplicate_blob_keys
        ; Alcotest.test_case "touch ledger overflow blocks reclaim fail-closed across both generations" `Quick
            test_touch_ledger_overflow_blocks_reclaim_fail_closed
        ; Alcotest.test_case "legacy untyped _blob manifest expands children and unreadable fails closed" `Quick
            test_legacy_untyped_blob_manifest_expands_children_and_unreadable_fails_closed
        ; Alcotest.test_case "reclaim handles Record_absent, Previous_record_invalid, and partial delete failures" `Quick
            test_reclaim_absent_invalid_record_and_delete_failure_reporting
        ; Alcotest.test_case "duplicate sha256 keys in malformed _blob pin all or fail closed" `Quick
            test_duplicate_sha256_keys_in_malformed_blob_pin_all_or_fail_closed
        ; Alcotest.test_case "reclaim never deletes touched or unclassified blobs" `Quick
            test_reclaim_never_deletes_touched_or_unclassified_blobs
        ; Alcotest.test_case "second scan leaves out marked and rewritten blobs" `Quick
            test_second_scan_leaves_out_marked_and_rewritten_blobs
        ; Alcotest.test_case "previous deletable now live is classified" `Quick
            test_previous_deletable_now_live_is_classified
        ; Alcotest.test_case "invalid record is replaced and compares nothing" `Quick
            test_invalid_record_is_replaced_and_compares_nothing
        ; Alcotest.test_case "failed scan keeps the marks" `Quick
            test_failed_scan_keeps_the_marks
        ; Alcotest.test_case "unclassified entry leaves nothing deletable" `Quick
            test_unclassified_entry_leaves_nothing_deletable
        ; Alcotest.test_case "private JSONL lock does not end the scan" `Quick
            test_private_jsonl_lock_does_not_end_the_scan
        ; Alcotest.test_case "finder file below a store does not end the scan" `Quick
            test_finder_file_below_a_store_does_not_end_the_scan
        ; Alcotest.test_case "empty sqlite and lane-addon stores leave sweep classified" `Quick
            test_empty_sqlite_and_lane_addon_stores_leave_sweep_classified
        ; Alcotest.test_case "the folder of the persons leaves the sweep classified" `Quick
            test_person_folder_leaves_sweep_classified
        ; Alcotest.test_case "activity-events leaves the sweep classified" `Quick
            test_activity_events_leaves_sweep_classified
        ; Alcotest.test_case "official-clients leaves the sweep classified" `Quick
            test_official_clients_leaves_sweep_classified
        ; Alcotest.test_case "lane-addon records keep embedded tool blobs live" `Quick
            test_lane_addon_records_keep_embedded_tool_blobs_live
        ; Alcotest.test_case "lane-addon raw evidence keeps tool blobs live" `Quick
            test_lane_addon_raw_evidence_keeps_tool_blobs_live
        ] )
    ]

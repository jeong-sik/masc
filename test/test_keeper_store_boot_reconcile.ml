(** A store this build cannot decode is settled once, at boot: examined
    without being touched, refused unless the operator accepted the
    quarantine, and moved aside only then (RFC-0420). The goal store is only
    read: boot logs one INFO line when it cannot read it, never refuses or
    moves it, and leaves its bytes as they were (RFC-0444 §2.4, criteria 3
    and 7). *)

open Alcotest
open Masc
module R = Keeper_store_boot_reconcile
module D = Keeper_durable_store
module B = Server_bootstrap_loops

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let with_workspace operation =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* Preparation checks the config base path against its realpath; on macOS
     the temp dir is reached through the /var -> /private/var symlink. *)
  let root = Unix.realpath (Filename.temp_dir "store-boot-reconcile-" "") in
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> operation config)
;;

let meta keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name; "trace_id", `String "trace-reconcile" ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let write_bytes path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc bytes;
  close_out oc
;;

let file_digest path = Digest.to_hex (Digest.file path)

(* One goal row as this build's encoder writes it; the decoder reads every
   member of it back. goals.json is written raw from these rows so no writer
   of the store (and none of its create-time rules) is involved. *)
let goal_row ts =
  Goal_store.goal_to_yojson
    { Goal_store.id = "goal-before-the-hard-cut"
    ; criterion_revision = "fixture-criterion"
    ; title = "Goal before the hard cut"
    ; metric = None
    ; target_value = None
    ; due_date = None
    ; priority = 3
    ; phase = Goal_phase.Executing
    ; last_review_note = None
    ; last_review_at = None
    ; created_at = ts
    ; updated_at = ts
    }
;;

let goals_bytes ts rows =
  Yojson.Safe.to_string
    (`Assoc [ "version", `Int 1; "updated_at", `String ts; "goals", `List rows ])
;;

let goal_bytes_that_read () =
  let ts = Masc_domain.now_iso () in
  goals_bytes ts [ goal_row ts ]
;;

(* goals.json as the #34459 hard cut left it: a row without
   [criterion_revision], in the file and in its .last-good mirror. *)
let goal_bytes_without_criterion_revision () =
  let ts = Masc_domain.now_iso () in
  let row =
    match goal_row ts with
    | `Assoc fields -> `Assoc (List.remove_assoc "criterion_revision" fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      fail "goal serializer returned a non-object"
  in
  goals_bytes ts [ row ]
;;

(* The line boot has to log for the seeded store, rendered from the store's
   own reader: refused on [criterion_revision], with the mirror refused too.
   Any other reading means the fixture is not the #34459 shape. *)
let unavailable_goal_store_line config =
  match Goal_store.load_source config with
  | Goal_store.Unavailable
      ({ Goal_store.reason = Goal_store.Schema_rejected { field; _ }
       ; mirror = Goal_store.Mirror_rejected _
       ; _
       } as unavailable) ->
    check string "the store refuses the missing field" "criterion_revision" field;
    Goal_store.unavailable_to_string unavailable
  | Goal_store.Unavailable unavailable ->
    failf "the goal store was refused another way: %s"
      (Goal_store.unavailable_to_string unavailable)
  | Goal_store.Available _ -> fail "the seeded goal store read as Available"
  | Goal_store.Uninitialized -> fail "the seeded goal store read as Uninitialized"
;;

(* [since_seq] is exclusive and the ring's first entry carries seq 0. *)
let ring_cursor () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

(* The INFO lines [Log.Keeper] wrote after [cursor], oldest first.
   [Log.Keeper] reads [MASC_LOG_KEEPER_LEVEL] once at start-up: a shell that
   sets it above INFO keeps these lines out of the ring and the counts below
   read 0. CI does not set it. *)
let keeper_info_lines_since cursor =
  Log.Ring.recent
    ~limit:Log.Ring.capacity
    ~since_seq:cursor
    ~module_filter:"Keeper"
    ~order:`Oldest_first
    ()
  |> List.filter_map (fun (entry : Log.Ring.entry) ->
    match entry.Log.Ring.level with
    | Log.Info -> Some entry.Log.Ring.message
    | Log.Debug | Log.Warn | Log.Error -> None)
;;

let count_line line lines = List.length (List.filter (String.equal line) lines)

(* One sound meta, one meta that is not a current snapshot, one memory
   snapshot that is not JSON, and a goal store this build refuses in both
   its files. *)
type fixture =
  { sound_meta : string
  ; broken_meta : string
  ; broken_snapshot : string
  ; goals : string
  ; goals_mirror : string
  }

let seed config =
  (match Keeper_meta_store.replace_snapshot config (meta "sound") with
   | Ok () -> ()
   | Error detail -> fail detail);
  let sound_meta = Keeper_types_profile.keeper_meta_path config "sound" in
  let broken_meta = Keeper_types_profile.keeper_meta_path config "broken" in
  write_bytes broken_meta "{\"name\":\"broken\"}";
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  let broken_snapshot =
    Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"sound"
  in
  write_bytes broken_snapshot "{ this is not a snapshot";
  let goals = Goal_store.goals_path config in
  let goals_mirror = goals ^ ".last-good" in
  let goal_bytes = goal_bytes_without_criterion_revision () in
  write_bytes goals goal_bytes;
  write_bytes goals_mirror goal_bytes;
  { sound_meta; broken_meta; broken_snapshot; goals; goals_mirror }
;;

let goal_digests fixture = file_digest fixture.goals, file_digest fixture.goals_mirror

let check_goal_digests label fixture (goals, goals_mirror) =
  check string (label ^ ": goals.json digest") goals (file_digest fixture.goals);
  check string (label ^ ": .last-good digest") goals_mirror (file_digest fixture.goals_mirror)
;;

let stores_of undecodable =
  List.map (fun (u : R.undecodable) -> R.store_to_string u.R.store) undecodable
;;

let test_examine_reads_and_moves_nothing () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let digests = goal_digests fixture in
  let line = unavailable_goal_store_line config in
  let cursor = ring_cursor () in
  let examination = R.examine config in
  check int "readable" 1 examination.R.readable;
  check int "one INFO line for the unreadable goal store" 1
    (count_line line (keeper_info_lines_since cursor));
  check (list string) "both broken stores are named, meta first"
    [ "keeper_meta"; "memory_current" ]
    (stores_of examination.R.undecodable);
  List.iter
    (fun (u : R.undecodable) ->
       check bool (u.R.path ^ " is still where it was") true (Sys.file_exists u.R.path);
       check bool (u.R.path ^ " says why") true (String.length u.R.rejection > 0))
    examination.R.undecodable;
  check (list string) "the paths are the seeded files"
    [ fixture.broken_meta; fixture.broken_snapshot ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  let again = R.examine config in
  check (list string) "a second look gives the same answer"
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable)
    (List.map (fun (u : R.undecodable) -> u.R.path) again.R.undecodable);
  check int "one INFO line per look" 2 (count_line line (keeper_info_lines_since cursor));
  check_goal_digests "after two looks" fixture digests;
  check int "and no rejected copy appeared" 0
    (Sys.readdir (Filename.dirname fixture.broken_snapshot)
     |> Array.to_list
     |> List.filter (fun name -> String_util.contains_substring name ".rejected-")
     |> List.length)
;;

(* A goal store that does not exist yet, or that reads, is not a line;
   otherwise every fresh install would log a false INFO at each boot. The
   workspace holds no keeper, and the other examiners write no Keeper INFO
   line of their own. *)
let test_examine_is_silent_on_a_goal_store_that_is_absent_or_reads () =
  with_workspace
  @@ fun config ->
  (match Goal_store.load_source config with
   | Goal_store.Uninitialized -> ()
   | Goal_store.Available _ -> fail "a fresh workspace already had a goal store"
   | Goal_store.Unavailable unavailable ->
     failf "a fresh workspace read as %s" (Goal_store.unavailable_to_string unavailable));
  let cursor = ring_cursor () in
  let (_ : R.examination) = R.examine config in
  check (list string) "no INFO line for an absent goal store" []
    (keeper_info_lines_since cursor);
  write_bytes (Goal_store.goals_path config) (goal_bytes_that_read ());
  (match Goal_store.load_source config with
   | Goal_store.Available state ->
     check int "the written store reads its one goal" 1 (List.length state.Goal_store.goals)
   | Goal_store.Uninitialized -> fail "the written goal store read as Uninitialized"
   | Goal_store.Unavailable unavailable ->
     failf "the written goal store read as %s"
       (Goal_store.unavailable_to_string unavailable));
  let cursor = ring_cursor () in
  let (_ : R.examination) = R.examine config in
  check (list string) "no INFO line for a goal store that reads" []
    (keeper_info_lines_since cursor)
;;

let test_admit_refuses_only_undecodable_without_the_flag () =
  let clean = { R.readable = 3; undecodable = [] } in
  let broken =
    { R.readable = 1
    ; undecodable =
        [ { R.store = D.Refusing.Memory_current
          ; keeper = "sound"
          ; path = "/w/sound.memory-current.json"
          ; rejection = "invalid JSON"
          }
        ]
    }
  in
  (match R.admit ~accept_quarantine:false clean with
   | Ok admitted -> check int "nothing undecodable passes without the flag" 3 admitted.R.readable
   | Error _ -> fail "a clean examination was refused");
  (match R.admit ~accept_quarantine:false broken with
   | Error refused ->
     check (list string) "the refusal names the store" [ "memory_current" ] (stores_of refused)
   | Ok _ -> fail "an undecodable store passed without the flag");
  match R.admit ~accept_quarantine:true broken with
  | Ok admitted ->
    check int "the flag lets the undecodable store through to quarantine" 1
      (List.length admitted.R.undecodable)
  | Error _ -> fail "the flag did not admit the quarantine"
;;

let test_refusal_names_each_store_and_both_ways_forward () =
  let text =
    R.refusal_to_string
      [ { R.store = D.Refusing.Keeper_meta
        ; keeper = "broken"
        ; path = "/w/.masc/keepers/broken.json"
        ; rejection = "field set mismatch (missing: trace_id)"
        }
      ; { R.store = D.Refusing.Memory_current
        ; keeper = "sound"
        ; path = "/w/config/keepers/sound.memory-current.json"
        ; rejection = "invalid JSON: Line 1"
        }
      ]
  in
  let has needle = check bool ("mentions " ^ needle) true (String_util.contains_substring text needle) in
  has "boot refused: 2 store(s)";
  has "keeper_meta keeper=broken path=/w/.masc/keepers/broken.json: field set mismatch (missing: trace_id)";
  has "memory_current keeper=sound path=/w/config/keepers/sound.memory-current.json: invalid JSON: Line 1";
  has "validate-stores";
  has "--accept-store-quarantine";
  check int "one line per store plus the heading and the ways forward" 4
    (List.length (String.split_on_char '\n' text))
;;

let test_undecodable_stores_are_moved_aside_once () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let digests = goal_digests fixture in
  let report = R.quarantine ~now:1_700_000_000.0 config (R.examine config) in
  check int "examined" 3 report.R.examined;
  check int "readable" 1 report.R.readable;
  check int "quarantined" 2 (List.length report.R.quarantined);
  check int "failed" 0 (List.length report.R.failed);
  check bool "the broken meta is gone from its path" false (Sys.file_exists fixture.broken_meta);
  check bool "the broken snapshot is gone from its path" false
    (Sys.file_exists fixture.broken_snapshot);
  List.iter
    (fun (q : R.quarantined) ->
       check bool (q.R.path ^ " kept as bytes") true (Sys.file_exists q.R.rejected_path);
       check int (q.R.path ^ " moved alone") 0 (List.length q.R.moved_with);
       check bool (q.R.path ^ " says why") true (String.length q.R.rejection > 0))
    report.R.quarantined;
  check (list string) "both stores are named"
    [ "keeper_meta"; "memory_current" ]
    (List.map (fun (q : R.quarantined) -> R.store_to_string q.R.store) report.R.quarantined);
  check bool "the sound meta still reads" true
    (Result.is_ok (Keeper_meta_store.validate_current_meta_file_result fixture.sound_meta));
  check_goal_digests "after the quarantine" fixture digests;
  let again = R.examine config in
  check int "a second boot finds nothing to move" 0 (List.length again.R.undecodable);
  check int "and still reads the sound meta" 1 again.R.readable;
  let counted = R.quarantine ~now:1_700_000_001.0 config again in
  check int "quarantine with nothing undecodable only counts" 1 counted.R.examined;
  check int "and moves nothing" 0 (List.length counted.R.quarantined)
;;

(* The whole preparation, as the server runs it: refused without the flag with
   the file untouched, moved aside with it. The goal store gives one line per
   boot and keeps its bytes through both. *)
let test_preparation_refuses_then_moves_aside_with_the_flag () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let digests = goal_digests fixture in
  let line = unavailable_goal_store_line config in
  let cursor = ring_cursor () in
  Fun.protect
    ~finally:B.For_testing.reset_keeper_persistence_lifecycle
    (fun () ->
       B.For_testing.reset_keeper_persistence_lifecycle ();
       (match B.prepare_keeper_persistence ~accept_store_quarantine:false ~config () with
        | Error (B.Store_quarantine_refused undecodable) ->
          check (list string) "the refusal names both stores"
            [ "keeper_meta"; "memory_current" ]
            (stores_of undecodable);
          check bool "the broken snapshot is untouched" true
            (Sys.file_exists fixture.broken_snapshot);
          check bool "the broken meta is untouched" true (Sys.file_exists fixture.broken_meta);
          check bool "the refusal text reaches the operator" true
            (String_util.contains_substring
               (B.keeper_persistence_prepare_error_to_string
                  (B.Store_quarantine_refused undecodable))
               fixture.broken_snapshot)
        | Error error ->
          failf "preparation failed for another reason: %s"
            (B.keeper_persistence_prepare_error_to_string error)
        | Ok _ -> fail "preparation went on past an undecodable store without the flag");
       check_goal_digests "after the refused boot" fixture digests;
       B.For_testing.reset_keeper_persistence_lifecycle ();
       match B.prepare_keeper_persistence ~accept_store_quarantine:true ~config () with
       | Ok _ ->
         check bool "with the flag the broken snapshot is moved aside" false
           (Sys.file_exists fixture.broken_snapshot);
         check bool "and the broken meta too" false (Sys.file_exists fixture.broken_meta);
         check_goal_digests "after the accepted quarantine" fixture digests;
         check int "one INFO line per boot, two boots" 2
           (count_line line (keeper_info_lines_since cursor))
       | Error error ->
         failf "preparation with the flag failed: %s"
           (B.keeper_persistence_prepare_error_to_string error))
;;

(* The deploy preflight and boot read one list (Keeper_durable_store). For a
   store boot refuses on, both must refuse the same file: a build that boot
   refuses would otherwise have passed the preflight, or the reverse. The
   goal store degrades at boot and has no preflight reader. *)
let test_preflight_refuses_what_boot_names () =
  with_workspace
  @@ fun config ->
  let fixture = seed config in
  let base_path = config.Workspace.base_path in
  let first_refusal id =
    match D.reader id with
    | D.Refuse_boot (_, scan) | D.Preflight_only scan ->
      (match D.run scan ~base_path with
       | Ok { D.refused = 1; first_refusal = Some detail; _ } -> detail
       | Ok report -> failf "%s: refused %d, not 1" (D.name id) report.D.refused
       | Error detail -> failf "%s: scan failed: %s" (D.name id) detail)
    | D.Degrade_typed _ -> failf "%s: no preflight reader" (D.name id)
  in
  let examination = R.examine config in
  check (list string) "boot names both refusing stores"
    [ "keeper_meta"; "memory_current" ]
    (stores_of examination.R.undecodable);
  check bool "the preflight refuses the keeper meta file boot names" true
    (String.starts_with ~prefix:(fixture.broken_meta ^ ": ") (first_refusal D.Id.Keeper_meta));
  check bool "the preflight refuses the snapshot of the keeper boot names" true
    (String.starts_with ~prefix:"sound: " (first_refusal D.Id.Memory_current));
  check bool "the goal store boot reports has no preflight reader" true
    (match D.reader D.Id.Goal_store with
     | D.Degrade_typed D.Reported.Goal_store -> true
     | D.Refuse_boot _ | D.Preflight_only _ -> false)
;;

(* [Id.all] is derived. Each store boot refuses on or reports must be
   reached from exactly one id, or boot would read it twice or never. *)
let test_every_boot_store_has_exactly_one_id () =
  let refusing =
    List.filter_map
      (fun id ->
         match D.reader id with
         | D.Refuse_boot (store, _) -> Some store
         | D.Degrade_typed _ | D.Preflight_only _ -> None)
      D.Id.all
  in
  let reported =
    List.filter_map
      (fun id ->
         match D.reader id with
         | D.Degrade_typed store -> Some store
         | D.Refuse_boot _ | D.Preflight_only _ -> None)
      D.Id.all
  in
  check bool "each refusing store once" true
    (List.sort compare refusing = List.sort compare D.Refusing.all);
  check bool "each reported store once" true
    (List.sort compare reported = List.sort compare D.Reported.all);
  let names = List.map D.name D.Id.all in
  check int "names are distinct" (List.length names)
    (List.length (List.sort_uniq String.compare names));
  List.iter
    (fun id ->
       let read_by_preflight = Option.is_some (D.preflight_scan id) in
       match D.reader id with
       | D.Refuse_boot _ | D.Preflight_only _ ->
         check bool (D.name id ^ ": the deploy preflight reads it") true read_by_preflight
       | D.Degrade_typed _ ->
         check bool (D.name id ^ ": the deploy preflight leaves it to boot") false
           read_by_preflight)
    D.Id.all
;;

(* 2026-09-26: a binding written before the official-client session schema
   hard cut (#38986) made every turn of its keeper fail, and boot did not
   read that store. Boot now refuses it and names the file; the preflight
   refuses the same file; the accepted quarantine moves it aside under the
   store lock, so the keeper's next claim finds no binding and starts a new
   vendor session. *)
let test_an_unreadable_session_binding_refuses_boot () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let path =
    match Keeper_official_client_session_store.path ~base_path ~keeper_name:"sound" with
    | Ok path -> path
    | Error detail -> fail detail
  in
  write_bytes path "{\"schema\":\"masc.keeper.official-client-session.v1\"}";
  let digest = file_digest path in
  let examination = R.examine config in
  check (list string) "boot names the binding" [ "official_client_session" ]
    (stores_of examination.R.undecodable);
  check (list string) "at its path" [ path ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  (match R.admit ~accept_quarantine:false examination with
   | Ok _ -> fail "boot must refuse a binding this build cannot read"
   | Error undecodable ->
     let refusal = R.refusal_to_string undecodable in
     check bool "the refusal names the keeper and the path" true
       (String_util.contains_substring
          refusal
          ("official_client_session keeper=sound path=" ^ path)));
  check string "the refused binding is untouched" digest (file_digest path);
  (match D.reader D.Id.Official_client_session with
   | D.Refuse_boot (_, scan) ->
     (match D.run scan ~base_path with
      | Ok { D.refused = 1; first_refusal = Some detail; _ } ->
        check bool "the preflight refuses the same keeper's binding" true
          (String.starts_with ~prefix:"sound: " detail)
      | Ok report -> failf "the preflight refused %d, not 1" report.D.refused
      | Error detail -> failf "preflight scan failed: %s" detail)
   | D.Degrade_typed _ | D.Preflight_only _ -> fail "the session store refuses boot");
  let report = R.quarantine ~now:1_700_000_002.0 config examination in
  (match report.R.quarantined, report.R.failed with
   | [ { R.rejected_path; moved_with = []; _ } ], [] ->
     check bool "the binding is gone" false (Sys.file_exists path);
     check string "the rejected copy keeps the bytes" digest (file_digest rejected_path)
   | _ -> fail "exactly one binding is moved aside");
  (match Keeper_official_client_session_store.load ~base_path ~keeper_name:"sound" with
   | Ok None -> ()
   | Ok (Some _) -> fail "a binding survived the quarantine"
   | Error detail -> failf "the store still refuses after the quarantine: %s" detail);
  (* The next claim plans from no binding and writes a fresh one beside the
     rejected copy. *)
  match
    Keeper_official_client_session_store.claim
      ~base_path
      ~keeper_name:"sound"
      ~expected:None
      ~client_kind:Keeper_official_client_session_store.Claude_code
      ~owner_epoch:(Keeper_official_client_session_store.process_epoch ())
      ~runtime_id:"claude_code.fixture"
      ~tool_surface_sha256:(String.make 64 'a')
      ~updated_at:1_700_000_003.0
  with
  | Error detail -> failf "the claim after the quarantine failed: %s" detail
  | Ok (_ : Keeper_official_client_session_store.t) ->
    (match Keeper_official_client_session_store.load ~base_path ~keeper_name:"sound" with
     | Ok (Some _) -> ()
     | Ok None -> fail "the claim wrote no binding"
     | Error detail -> failf "the fresh binding does not read back: %s" detail)
;;

(* A claim reads a binding through a linked keeper directory, so boot must
   read it the same way, or a v1 binding behind the link stops every turn of
   that keeper while boot names nothing. *)
let test_a_binding_behind_a_linked_keeper_directory_refuses_boot () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let path =
    match Keeper_official_client_session_store.path ~base_path ~keeper_name:"linked" with
    | Ok path -> path
    | Error detail -> fail detail
  in
  let keeper_dir = Filename.dirname (Filename.dirname path) in
  let target = Filename.concat base_path "linked-keeper-elsewhere" in
  Fs_compat.mkdir_p target;
  Fs_compat.mkdir_p (Filename.dirname keeper_dir);
  Unix.symlink target keeper_dir;
  write_bytes path "{\"schema\":\"masc.keeper.official-client-session.v1\"}";
  let examination = R.examine config in
  check (list string) "boot names the binding behind the link" [ "official_client_session" ]
    (stores_of examination.R.undecodable);
  check (list string) "for the linked keeper" [ "linked" ]
    (List.map (fun (u : R.undecodable) -> u.R.keeper) examination.R.undecodable)
;;

let queue_dir ~base_path = Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) "sound"

(* A snapshot the v19 reader accepts: no pending stimulus, nothing in flight. *)
let current_snapshot_bytes =
  {|{"schema":"keeper.event_queue.state.v19","revision":1,"pending":[],"last_transition":null,"projected_dispositions":[],"transition_outbox":[],"accepted_transfer_projections":[]}|}
;;

let queue_files ~base_path =
  let dir = queue_dir ~base_path in
  ( Filename.concat dir Keeper_event_queue_persistence.snapshot_filename
  , Filename.concat dir Keeper_event_queue_persistence.transition_wal_filename )
;;

let check_queue_starts_empty ~base_path =
  let module Q = Keeper_event_queue_persistence in
  (match Q.durable_state_exists_result ~base_path ~keeper_name:"sound" with
   | Ok false -> ()
   | Ok true -> fail "durable queue state survived the quarantine"
   | Error detail -> fail detail);
  match Q.load_result ~base_path ~keeper_name:"sound" with
  | Ok queue ->
    check int "the next load starts the empty queue" 0 (Keeper_event_queue.length queue)
  | Error detail -> failf "the queue still refuses after the quarantine: %s" detail
;;

(* A queue this build cannot decode keeps its keeper from registering
   (#37900), and until this step only the deploy preflight read it. Boot now
   refuses it, the preflight refuses the same keeper, and the accepted
   quarantine moves the snapshot and its WAL together, the rejected snapshot
   last, so the next load starts the empty queue. *)
let test_an_unreadable_event_queue_refuses_boot () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let snapshot, wal = queue_files ~base_path in
  write_bytes snapshot "{\"schema\":\"keeper.event_queue.state.v18\"}";
  write_bytes wal "{not-json\n";
  let snapshot_digest = file_digest snapshot in
  let wal_digest = file_digest wal in
  let examination = R.examine config in
  check (list string) "boot names the queue" [ "event_queue" ]
    (stores_of examination.R.undecodable);
  check (list string) "at its snapshot" [ snapshot ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  (match R.admit ~accept_quarantine:false examination with
   | Ok _ -> fail "boot must refuse a queue this build cannot read"
   | Error undecodable ->
     check bool "the refusal names the keeper and the path" true
       (String_util.contains_substring
          (R.refusal_to_string undecodable)
          ("event_queue keeper=sound path=" ^ snapshot)));
  check string "the refused snapshot is untouched" snapshot_digest (file_digest snapshot);
  check string "the refused WAL is untouched" wal_digest (file_digest wal);
  (match D.reader D.Id.Keeper_event_queue with
   | D.Refuse_boot (_, scan) ->
     (match D.run scan ~base_path with
      | Ok { D.refused = 1; first_refusal = Some detail; _ } ->
        check bool "the preflight refuses the same keeper's queue" true
          (String.starts_with ~prefix:"sound: " detail)
      | Ok report -> failf "the preflight refused %d, not 1" report.D.refused
      | Error detail -> failf "preflight scan failed: %s" detail)
   | D.Degrade_typed _ | D.Preflight_only _ -> fail "the event queue refuses boot");
  let report = R.quarantine ~now:1_700_000_004.0 config examination in
  (match report.R.quarantined, report.R.failed with
   | [ { R.rejected_path; moved_with = [ (moved, rejected_wal) ]; _ } ], [] ->
     check string "the WAL moved with it" wal moved;
     check bool "the snapshot is gone" false (Sys.file_exists snapshot);
     check bool "the WAL is gone" false (Sys.file_exists wal);
     check string "the rejected snapshot keeps the bytes" snapshot_digest
       (file_digest rejected_path);
     check string "the rejected WAL keeps the bytes" wal_digest (file_digest rejected_wal)
   | [ _ ], [] -> fail "the snapshot and the WAL move together"
   | _ -> fail "exactly one queue is moved aside");
  check_queue_starts_empty ~base_path
;;

(* With no snapshot the WAL is the queue, so the refusal names the WAL: a
   path to a file that does not exist would send the operator to the wrong
   place. *)
let test_a_wal_only_queue_is_named_by_its_wal () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let _, wal = queue_files ~base_path in
  write_bytes wal "{not-json\n";
  let wal_digest = file_digest wal in
  let examination = R.examine config in
  check (list string) "boot names the queue at its WAL" [ wal ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  let report = R.quarantine ~now:1_700_000_005.0 config examination in
  (match report.R.quarantined, report.R.failed with
   | [ { R.rejected_path; moved_with = []; _ } ], [] ->
     check bool "the WAL is gone" false (Sys.file_exists wal);
     check string "the rejected WAL keeps the bytes" wal_digest (file_digest rejected_path)
   | _ -> fail "exactly the WAL is moved aside");
  check_queue_starts_empty ~base_path
;;

(* The snapshot decodes and the WAL on top of it does not. The row names the
   WAL, the file the operator has to look at, and the WAL moves last. *)
let test_a_bad_wal_over_a_good_snapshot_is_named_by_its_wal () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let snapshot, wal = queue_files ~base_path in
  write_bytes snapshot current_snapshot_bytes;
  write_bytes wal "{not-json\n";
  let examination = R.examine config in
  check (list string) "boot names the queue at its WAL" [ wal ]
    (List.map (fun (u : R.undecodable) -> u.R.path) examination.R.undecodable);
  let report = R.quarantine ~now:1_700_000_006.0 config examination in
  (match report.R.quarantined, report.R.failed with
   | [ { R.rejected_path; moved_with = [ (moved, rejected_snapshot) ]; _ } ], [] ->
     check string "the snapshot moved with it" snapshot moved;
     check bool "the rejected WAL is kept" true (Sys.file_exists rejected_path);
     check bool "the snapshot is kept" true (Sys.file_exists rejected_snapshot)
   | _ -> fail "the WAL and its snapshot move together");
  check_queue_starts_empty ~base_path
;;

(* A move that stops between the two renames must not leave a pair the next
   boot reads as a queue. The rejected file moves last, so it is the one that
   stays, and boot refuses again at it; the error names the file already
   moved. *)
let test_a_half_finished_move_leaves_the_rejected_file_and_boot_refuses_again () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let snapshot, wal = queue_files ~base_path in
  write_bytes snapshot "{\"schema\":\"keeper.event_queue.state.v18\"}";
  write_bytes wal "";
  let unreachable = Filename.concat base_path "no-such-directory/rejected" in
  let rejected_wal = wal ^ ".rejected-test" in
  (match
     Keeper_event_queue_persistence.move_aside_undecodable_result
       ~base_path
       ~keeper_name:"sound"
       ~rejected_path_of:(fun path -> if path = snapshot then unreachable else rejected_wal)
   with
   | Ok _ -> fail "the snapshot cannot be renamed into a missing directory"
   | Error detail ->
     check bool "the error names the WAL already moved" true
       (String_util.contains_substring detail rejected_wal));
  check bool "the WAL moved first" true (Sys.file_exists rejected_wal);
  check bool "the rejected snapshot stays" true (Sys.file_exists snapshot);
  check (list string) "the next boot refuses again at the snapshot" [ snapshot ]
    (List.map (fun (u : R.undecodable) -> u.R.path) (R.examine config).R.undecodable)
;;

(* State that reads by the time the lock is held is left where it is. *)
let test_a_queue_that_decodes_is_not_moved () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace.base_path in
  let snapshot, _ = queue_files ~base_path in
  write_bytes snapshot current_snapshot_bytes;
  let digest = file_digest snapshot in
  check int "boot names nothing" 0 (List.length (R.examine config).R.undecodable);
  (match
     Keeper_event_queue_persistence.move_aside_undecodable_result
       ~base_path
       ~keeper_name:"sound"
       ~rejected_path_of:(fun path -> path ^ ".rejected-test")
   with
   | Ok _ -> fail "a queue that decodes must not move"
   | Error (_ : string) -> ());
  check string "the snapshot is untouched" digest (file_digest snapshot)
;;

let () =
  run
    "keeper store boot reconcile"
    [ ( "examine"
      , [ test_case "reads every store and moves nothing" `Quick
            test_examine_reads_and_moves_nothing
        ; test_case "is silent on a goal store that is absent or reads" `Quick
            test_examine_is_silent_on_a_goal_store_that_is_absent_or_reads
        ] )
    ; ( "admit"
      , [ test_case "refuses only undecodable stores without the flag" `Quick
            test_admit_refuses_only_undecodable_without_the_flag
        ; test_case "the refusal names each store and both ways forward" `Quick
            test_refusal_names_each_store_and_both_ways_forward
        ] )
    ; ( "quarantine"
      , [ test_case "undecodable stores are moved aside once" `Quick
            test_undecodable_stores_are_moved_aside_once
        ] )
    ; ( "preparation"
      , [ test_case "refuses without the flag and moves aside with it" `Quick
            test_preparation_refuses_then_moves_aside_with_the_flag
        ] )
    ; ( "one list"
      , [ test_case "the preflight refuses what boot names" `Quick
            test_preflight_refuses_what_boot_names
        ; test_case "every boot store has exactly one id" `Quick
            test_every_boot_store_has_exactly_one_id
        ] )
    ; ( "official-client session"
      , [ test_case "an unreadable binding refuses boot and moves aside under its lock"
            `Quick test_an_unreadable_session_binding_refuses_boot
        ; test_case "a binding behind a linked keeper directory refuses boot" `Quick
            test_a_binding_behind_a_linked_keeper_directory_refuses_boot
        ] )
    ; ( "event queue"
      , [ test_case "an unreadable queue refuses boot and moves aside with its WAL" `Quick
            test_an_unreadable_event_queue_refuses_boot
        ; test_case "a WAL-only queue is named by its WAL" `Quick
            test_a_wal_only_queue_is_named_by_its_wal
        ; test_case "a bad WAL over a good snapshot is named by its WAL" `Quick
            test_a_bad_wal_over_a_good_snapshot_is_named_by_its_wal
        ; test_case "a half-finished move leaves the rejected file" `Quick
            test_a_half_finished_move_leaves_the_rejected_file_and_boot_refuses_again
        ; test_case "a queue that decodes is not moved" `Quick
            test_a_queue_that_decodes_is_not_moved
        ] )
    ]
;;

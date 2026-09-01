(* The librarian's journal, projected for the dashboard.

   The internal-agents monitor could already show that a librarian pass ran.
   What it could not show is what the pass decided, and a failed pass is the
   case an operator actually opens. These cases hold the properties that make
   the projection worth trusting: a failure and a commit are different shapes,
   an undecodable line keeps its place, and the drop reasons survive. *)

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module U = Yojson.Safe.Util

let keeper = "test-keeper"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-journal-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

let with_keepers_dir f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  f dir
;;

let append_raw ~keepers_dir line =
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:keeper in
  let out = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  output_string out (line ^ "\n");
  close_out out
;;

let read_json ~keepers_dir =
  Current.read_journal_tail ~keepers_dir ~keeper_id:keeper ~limit:50
  |> List.map Current.journal_line_to_json
;;

let field json name = U.member name json

(* A failure has no revision. Projecting both shapes into one object with null
   fields would make a reader check a null to tell them apart, and a reader
   that has to check will eventually forget. *)
let test_failure_and_commit_project_to_different_shapes () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id:keeper
      ~now:1_700_000_000.0
      ~trace_id:"trace-a"
      ~kind:Exact_execution_failure
      ~detail:"provider returned 503"
      ~snapshot_present:true
      ~cadence_deferred:true;
    let fact : Types.fact =
      Types.observed ~claim:"a claim" ~category:Fact ~now:1_700_000_000.0
        ~origin:{ kind = Authored; trace_id = "" }
    in
    (match
       Current.replace
         ~keepers_dir
         ~keeper_id:keeper
         ~expected_revision:None
         ~now:1_700_000_100.0
         ~source:{ kind = Librarian; trace_id = "trace-b" }
         ~facts:[ fact ]
         ()
     with
     | Ok _ -> ()
     | Error reason -> Alcotest.failf "replace failed: %s" reason);
    match read_json ~keepers_dir with
    | [ failed; committed ] ->
      Alcotest.(check bool) "both lines decoded" true
        (U.to_bool (field failed "ok") && U.to_bool (field committed "ok"));
      Alcotest.(check string) "failure outcome" "failed"
        (U.to_string (field failed "outcome"));
      Alcotest.(check string) "commit outcome" "committed"
        (U.to_string (field committed "outcome"));
      Alcotest.(check string) "failure names its kind" "exact_execution_failure"
        (U.to_string (field failed "kind"));
      Alcotest.(check bool) "failure carries no revision" true
        (field failed "revision" = `Null);
      Alcotest.(check int) "commit carries its revision" 1
        (U.to_int (field committed "revision"));
      Alcotest.(check bool) "commit carries no failure kind" true
        (field committed "kind" = `Null)
    | lines -> Alcotest.failf "expected two lines, got %d" (List.length lines))
;;

(* The whole reason the failure line exists: an operator asking why memory did
   not advance needs the detail, not just that something failed. *)
let test_failure_carries_its_detail_and_deferral () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id:keeper
      ~now:1_700_000_000.0
      ~trace_id:"trace-a"
      ~kind:Runtime_context_unavailable
      ~detail:"Eio net/clock context unavailable"
      ~snapshot_present:false
      ~cadence_deferred:false;
    match read_json ~keepers_dir with
    | [ line ] ->
      Alcotest.(check string) "detail survives"
        "Eio net/clock context unavailable"
        (U.to_string (field line "detail"));
      Alcotest.(check bool) "snapshot presence is stated" false
        (U.to_bool (field line "snapshot_present"));
      Alcotest.(check bool) "cadence deferral is stated" false
        (U.to_bool (field line "cadence_deferred"));
      Alcotest.(check string) "trace id survives" "trace-a"
        (U.to_string (field line "trace_id"))
    | lines -> Alcotest.failf "expected one line, got %d" (List.length lines))
;;

(* A torn line occupies its own position. Collapsing it would make a damaged
   journal read as a shorter one, and the operator counting passes is the one
   who would be misled. *)
let test_undecodable_line_keeps_its_position_and_reason () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir ~keeper_id:keeper ~now:1.0 ~trace_id:"before"
      ~kind:Domain_output_invalid ~detail:"d" ~snapshot_present:true
      ~cadence_deferred:false;
    append_raw ~keepers_dir "{not json";
    Current.append_librarian_failure
      ~keepers_dir ~keeper_id:keeper ~now:2.0 ~trace_id:"after"
      ~kind:Domain_output_invalid ~detail:"d" ~snapshot_present:true
      ~cadence_deferred:false;
    match read_json ~keepers_dir with
    | [ before; torn; after ] ->
      Alcotest.(check string) "first is intact" "before"
        (U.to_string (field before "trace_id"));
      Alcotest.(check bool) "torn line is marked" false (U.to_bool (field torn "ok"));
      Alcotest.(check bool) "and carries a reason" true
        (String.length (U.to_string (field torn "error")) > 0);
      Alcotest.(check string) "third is intact" "after"
        (U.to_string (field after "trace_id"))
    | lines -> Alcotest.failf "expected three lines, got %d" (List.length lines))
;;

(* Drop reasons are the librarian's own account of what it forgot. They ride
   the journal line and nothing else stores them, so losing them in the
   projection loses them entirely. *)
let test_drop_reasons_survive_the_projection () =
  with_keepers_dir (fun keepers_dir ->
    let fact : Types.fact =
      Types.observed ~claim:"kept" ~category:Fact ~now:1_700_000_000.0
        ~origin:{ kind = Authored; trace_id = "" }
    in
    match
      Current.replace
        ~keepers_dir
        ~keeper_id:keeper
        ~dropped_statements:
          [ { memory_id = "sha256:" ^ String.make 64 'a'
            ; reason = "superseded by the openssl decision"
            }
          ]
        ~expected_revision:None
        ~now:1_700_000_000.0
        ~source:{ kind = Librarian; trace_id = "trace-a" }
        ~facts:[ fact ]
        ()
    with
    | Error reason -> Alcotest.failf "replace failed: %s" reason
    | Ok _ ->
      (match read_json ~keepers_dir with
       | [ line ] ->
         let dropped = U.to_list (field line "dropped") in
         Alcotest.(check int) "one drop statement" 1 (List.length dropped);
         (match dropped with
          | [ statement ] ->
            Alcotest.(check string) "the reason survives"
              "superseded by the openssl decision"
              (U.to_string (field statement "reason"))
          | _ -> Alcotest.fail "expected one statement")
       | lines -> Alcotest.failf "expected one line, got %d" (List.length lines)))
;;

(* A pass that started and was cancelled before it could commit used to leave
   nothing here, so the journal read the same for a pass killed mid-flight as
   for a turn on which the librarian never ran. Measured live on 2026-08-07:
   11 of 23 completed librarian lane runs cancelled, none of them in the
   journal. The operator asking why memory stopped advancing is exactly the
   reader that silence misleads. *)
let test_cancelled_pass_is_recorded_and_named () =
  with_keepers_dir (fun keepers_dir ->
    Current.append_librarian_failure
      ~keepers_dir
      ~keeper_id:keeper
      ~now:1_700_000_000.0
      ~trace_id:"trace-cancelled"
      ~kind:Lane_cancelled
      ~detail:"memory os librarian cancelled lane=librarian_exact before commit"
      ~snapshot_present:true
      ~cadence_deferred:false;
    match read_json ~keepers_dir with
    | [ line ] ->
      Alcotest.(check bool) "the pass is on the record" true (U.to_bool (field line "ok"));
      Alcotest.(check string) "recorded as a failed pass" "failed"
        (U.to_string (field line "outcome"));
      (* Naming it apart from the extraction failures is the point: an operator
         reading `exact_execution_failure` would go looking at the provider. *)
      Alcotest.(check string) "cancellation names itself" "lane_cancelled"
        (U.to_string (field line "kind"));
      Alcotest.(check bool) "and carries no revision" true
        (field line "revision" = `Null)
    | lines -> Alcotest.failf "expected one line, got %d" (List.length lines))
;;

(* The counterfactual this case rests on — that a keeper whose librarian never
   ran has an empty journal — is held by [test_missing_journal_reads_empty] in
   test_librarian_journal_failures.ml, and the wire round-trip for every kind
   is held by the [all_kinds] guard in that same file. What is only true here
   is the projected spelling the dashboard reads. *)

let () =
  Random.self_init ();
  Alcotest.run
    "keeper memory journal projection"
    [ ( "shape"
      , [ Alcotest.test_case "failure and commit project to different shapes" `Quick
            test_failure_and_commit_project_to_different_shapes
        ; Alcotest.test_case "failure carries its detail and deferral" `Quick
            test_failure_carries_its_detail_and_deferral
        ] )
    ; ( "honesty"
      , [ Alcotest.test_case "undecodable line keeps its position and reason" `Quick
            test_undecodable_line_keeps_its_position_and_reason
        ; Alcotest.test_case "cancelled pass is recorded and named" `Quick
            test_cancelled_pass_is_recorded_and_named
        ] )
    ; ( "content"
      , [ Alcotest.test_case "drop reasons survive the projection" `Quick
            test_drop_reasons_survive_the_projection
        ] )
    ]
;;

(* RFC-0517 §2.2: a store commit that rewrites a keeper's Memory moves the
   change counter by the memory IDs it added, absorbed, superseded and
   dropped, under the pass that called it, and sets the fact and byte gauges
   from the snapshot it wrote. A commit that keeps the stored snapshot moves
   nothing. *)

open Alcotest

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Program = Masc.Keeper_memory_os_program
module Unread = Masc.Keeper_librarian_unread
module Pass = Masc.Keeper_memory_commit_pass
module Metric_store = Masc.Otel_metric_store

let keeper_id = "keeper"

(* The [change] label values, in the order the checks list them. *)
let change_labels = [ "added"; "absorbed"; "superseded"; "dropped" ]

(* No commit writes a negative gauge, so this value shows that no commit set
   the gauge after the test did. *)
let unset_gauge = -1.0

let gauge_metrics = [ Keeper_metrics.MemoryFacts; Keeper_metrics.MemorySnapshotBytes ]

let with_temp_keepers f =
  let path = Filename.temp_file "memory-change-metrics-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let fact ?(last_seen = 100.0) claim : Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen
  ; origin = { kind = Types.Authored; trace_id = "trace" }
  ; basis = Types.Observed Types.Transcript
  }
;;

let id = Types.memory_id
let source kind = { Current.kind; trace_id = "trace" }

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
;;

let drop value reason = { Types.memory_id = id value; reason }
let absorb from into = { Types.absorbed = id from; into = id into }
let revision from into = { Types.superseded = id from; superseded_by = id into }

let changes ~pass =
  List.map
    (fun change ->
       Metric_store.metric_value_or_zero
         Keeper_metrics.(to_string MemoryChanges)
         ~labels:[ "keeper", keeper_id; "pass", pass; "change", change ]
         ())
    change_labels
;;

let moved ~before ~after = List.map2 (fun before after -> int_of_float (after -. before)) before after

let gauge metric =
  Metric_store.get_metric_value (Keeper_metrics.to_string metric) ~labels:[ "keeper", keeper_id ] ()
;;

let unset_gauges () =
  List.iter
    (fun metric ->
       Metric_store.set_gauge (Keeper_metrics.to_string metric) ~labels:[ "keeper", keeper_id ] unset_gauge)
    gauge_metrics
;;

(* Run one commit. It moves the four counters of [pass] by [expected] and
   sets both gauges from the snapshot it wrote, so it rewrote the snapshot. *)
let check_commit ~commit ~pass ~expected write =
  unset_gauges ();
  let before = changes ~pass in
  let (snapshot : Current.t) = write () in
  check (list int) (commit ^ " moves added, absorbed, superseded and dropped") expected
    (moved ~before ~after:(changes ~pass));
  check (option (float 0.0)) (commit ^ " sets the fact gauge to the facts it wrote")
    (Some (float_of_int (List.length snapshot.facts)))
    (gauge Keeper_metrics.MemoryFacts);
  check (option (float 0.0)) (commit ^ " sets the byte gauge to its rendered facts")
    (Some (float_of_int (String.length (Masc.Keeper_memory_os_render.render_facts snapshot.facts))))
    (gauge Keeper_metrics.MemorySnapshotBytes);
  snapshot
;;

(* One program stage: the exact facts it starts from and its decision. *)
let stage ~input ?(dropped = []) ?(absorbed = []) ?(revisions = []) new_claims =
  input, new_claims, dropped, absorbed, revisions
;;

(* Build an ordered program over [current], one message per stage, like the
   recall programs of test_keeper_memory_os_current, and commit it. *)
let publish_program ~keepers_dir ~transaction_id ~current ~apply stages =
  let anchor = Current.capture_program_anchor ~keepers_dir ~keeper_id |> require_ok in
  let program_keeper = Masc_test_deps.keeper_id_fixture keeper_id in
  let turn_ref = Ids.Turn_ref.make ~trace_id:transaction_id ~absolute_turn:3 in
  let messages =
    List.mapi
      (fun index _ ->
         Agent_core.Types.make_message ~role:Agent_core.Types.User
           [ Agent_core.Types.Text (Printf.sprintf "Ordered observation %d." index) ])
      stages
  in
  let sources =
    List.mapi
      (fun message_in_turn message ->
         Unread.Official_turn
           { turn_ref; boundary_line = 1; message_in_turn; message_sha256 = Unread.message_digest message })
      messages
  in
  let decisions =
    List.mapi
      (fun index (input, new_claims, dropped, absorbed, revisions) : Program.decision ->
         { run_id = Printf.sprintf "%s-%d" transaction_id index
         ; keeper_id = program_keeper
         ; turn_ref
         ; input_current = Some input
         ; sources = [ List.nth sources index ]
         ; input_evidence = `Null
         ; gate_evidence = `Null
         ; working_state = "Accepted ordered continuation."
         ; new_claims
         ; dropped
         ; absorbed
         ; revisions
         })
      stages
  in
  let program =
    Program.create ~transaction_id ~keeper_id:program_keeper ~turn_ref ~sources ~unread:[]
      ~initial_current:(Some current) ~decisions
    |> require_ok
  in
  let range : Current.official_range_id =
    { receipt_scope = transaction_id; after_boundary_line = 0; turns = [ 1, turn_ref ]; unread_messages = [] }
  in
  apply ~anchor ~source:(Current.Official_program_source { range; selected_turns = [ 1, turn_ref, messages ] })
    program
;;

let claims (snapshot : Current.t) =
  List.sort String.compare (List.map (fun (value : Types.fact) -> value.claim) snapshot.facts)
;;

let test_a_commit_counts_its_changes_under_its_pass () =
  with_temp_keepers
  @@ fun keepers_dir ->
  let absorbed_source = fact "absorbed source"
  and revised = fact "revised claim"
  and retired = fact "retired claim"
  and kept = fact "kept claim"
  and spare = fact "spare claim" in
  Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:200.0 ~source:(source Current.Librarian)
    ~facts:[ absorbed_source; revised; retired; kept; spare ] ()
  |> require_ok
  |> ignore;
  (* A Keeper re-observes a held fact: the same ID with a later [last_seen]. *)
  ignore
    (check_commit ~commit:"a re-observation" ~pass:"keeper_write" ~expected:[ 0; 0; 0; 0 ]
     @@ fun () ->
     Current.upsert_fact ~pass:Pass.Keeper_write ~keepers_dir ~keeper_id ~now:250.0
       ~source:(source Current.Explicit_write) (fact ~last_seen:250.0 kept.claim)
     |> Result.map_error Current.upsert_error_to_string
     |> require_ok);
  (* One Librarian disposition: an absorption, a revision, a plain drop and
     two new claims. *)
  let merged = fact "merged claim"
  and successor = fact "successor claim" in
  let disposed =
    check_commit ~commit:"a disposition" ~pass:"durable" ~expected:[ 2; 1; 1; 1 ]
    @@ fun () ->
    (Current.apply_disposition ~pass:Pass.Durable
       ~dropped_statements:[ drop revised "the successor restates it"; drop retired "no longer true" ]
       ~absorbed:[ absorb absorbed_source merged ]
       ~revisions:[ revision revised successor ]
       ~keepers_dir ~keeper_id ~now:260.0 ~source:(source Current.Librarian) ~new_claims:[ merged; successor ] ()
     |> require_ok)
      .snapshot
  in
  (* A program of three stages, counted once from its first facts to its
     last by following each chain. Stage 0 absorbs [successor] into
     [combined] and [spare] into [folded], revises [merged] into [refined] and
     adds [staged]. Stage 1 revises [refined] into [polished], [folded] into
     [pressed], [staged] into [restated] and [kept] into [clarified]. Stage 2
     drops [pressed]. So [successor] was absorbed, [merged] (through
     [refined]) and [kept] were superseded, [spare] ended in a dropped claim,
     and [staged] never reached a committed snapshot. *)
  let refined = fact "refined claim"
  and polished = fact "polished claim"
  and combined = fact "combined claim"
  and folded = fact "folded claim"
  and pressed = fact "pressed claim"
  and staged = fact "staged claim"
  and restated = fact "restated claim"
  and clarified = fact "clarified claim" in
  let held = List.filter (fun (value : Types.fact) -> String.equal (id value) (id kept)) disposed.facts in
  let replaced = "a later claim replaces it" in
  let published =
    check_commit ~commit:"a three-stage program" ~pass:"continuity" ~expected:[ 4; 1; 2; 1 ]
    @@ fun () ->
    (publish_program ~keepers_dir ~transaction_id:"change-metrics-program" ~current:disposed.facts
       ~apply:(fun ~anchor ~source program ->
         Current.apply_program ~pass:Pass.Continuity ~keepers_dir ~keeper_id ~now:300.0 ~anchor ~source
           ~validate_source:(fun () -> Ok ()) program)
       [ stage ~input:disposed.facts ~dropped:[ drop merged replaced ]
           ~absorbed:[ absorb successor combined; absorb spare folded ] ~revisions:[ revision merged refined ]
           [ refined; combined; folded; staged ]
       ; stage ~input:(held @ [ refined; combined; folded; staged ])
           ~dropped:[ drop refined replaced; drop folded replaced; drop staged replaced; drop kept replaced ]
           ~revisions:
             [ revision refined polished; revision folded pressed; revision staged restated; revision kept clarified ]
           [ polished; pressed; restated; clarified ]
       ; stage ~input:[ combined; polished; pressed; restated; clarified ]
           ~dropped:[ drop pressed "no longer true" ] []
       ]
     |> require_ok)
      .snapshot
  in
  check (list string) "the program leaves only the claims its last stage kept"
    (List.sort String.compare [ combined.claim; polished.claim; restated.claim; clarified.claim ])
    (claims published);
  (* The rename of this program's snapshot returns, but the directory sync
     fails. The commit returns an error, yet its snapshot is the store's state
     and the next reader finalizes it, so it is counted. *)
  ignore
    (check_commit ~commit:"a program renamed but not synced" ~pass:"durable" ~expected:[ 1; 0; 0; 0 ]
     @@ fun () ->
     (match
        publish_program ~keepers_dir ~transaction_id:"change-metrics-unsynced" ~current:published.facts
          ~apply:(fun ~anchor ~source program ->
            Current.For_testing.apply_program_with_publication_io ~pass:Pass.Durable ~keepers_dir ~keeper_id
              ~now:305.0 ~anchor ~source ~validate_source:(fun () -> Ok ())
              ~write_snapshot:
                (Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged ~sync_file:ignore
                   ~sync_parent:(fun _ -> failwith "directory sync failed"))
              ~sync_snapshot:(fun _ -> Error "directory sync failed")
              ~before_journal:ignore ~on_committed:ignore program)
          [ stage ~input:published.facts [ fact "unsynced claim" ] ]
      with
      | Ok _ -> fail "a snapshot whose directory sync failed reports no commit"
      | Error _ -> ());
     match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
     | Ok (Some snapshot) -> snapshot
     | Ok None | Error _ -> fail "the renamed snapshot is readable");
  (* A Keeper replaces one fact with another and retracts a second. *)
  ignore
    (check_commit ~commit:"a supersession" ~pass:"keeper_write" ~expected:[ 1; 0; 1; 0 ]
     @@ fun () ->
     match
       Current.supersede_fact ~pass:Pass.Keeper_write ~keepers_dir ~keeper_id ~now:310.0
         ~source:(source Current.Explicit_write) ~superseded_memory_id:(id combined) (fact "replacement claim")
     with
     | Ok (snapshot, _) -> snapshot
     | Error _ -> fail "the supersession failed");
  ignore
    (check_commit ~commit:"a retraction" ~pass:"keeper_delete" ~expected:[ 0; 0; 0; 1 ]
     @@ fun () ->
     match
       Current.retract_fact ~pass:Pass.Keeper_delete ~keepers_dir ~keeper_id ~now:320.0
         ~source:(source Current.Explicit_retract) ~memory_id:(id clarified) ~reason:"the Keeper withdrew it" ()
     with
     | Ok snapshot -> snapshot
     | Error _ -> fail "the retraction failed");
  (* Restating a held fact keeps the stored snapshot. *)
  unset_gauges ();
  let before = changes ~pass:"durable" in
  let restatement =
    Current.apply_disposition ~pass:Pass.Durable ~absorbed:[] ~revisions:[] ~keepers_dir ~keeper_id ~now:400.0
      ~source:(source Current.Librarian) ~new_claims:[ restated ] ()
    |> require_ok
  in
  check bool "the restatement keeps the snapshot" true (restatement.commit = Current.Unchanged);
  check (list int) "an unchanged commit moves no change" [ 0; 0; 0; 0 ]
    (moved ~before ~after:(changes ~pass:"durable"));
  List.iter
    (fun metric ->
       check (option (float 0.0)) "an unchanged commit sets no gauge" (Some unset_gauge) (gauge metric))
    gauge_metrics
;;

let () =
  run "keeper_memory_change_metrics"
    [ ( "store commit"
      , [ test_case "a commit counts its changes under its pass" `Quick
            test_a_commit_counts_its_changes_under_its_pass
        ] )
    ]
;;

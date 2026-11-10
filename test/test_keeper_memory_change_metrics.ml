(* RFC-0517 §2.2: a store commit that rewrites a keeper's Memory moves the
   change counter by the memory IDs it added, absorbed, superseded and
   dropped, under the pass that called it, and sets the fact and byte gauges
   from the snapshot it wrote. A commit that keeps the stored snapshot moves
   nothing. *)

open Alcotest

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
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

let source kind = { Current.kind; trace_id = "trace" }

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
;;

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
  Metric_store.get_metric_value
    (Keeper_metrics.to_string metric)
    ~labels:[ "keeper", keeper_id ]
    ()
;;

let unset_gauges () =
  List.iter
    (fun metric ->
       Metric_store.set_gauge
         (Keeper_metrics.to_string metric)
         ~labels:[ "keeper", keeper_id ]
         unset_gauge)
    gauge_metrics
;;

let check_gauges ~commit (snapshot : Current.t) =
  check
    (option (float 0.0))
    (commit ^ " sets the fact gauge to the facts it wrote")
    (Some (float_of_int (List.length snapshot.facts)))
    (gauge Keeper_metrics.MemoryFacts);
  check
    (option (float 0.0))
    (commit ^ " sets the byte gauge to its rendered facts")
    (Some
       (float_of_int
          (String.length (Masc.Keeper_memory_os_render.render_facts snapshot.facts))))
    (gauge Keeper_metrics.MemorySnapshotBytes)
;;

let test_a_commit_counts_its_changes_under_its_pass () =
  with_temp_keepers
  @@ fun keepers_dir ->
  let absorbed_source = fact "absorbed source"
  and revised = fact "revised claim"
  and retired = fact "retired claim"
  and kept = fact "kept claim" in
  let seeded =
    Current.replace
      ~keepers_dir
      ~keeper_id
      ~expected_revision:None
      ~now:200.0
      ~source:(source Current.Librarian)
      ~facts:[ absorbed_source; revised; retired; kept ]
      ()
    |> require_ok
  in
  (* A Keeper re-observes a held fact: the same ID with a later [last_seen]. *)
  unset_gauges ();
  let before = changes ~pass:"keeper_write" in
  let reobserved =
    Current.upsert_fact
      ~pass:Pass.Keeper_write
      ~keepers_dir
      ~keeper_id
      ~now:250.0
      ~source:(source Current.Explicit_write)
      (fact ~last_seen:250.0 kept.claim)
    |> Result.map_error Current.upsert_error_to_string
    |> require_ok
  in
  check int "the re-observation rewrites the snapshot" (seeded.revision + 1) reobserved.revision;
  check
    (list int)
    "a payload change under the same ID counts nowhere"
    [ 0; 0; 0; 0 ]
    (moved ~before ~after:(changes ~pass:"keeper_write"));
  check_gauges ~commit:"the re-observation" reobserved;
  (* One Librarian disposition: an absorption, a revision, a plain drop and
     two new claims. *)
  let merged = fact "merged claim"
  and successor = fact "successor claim" in
  let id = Types.memory_id in
  unset_gauges ();
  let before = changes ~pass:"durable" in
  let committed =
    Current.apply_disposition
      ~pass:Pass.Durable
      ~dropped_statements:
        [ { Types.memory_id = id revised; reason = "the successor restates it" }
        ; { Types.memory_id = id retired; reason = "no longer true" }
        ]
      ~absorbed:[ { Types.absorbed = id absorbed_source; into = id merged } ]
      ~revisions:[ { Types.superseded = id revised; superseded_by = id successor } ]
      ~keepers_dir
      ~keeper_id
      ~now:300.0
      ~source:(source Current.Librarian)
      ~new_claims:[ merged; successor ]
      ()
    |> require_ok
  in
  check bool "the disposition rewrites the snapshot" true (committed.commit = Current.Rewritten);
  check
    (list string)
    "the disposition keeps one fact and adds two"
    [ kept.claim; merged.claim; successor.claim ]
    (List.map (fun (value : Types.fact) -> value.claim) committed.snapshot.facts);
  check
    (list int)
    "added, absorbed, superseded and dropped move by the IDs of the commit"
    [ 2; 1; 1; 1 ]
    (moved ~before ~after:(changes ~pass:"durable"));
  check_gauges ~commit:"the disposition" committed.snapshot;
  (* Restating a held fact keeps the stored snapshot. *)
  unset_gauges ();
  let before = changes ~pass:"durable" in
  let restated =
    Current.apply_disposition
      ~pass:Pass.Durable
      ~absorbed:[]
      ~revisions:[]
      ~keepers_dir
      ~keeper_id
      ~now:400.0
      ~source:(source Current.Librarian)
      ~new_claims:[ merged ]
      ()
    |> require_ok
  in
  check bool "the restatement keeps the snapshot" true (restated.commit = Current.Unchanged);
  check
    (list int)
    "an unchanged commit moves no change"
    [ 0; 0; 0; 0 ]
    (moved ~before ~after:(changes ~pass:"durable"));
  List.iter
    (fun metric ->
       check
         (option (float 0.0))
         "an unchanged commit sets no gauge"
         (Some unset_gauge)
         (gauge metric))
    gauge_metrics
;;

let () =
  run
    "keeper_memory_change_metrics"
    [ ( "store commit"
      , [ test_case
            "a commit counts its changes under its pass"
            `Quick
            test_a_commit_counts_its_changes_under_its_pass
        ] )
    ]
;;

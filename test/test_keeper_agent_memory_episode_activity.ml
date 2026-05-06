(** Tests for keeper memory episode activity visibility. *)

open Alcotest
open Masc_mcp

module Episode = Keeper_agent_memory_episode
module Hooks = Coord_hooks
module P = Prometheus

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_memory_activity_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter
          (fun name -> rm (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let make_config ~base_path : Coord_utils.config =
  let backend_config : Backend_types.config = {
    backend_type = Backend_types.Memory;
    base_path;
    node_id = "test-node";
    cluster_name = "default";
    pubsub_max_messages = 1000;
  } in
  let memory_backend = Backend.Memory.create () in
  {
    Coord_utils.base_path;
    workspace_path = base_path;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Coord_utils.Memory memory_backend;
  }

let with_config f =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () -> f (make_config ~base_path))

let with_activity_emit fn f =
  let previous = Atomic.get Hooks.activity_emit_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set Hooks.activity_emit_fn previous)
    (fun () ->
      Atomic.set Hooks.activity_emit_fn fn;
      f ())

let read_failure ~keeper ~outcome =
  P.metric_value_or_zero
    P.metric_keeper_memory_activity_emit_failures
    ~labels:[("keeper", keeper); ("outcome", outcome)]
    ()

let failing_emit _config ~actor:_ ?subject ~kind:_ ~payload:_ ~tags:_ () =
  ignore subject;
  failwith "activity graph down"

let test_activity_emit_failure_increments_success_metric () =
  with_config (fun config ->
    let keeper = "keeper-memory-activity-success" in
    let before = read_failure ~keeper ~outcome:"success" in
    with_activity_emit failing_emit (fun () ->
      Episode.emit_flush_activity ~config ~keeper_name:keeper ~turn:7
        ~episodes:1 ~procedures:0 ~tags:["memory"; "episode"; "flush"]
        ();
      let after = read_failure ~keeper ~outcome:"success" in
      check (float 0.0001)
        "activity emit failure increments success-outcome metric"
        (before +. 1.0) after))

let test_activity_emit_failure_increments_failure_metric () =
  with_config (fun config ->
    let keeper = "keeper-memory-activity-failure" in
    let before = read_failure ~keeper ~outcome:"failure" in
    with_activity_emit failing_emit (fun () ->
      Episode.emit_flush_activity ~config ~keeper_name:keeper ~turn:8
        ~episodes:0 ~procedures:1 ~outcome:"failure"
        ~tags:["memory"; "episode"; "flush"; "failure"]
        ();
      let after = read_failure ~keeper ~outcome:"failure" in
      check (float 0.0001)
        "activity emit failure preserves failure outcome label"
        (before +. 1.0) after))

let test_zero_flush_is_noop () =
  with_config (fun config ->
    let called = ref false in
    let counting_emit _config ~actor:_ ?subject ~kind:_ ~payload:_ ~tags:_ () =
      ignore subject;
      called := true
    in
    with_activity_emit counting_emit (fun () ->
      Episode.emit_flush_activity ~config
        ~keeper_name:"keeper-memory-activity-noop" ~turn:9
        ~episodes:0 ~procedures:0 ~tags:["memory"]
        ();
      check bool "zero flush does not call activity emit" false !called))

let () =
  run "keeper_agent_memory_episode_activity" [
    "activity emit visibility", [
      test_case "success flush emit failure increments metric" `Quick
        test_activity_emit_failure_increments_success_metric;
      test_case "failure flush emit failure increments metric" `Quick
        test_activity_emit_failure_increments_failure_metric;
      test_case "zero flush remains a no-op" `Quick test_zero_flush_is_noop;
    ];
  ]

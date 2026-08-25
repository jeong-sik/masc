(** Tests for the write-only tool metrics JSONL stream. *)

module P = Masc.Tool_metrics_persist
module R = Tool_result

let make_result ~name ~success ~duration_ms : R.result =
  if success
  then R.Completed { R.tool_name = name; data = `Null; metadata = None; duration_ms }
  else
    R.Failed
      { R.class_ = Runtime_failure
      ; message = ""
      ; data = `Null
      ; metadata = None
      ; tool_name = name
      ; duration_ms
      }

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let with_tmp_dir f =
  let dir = Filename.temp_dir "test-tool-metrics-persist-" "" in
  P.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      P.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let read_records ~base_path =
  let dir = Filename.concat base_path "data/tool-metrics" in
  if not (Sys.file_exists dir)
  then []
  else (
    let records = ref [] in
    let store = Dated_jsonl.create ~base_dir:dir () in
    Dated_jsonl.iter_all store (fun json -> records := json :: !records);
    List.rev !records)

let string_field key json =
  match Safe_ops.json_string_opt key json with
  | Some value -> value
  | None -> Alcotest.failf "missing string field %s" key

let test_enqueue_flush_current_records () =
  with_tmp_dir (fun base_path ->
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue (make_result ~name:"alpha" ~success:false ~duration_ms:5.0);
    P.enqueue
      (R.Deferred
         { R.tool_name = "alpha"
         ; data = `Null
         ; metadata = None
         ; duration_ms = 3.0
         });
    P.enqueue (make_result ~name:"beta" ~success:true ~duration_ms:20.0);
    P.flush_now ~base_path;
    let records = read_records ~base_path in
    Alcotest.(check int) "four records written" 4 (List.length records);
    Alcotest.(check (list string))
      "current dispositions only"
      [ "completed"; "failed"; "deferred"; "completed" ]
      (List.map (string_field "disposition") records);
    Alcotest.(check bool)
      "removed success-bit format is not emitted"
      true
      (List.for_all
         (fun json -> Safe_ops.json_bool_opt "success" json = None)
         records))

let test_reset_discards_queued_records () =
  with_tmp_dir (fun base_path ->
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:1.0);
    P.reset_for_testing ();
    P.flush_now ~base_path;
    Alcotest.(check int)
      "reset leaves no persisted rows"
      0
      (List.length (read_records ~base_path)))

let test_enqueue_drops_when_queue_full () =
  with_tmp_dir (fun base_path ->
    for i = 1 to 4101 do
      P.enqueue
        (make_result
           ~name:(Printf.sprintf "tool-%04d" i)
           ~success:true
           ~duration_ms:1.0)
    done;
    P.flush_now ~base_path;
    Alcotest.(check int)
      "bounded queue persists only capacity"
      4096
      (List.length (read_records ~base_path)))

let test_enqueue_multidomain_drop_is_bounded () =
  with_tmp_dir (fun base_path ->
    let spawn producer =
      Domain.spawn (fun () ->
        for i = 1 to 1500 do
          P.enqueue
            (make_result
               ~name:(Printf.sprintf "domain-%d-tool-%04d" producer i)
               ~success:true
               ~duration_ms:1.0)
        done)
    in
    let domains = List.init 4 spawn in
    List.iter Domain.join domains;
    P.flush_now ~base_path;
    Alcotest.(check int)
      "multi-domain producers persist only capacity"
      4096
      (List.length (read_records ~base_path)))

let () =
  Alcotest.run
    "Tool_metrics_persist"
    [ ( "persistence"
      , [ eio_test "enqueue and flush current rows" test_enqueue_flush_current_records
        ; eio_test "reset discards queued records" test_reset_discards_queued_records
        ; eio_test
            "enqueue drops instead of blocking when queue is full"
            test_enqueue_drops_when_queue_full
        ; eio_test
            "enqueue drops safely from multiple domains"
            test_enqueue_multidomain_drop_is_bounded
        ] )
    ]

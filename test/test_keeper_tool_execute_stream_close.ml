open Alcotest

module EO = Dashboard_execute_output
module Runtime = Masc.Keeper_tool_execute_runtime

let take_json env subscriber =
  Eio.Time.with_timeout_exn
    (Eio.Stdenv.clock env)
    1.0
    (fun () -> EO.take_event subscriber |> EO.stream_event_json)

let test_rejected_dispatch_closes_stream name kind =
  EO.reset_for_testing ();
  Eio_main.run @@ fun env ->
  match EO.subscribe ~keeper_name:"sangsu" with
  | None -> fail (name ^ ": expected subscriber")
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () ->
        EO.record_stream_start
          ~keeper_name:"sangsu"
          ~task_id:(Some "task-rejected");
        let opened = take_json env subscriber in
        check string
          (name ^ " emits task_opened")
          "task_opened"
          Yojson.Safe.Util.(opened |> member "type" |> to_string);
        Runtime.For_testing.close_rejected_execute_stream
          ~keeper_name:"sangsu"
          ~task_id:(Some "task-rejected")
          ~kind
          ~detail:"test rejection";
        let closed = take_json env subscriber in
        let open Yojson.Safe.Util in
        check string
          (name ^ " emits task_closed")
          "task_closed"
          (closed |> member "type" |> to_string);
        check bool
          (name ^ " marks stream closed")
          true
          (closed |> member "closed" |> to_bool);
        check string
          (name ^ " preserves task id")
          "task-rejected"
          (closed |> member "task_id" |> to_string);
        check int
          (name ^ " closes with failure status")
          1
          (closed |> member "status" |> member "code" |> to_int);
        check string
          (name ^ " records rejection kind")
          name
          (closed |> member "status" |> member "error" |> to_string);
        EO.append_stream_chunk
          ~keeper_name:"sangsu"
          ~stream:`Stdout
          "after rejection\n";
        let line = take_json env subscriber in
        check string
          (name ^ " emits later line")
          "line"
          (line |> member "type" |> to_string);
        check bool
          (name ^ " removes open stream binding")
          true
          (line |> member "task_id" = `Null))

let () =
  run
    "Keeper_tool_execute_stream_close"
    [ ( "rejected_dispatch"
      , [ test_case
            "Gate_reject"
            `Quick
            (fun () ->
              test_rejected_dispatch_closes_stream "gate_reject" `Gate_reject)
        ; test_case
            "Cannot_parse"
            `Quick
            (fun () ->
              test_rejected_dispatch_closes_stream "cannot_parse" `Cannot_parse)
        ; test_case
            "Too_complex"
            `Quick
            (fun () ->
              test_rejected_dispatch_closes_stream "too_complex" `Too_complex)
        ; test_case
            "Path_reject"
            `Quick
            (fun () ->
              test_rejected_dispatch_closes_stream "path_reject" `Path_reject)
        ] )
    ]

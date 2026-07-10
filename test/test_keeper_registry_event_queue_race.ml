let temp_dir () = Filename.temp_dir "keeper-registry-event-queue-race" ""

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let meta_for_keeper keeper_name trace_id =
  match
    Masc.Keeper_meta_json_parse.meta_of_json
      (`Assoc
        [ "name", `String keeper_name
        ; "agent_name", `String keeper_name
        ; "trace_id", `String trace_id
        ; "last_model_used", `String "llama:auto"
        ; "tool_access", `List []
        ])
  with
  | Ok meta -> meta
  | Error msg -> Alcotest.fail ("meta parse failed: " ^ msg)
;;

let hitl_stimulus keeper_name =
  let resolution =
    Keeper_event_queue.
      { approval_id = "approval-register-race"
      ; decision =
          Hitl_approved
            { keeper_name
            ; tool_name = "keeper_continue_after_reconcile"
            ; input_hash = String.make 64 'a'
            }
      ; channel = Keeper_continuation_channel.unrouted "registry race test"
      }
  in
  Keeper_event_queue.
    { post_id = hitl_resolution_post_id resolution
    ; urgency = Immediate
    ; arrived_at = Unix.gettimeofday ()
    ; payload = Hitl_resolved resolution
    }
;;

let test_publish_to_replacement_registry_entry () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry_event_queue.For_testing.set_before_durable_live_publication_hook
        None;
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
       let keeper_name = "keeper-registry-event-queue-race-test" in
       let first =
         Masc.Keeper_registry.register
           ~base_path
           keeper_name
           (meta_for_keeper keeper_name "trace-register-race-first")
       in
       let replacement =
         Masc.Keeper_registry.register
           ~base_path
           keeper_name
           (meta_for_keeper keeper_name "trace-register-race-replacement")
       in
       Masc.Keeper_registry.For_testing.unsafe_put_entry
         ~base_path
         keeper_name
         first;
       Masc.Keeper_registry_event_queue.For_testing.set_before_durable_live_publication_hook
         (Some (fun () ->
            Masc.Keeper_registry.For_testing.unsafe_put_entry
              ~base_path
              keeper_name
              replacement));
       (match
          Masc.Keeper_registry_event_queue.enqueue_durable_result
            ~base_path
            keeper_name
            (hitl_stimulus keeper_name)
        with
        | Ok () -> ()
        | Error msg -> Alcotest.fail ("durable enqueue failed: " ^ msg));
       let current =
         match Masc.Keeper_registry.get ~base_path keeper_name with
         | Some entry -> entry
         | None -> Alcotest.fail "replacement registry entry disappeared"
       in
       Alcotest.(check bool) "replacement remains current" true (current == replacement);
       Alcotest.(check int)
         "committed stimulus is published to current entry"
         1
         (Keeper_event_queue.length (Atomic.get current.event_queue)))
;;

let () =
  Alcotest.run
    "keeper_registry_event_queue_race"
    [ ( "durable publication"
      , [ Alcotest.test_case
            "registry replacement receives committed stimulus"
            `Quick
            test_publish_to_replacement_registry_entry
        ] )
    ]
;;

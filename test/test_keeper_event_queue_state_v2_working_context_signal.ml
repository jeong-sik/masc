module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Registry_event_queue = Masc.Keeper_registry_event_queue

(* Prompts moved from code into config/prompts; load them so keeper world event
   rows render a non-empty title and preview. Matches the other
   prompt-rendering tests. *)
let () =
  let prompt_dir =
    Filename.concat
      (match Sys.getenv_opt "DUNE_SOURCEROOT" with
       | Some root -> root
       | None -> Sys.getcwd ())
      "config/prompts"
  in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let stimulus post_id arrived_at : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at; payload = Queue.Bootstrap }
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)
;;

let with_state_change_observer observer f =
  Persistence.install_state_change_observer (fun ~base_path:_ ~keeper_name:_ -> observer ());
  Fun.protect
    ~finally:(fun () -> Persistence.install_state_change_observer (fun ~base_path:_ ~keeper_name:_ -> ()))
    f
;;

(* A snapshot write is a rename, so a rewrite of even the same bytes is a new
   inode with a new ctime. *)
let same_file_identity (before : Unix.stats) (after : Unix.stats) =
  before.st_dev = after.st_dev
  && before.st_ino = after.st_ino
  && Float.equal before.st_ctime after.st_ctime
;;

let test_durable_enqueue_replays_write_and_signal_nothing () =
  with_temp_dir "keeper-durable-enqueue-replay" (fun base_path ->
    let keeper_name = "durable-replay" in
    let source = stimulus "durable-replay-source" 1.0 in
    let writes = ref 0 in
    let signals = ref 0 in
    let enqueue () =
      Registry_event_queue.enqueue_stimulus_once_durable_result ~base_path keeper_name source
    in
    Masc.Keeper_working_context_signal.install (fun ~base_path:_ ~keeper_name:_ -> incr signals);
    Fun.protect
      ~finally:(fun () ->
        Masc.Keeper_working_context_signal.install (fun ~base_path:_ ~keeper_name:_ -> ()))
      (fun () ->
        with_state_change_observer (fun () -> incr writes) (fun () ->
          (match enqueue () with
           | Registry_event_queue.Stimulus_enqueued -> ()
           | Registry_event_queue.Stimulus_already_present ->
             Alcotest.fail "first delivery was already present"
           | Registry_event_queue.Stimulus_shutdown_reserved operation_id ->
             Alcotest.fail (Registry_event_queue.shutdown_reserved_detail operation_id)
           | Registry_event_queue.Stimulus_storage_error detail -> Alcotest.fail detail);
          Alcotest.(check (pair int int)) "first delivery writes and signals once" (1, 1)
            (!writes, !signals);
          let primary = Filename.concat
            (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
            Persistence.snapshot_filename in
          let delivered = Unix.lstat primary in
          List.iter (fun replay ->
            match enqueue () with
            | Registry_event_queue.Stimulus_already_present -> ()
            | Registry_event_queue.Stimulus_enqueued ->
              Alcotest.failf "replay %d enqueued the source again" replay
            | Registry_event_queue.Stimulus_shutdown_reserved operation_id ->
              Alcotest.fail (Registry_event_queue.shutdown_reserved_detail operation_id)
            | Registry_event_queue.Stimulus_storage_error detail -> Alcotest.fail detail)
            [ 1; 2; 3 ];
          Alcotest.(check (pair int int)) "replays write and signal nothing" (1, 1)
            (!writes, !signals);
          Alcotest.(check bool) "replays leave the snapshot in place" true
            (same_file_identity delivered (Unix.lstat primary));
          Alcotest.(check int) "one source stays pending" 1
            (List.length
               (Queue.to_list
                  (State.pending
                     (Persistence.load_state_result ~base_path ~keeper_name
                      |> require_ok "read")))))))

let () =
  Alcotest.run
    "keeper_event_queue_state_v2_working_context_signal"
    [ ( "one-shot durability"
      , [ Alcotest.test_case "durable enqueue replays write and signal nothing" `Quick
            test_durable_enqueue_replays_write_and_signal_nothing
        ] )
    ]
;;

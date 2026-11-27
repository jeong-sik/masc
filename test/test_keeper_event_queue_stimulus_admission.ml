(* Admission under the owner lock and the ACK decided under it (RFC
   ask-answer-is-queued-before-it-is-recorded, D1 and D2). *)

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Registry_event_queue = Masc.Keeper_registry_event_queue

let keeper_name = "admission-keeper"

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let stimulus post_id : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at = 1.; payload = Queue.Bootstrap }
;;

let source = stimulus "admitted-source"

let with_temp_dir f =
  let path = Filename.temp_file "keeper-stimulus-admission" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)
;;

let load ~base_path = Persistence.load_state_result ~base_path ~keeper_name |> require_ok "load"

let pending_post_ids ~base_path =
  Queue.to_list (State.pending (load ~base_path))
  |> List.map (fun (item : Queue.stimulus) -> item.post_id)
;;

let selection_of ~base_path post_id =
  match
    List.find_opt
      (fun (selection : State.pending_selection) -> String.equal selection.source.post_id post_id)
      (State.pending_selections (load ~base_path))
  with
  | Some selection -> selection
  | None -> Alcotest.failf "no pending selection for %s" post_id
;;

let admission_label = function
  | Ok Persistence.Enqueued -> "enqueued"
  | Ok Persistence.Already_present -> "already present"
  | Error _ -> "error"
;;

let snapshot_bytes ~base_path =
  let path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      Persistence.snapshot_filename
  in
  In_channel.with_open_bin path In_channel.input_all
;;

let contains ~sub text =
  let sub_len = String.length sub in
  let rec scan index =
    index + sub_len <= String.length text
    && (String.equal (String.sub text index sub_len) sub || scan (index + 1))
  in
  scan 0
;;

(* What [f] does after [admit] already finds the pointer in the snapshot file,
   and [f]'s value comes back. The owner lock is not reentrant, so the check
   reads the file instead of loading the state. *)
let test_admission_is_durable_before_the_callers_next_write () =
  with_temp_dir (fun base_path ->
    let on_disk =
      Persistence.with_stimulus_admission ~base_path ~keeper_name (fun admit ->
        Alcotest.(check string) "first admission" "enqueued" (admission_label (admit source));
        contains ~sub:("\"" ^ source.post_id ^ "\"") (snapshot_bytes ~base_path))
      |> require_ok "admission"
    in
    Alcotest.(check bool) "pointer in the snapshot file inside the lock" true on_disk;
    Alcotest.(check (list string)) "pointer pending" [ source.post_id ]
      (pending_post_ids ~base_path))
;;

let test_a_repeated_admission_is_already_present () =
  with_temp_dir (fun base_path ->
    let first, second =
      Persistence.with_stimulus_admission ~base_path ~keeper_name (fun admit ->
        let first = admission_label (admit source) in
        first, admission_label (admit source))
      |> require_ok "admission"
    in
    let later =
      Persistence.with_stimulus_admission ~base_path ~keeper_name (fun admit ->
        admission_label (admit source))
      |> require_ok "later admission"
    in
    Alcotest.(check (list string)) "outcomes" [ "enqueued"; "already present"; "already present" ]
      [ first; second; later ];
    Alcotest.(check (list string)) "one pointer" [ source.post_id ] (pending_post_ids ~base_path))
;;

let test_admit_after_the_lock_is_released_writes_nothing () =
  with_temp_dir (fun base_path ->
    let escaped = ref None in
    Persistence.with_stimulus_admission ~base_path ~keeper_name (fun admit -> escaped := Some admit)
    |> require_ok "admission";
    let admit = Option.get !escaped in
    Alcotest.(check string) "late admission refused" "error" (admission_label (admit source));
    Alcotest.(check (list string)) "nothing pending" [] (pending_post_ids ~base_path))
;;

(* An ACK from another fiber waits for the admission's lock, so it cannot land
   between the pointer and the caller's record. *)
let test_another_transaction_waits_for_the_callers_work () =
  with_temp_dir (fun base_path ->
    Persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name (stimulus "earlier")
    |> require_ok "seed"
    |> ignore;
    let selection = selection_of ~base_path "earlier" in
    let acked = ref false in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let acked_inside_lock =
          Persistence.with_stimulus_admission ~base_path ~keeper_name (fun admit ->
            ignore (admit source);
            Eio.Fiber.fork ~sw (fun () ->
              Persistence.ack_pending_result ~base_path ~keeper_name ~selection ()
              |> require_ok "ack";
              acked := true);
            for _ = 1 to 20 do
              Eio.Fiber.yield ()
            done;
            !acked)
          |> require_ok "admission"
        in
        Alcotest.(check bool) "ACK did not run inside the admission" false acked_inside_lock));
    Alcotest.(check bool) "ACK ran after the lock was released" true !acked;
    Alcotest.(check (list string)) "only the admitted pointer remains" [ source.post_id ]
      (pending_post_ids ~base_path))
;;

let guarded_label = function
  | Ok Persistence.Ack_committed -> "committed"
  | Ok (Persistence.Ack_withheld kept) -> "withheld " ^ kept
  | Error detail -> "error " ^ detail
;;

let seeded_selection ~base_path =
  Persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name source
  |> require_ok "seed"
  |> ignore;
  selection_of ~base_path source.post_id
;;

let test_withheld_ack_writes_nothing () =
  with_temp_dir (fun base_path ->
    let selection = seeded_selection ~base_path in
    let revision = State.revision (load ~base_path) in
    Alcotest.(check string) "outcome" "withheld answered"
      (guarded_label
         (Persistence.ack_pending_unless_result ~base_path ~keeper_name ~selection
            ~withhold:(fun () -> Ok (Some "answered")) ()));
    Alcotest.(check (list string)) "source stays pending" [ source.post_id ]
      (pending_post_ids ~base_path);
    Alcotest.(check int64) "no revision" revision (State.revision (load ~base_path)))
;;

let test_unwithheld_ack_commits () =
  with_temp_dir (fun base_path ->
    let selection = seeded_selection ~base_path in
    Alcotest.(check string) "outcome" "committed"
      (guarded_label
         (Persistence.ack_pending_unless_result ~base_path ~keeper_name ~selection
            ~withhold:(fun () -> Ok None) ()));
    Alcotest.(check (list string)) "source acknowledged" [] (pending_post_ids ~base_path))
;;

let test_withhold_error_writes_nothing () =
  with_temp_dir (fun base_path ->
    let selection = seeded_selection ~base_path in
    Alcotest.(check string) "outcome" "error ask log unreadable"
      (guarded_label
         (Persistence.ack_pending_unless_result ~base_path ~keeper_name ~selection
            ~withhold:(fun () -> Error "ask log unreadable") ()));
    Alcotest.(check (list string)) "source stays pending" [ source.post_id ]
      (pending_post_ids ~base_path))
;;

let test_registry_admission_returns_the_callers_value () =
  with_temp_dir (fun base_path ->
    Eio_main.run (fun _env ->
      match
        Registry_event_queue.with_stimulus_admission ~base_path keeper_name (fun admit ->
          admission_label (admit source))
      with
      | Registry_event_queue.Admission_completed label ->
        Alcotest.(check string) "admission" "enqueued" label
      | Registry_event_queue.Admission_shutdown_reserved _ ->
        Alcotest.fail "no shutdown holds this intake"
      | Registry_event_queue.Admission_storage_error detail -> Alcotest.fail detail);
    Alcotest.(check (list string)) "pointer committed" [ source.post_id ]
      (pending_post_ids ~base_path))
;;

let () =
  Alcotest.run
    "keeper event queue stimulus admission"
    [ ( "admission under the owner lock"
      , [ Alcotest.test_case "durable before the caller's next write" `Quick
            test_admission_is_durable_before_the_callers_next_write
        ; Alcotest.test_case "a repeated admission is already present" `Quick
            test_a_repeated_admission_is_already_present
        ; Alcotest.test_case "admit after release writes nothing" `Quick
            test_admit_after_the_lock_is_released_writes_nothing
        ; Alcotest.test_case "another transaction waits for the caller" `Quick
            test_another_transaction_waits_for_the_callers_work
        ; Alcotest.test_case "registry returns the caller's value" `Quick
            test_registry_admission_returns_the_callers_value
        ] )
    ; ( "ACK decided under the owner lock"
      , [ Alcotest.test_case "withheld writes nothing" `Quick test_withheld_ack_writes_nothing
        ; Alcotest.test_case "not withheld commits" `Quick test_unwithheld_ack_commits
        ; Alcotest.test_case "withhold error writes nothing" `Quick
            test_withhold_error_writes_nothing
        ] )
    ]
;;

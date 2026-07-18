(* Board payload authority regressions. Board reads remain explicit at the
   producer/admission boundary, but a durable queue lease is a complete
   immutable prompt snapshot. Intake must render it without consulting the
   mutable Board, preserve distinct same-post occurrences, and ACK only after
   successful projection. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(** Temp directory for test isolation — set before any Board.global call
    (mirrors test_board_dispatch.ml's [fresh_test_base_path]). *)
let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-unavailable-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let with_eio f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()
;;

let test_meta name =
  match
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
         ; "trace_id", `String ("trace-" ^ name)
         ; "sandbox_profile", `String "local"
         ; "network_mode", `String "inherit"
         ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.failf "test meta failed: %s" message
;;

(* (1) Exhaustive classification, pinned. A future new [Board.board_error]
   variant forces [disposition_of_error] to grow (compiler-enforced); this
   test pins today's actual poison/transient split so a change to the table
   is a deliberate, reviewed diff rather than a silent behavior change. *)
let test_disposition_of_error_classifies_every_variant () =
  let module BS = Keeper_world_observation_board_signal in
  let is_permanent err = BS.disposition_of_error err = BS.Permanent in
  let is_transient err = BS.disposition_of_error err = BS.Transient in
  check bool "Post_not_found is permanent (post swept, never resolves on retry)" true
    (is_permanent (Board.Post_not_found "p"));
  check bool "Comment_not_found is permanent (same argument, for a comment id)" true
    (is_permanent (Board.Comment_not_found "c"));
  check bool "Invalid_id is permanent (malformed id string never becomes valid)" true
    (is_permanent (Board.Invalid_id "bad id"));
  check bool "Io_error is transient (store/disk hiccup, retry may succeed)" true
    (is_transient (Board.Io_error "disk hiccup"));
  check bool "Validation_error is permanent (deterministic input-validation failure)" true
    (is_permanent (Board.Validation_error "x"));
  check bool "Already_voted is permanent (deterministic action conflict)" true
    (is_permanent (Board.Already_voted "x"));
  check bool "Already_exists is permanent (deterministic conflict)" true
    (is_permanent (Board.Already_exists "x"));
  check bool "Unauthorized is permanent (deterministic identity rejection)" true
    (is_permanent (Board.Unauthorized "x"))
;;

let poison_post_id = "nonexistent-post-poison-test"

(* A [Board_signal] stimulus naming a post_id that was never created in this
   test's isolated JSONL store — the exact shape of the reported incident
   (post swept from the store between the signal firing and the keeper
   consuming it). *)
let poison_board_signal_stimulus () : Keeper_event_queue.stimulus =
  { Keeper_event_queue.post_id = poison_post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = Time_compat.now ()
  ; payload =
      Keeper_event_queue.Board_signal
        { kind = Keeper_event_queue.Post_created
        ; author = "external-author"
        ; title = "poison stimulus"
        ; content = "references a post_id that was never created"
        ; preview = "immutable admitted preview"
        ; hearth = None
        ; post_kind = Keeper_event_queue.Human_post
        ; updated_at = Time_compat.now ()
        ; explicit_mention = false
        ; matched_targets = []
        ; thread_snapshot =
            { self_commented = false
            ; new_external_since = 0
            ; latest_external = None
            }
        }
  }
;;

(* A missing source post cannot affect an already-admitted payload. *)
let test_missing_source_still_projects_durable_payload () =
  let meta = test_meta "poison-report" in
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (poison_board_signal_stimulus ())
  with
  | Ok (Some event) ->
    check string "durable post id" poison_post_id event.post_id;
    check string "durable preview survives missing source" "immutable admitted preview" event.preview
  | Ok None -> fail "Board payload must produce an actionable event"
  | Error error ->
    fail ("valid durable Board payload failed: " ^ Keeper_event_queue.board_stimulus_error_to_string error)
;;

(* Reprojection is pure and deterministic across retries. *)
let test_missing_source_projection_is_deterministic () =
  let meta = test_meta "poison-intake" in
  let stim = poison_board_signal_stimulus () in
  let first_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  let first_pass = Result.get_ok first_pass in
  check int "first pass preserves the queued snapshot" 1 (List.length first_pass);
  let second_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  let second_pass = Result.get_ok second_pass in
  check int "second pass remains deterministic" 1 (List.length second_pass)
;;

let test_leased_snapshot_renders_before_ack_without_board_source () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let keeper_name = "durable-board-intake" in
  let meta = test_meta keeper_name in
  let stimulus = poison_board_signal_stimulus () in
  (match
     Keeper_registry_event_queue.enqueue_durable_result
       ~base_path
       keeper_name
       stimulus
   with
   | Ok () -> ()
   | Error detail -> fail ("enqueue failed: " ^ detail));
  let lease =
    match
      Keeper_registry_event_queue.claim_when_result
        ~base_path
        keeper_name
        ~claimed_at:(Time_compat.now ())
        ~ready:(fun _ -> true)
    with
    | Error detail -> fail ("claim failed: " ^ detail)
    | Ok None -> fail "durable Board stimulus was not leased"
    | Ok (Some lease) -> lease
  in
  let leased = Keeper_registry_event_queue.lease_stimuli lease in
  let rendered =
    match
      Keeper_heartbeat_stimulus_intake.consume_board_stimulus_batch
        ~meta_after_triage:meta
        leased
    with
    | Ok events -> events
    | Error detail -> fail ("leased payload did not render: " ^ detail)
  in
  check int "leased payload renders exactly once" 1 (List.length rendered);
  check string
    "rendering comes from the immutable queue snapshot"
    "immutable admitted preview"
    (List.hd rendered).Keeper_world_observation.preview;
  (match
     Keeper_registry_event_queue.settle_result
       ~base_path
       keeper_name
       ~settled_at:(Time_compat.now ())
       ~lease
       ~settlement:Keeper_registry_event_queue.Ack
   with
   | Ok (Keeper_registry_event_queue.Settled _)
   | Ok (Keeper_registry_event_queue.Already_settled _)
   | Ok (Keeper_registry_event_queue.Committed_followup_failed _) -> ()
   | Error detail -> fail ("ACK failed: " ^ detail));
  check
    bool
    "ACK removes only the already-rendered durable payload"
    true
    (Keeper_event_queue.is_empty
       (Keeper_event_queue_persistence.load ~base_path ~keeper_name))
;;

let test_same_post_queued_occurrences_are_lossless () =
  let meta = test_meta "same-post-lossless" in
  let created = poison_board_signal_stimulus () in
  let commented =
    match created.payload with
    | Keeper_event_queue.Board_signal board ->
      { created with
        payload =
          Keeper_event_queue.Board_signal
            { board with
              kind = Keeper_event_queue.Comment_added
            ; preview = "second immutable occurrence"
            ; updated_at = board.updated_at +. 1.0
            ; thread_snapshot =
                { self_commented = false
                ; new_external_since = 1
                ; latest_external =
                    Some
                      { latest_author = "external-author"
                      ; latest_preview = "second comment"
                      }
                }
            }
      }
    | _ -> fail "Board fixture changed payload family"
  in
  let project stimulus =
    match Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "Board stimulus projected no event"
    | Error error ->
      fail (Keeper_event_queue.board_stimulus_error_to_string error)
  in
  let created_event = project created in
  let commented_event = project commented in
  let merged =
    Keeper_heartbeat_stimulus_intake.merge_queued_board_events
      ~queued:[ created_event; commented_event ]
      ~scanned:[ created_event ]
  in
  check int "two immutable same-post occurrences survive" 2 (List.length merged);
  match merged with
  | [ first; second ] ->
    check string "queued authority is first" "immutable admitted preview" first.preview;
    check string "distinct comment occurrence survives" "second immutable occurrence" second.preview
  | _ -> fail "lossless merge changed occurrence ordering"
;;

let () =
  run
    "keeper_board_unavailable"
    [ ( "disposition"
      , [ test_case
            "disposition_of_error classifies every board_error variant"
            `Quick
            test_disposition_of_error_classifies_every_variant
        ] )
    ; ( "poison stimulus (masc keeper-cycle-exception incident)"
      , [ test_case
            "missing mutable source does not affect durable projection"
            `Quick
            (with_eio test_missing_source_still_projects_durable_payload)
        ; test_case
            "stimulus intake consumes without crash, stable on repeat"
            `Quick
            (with_eio test_missing_source_projection_is_deterministic)
        ; test_case
            "leased immutable snapshot renders before ACK without Board source"
            `Quick
            (with_eio test_leased_snapshot_renders_before_ack_without_board_source)
        ; test_case
            "same-post queued occurrences remain lossless"
            `Quick
            (with_eio test_same_post_queued_occurrences_are_lossless)
        ] )
    ]
;;

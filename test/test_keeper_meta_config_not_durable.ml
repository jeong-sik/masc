(** Config fields do not survive the durable keeper-meta round trip.

    TOML owns keeper config; the runtime JSON carries runtime state only.
    [Keeper_meta_contract.effective_meta_of_profile_defaults] overlays config on
    the way out, so [meta_to_json] does not write these fields and
    [meta_of_json] fills them from placeholders.

    The record does not say so. [{ meta with autoboot_enabled = false }]
    compiles, stores nothing and reads back [true], which cost three wrong
    root-cause guesses on one test failure (#27357). Splitting config out of
    [keeper_meta] is the fix. Until then this suite states the contract, so the
    drop is a checked property rather than something a reader has to infer from
    a decoder literal. *)

open Masc

let round_trip (meta : Keeper_meta_contract.keeper_meta) =
  match Keeper_meta_json_parse.meta_of_json (Keeper_meta_json.meta_to_json meta) with
  | Ok decoded -> decoded
  | Error detail -> Alcotest.fail ("meta round trip failed: " ^ detail)
;;

let base_meta () =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ ("name", `String "cfg-keeper") ]) with
  | Ok meta -> meta
  | Error detail -> Alcotest.fail ("fixture meta failed: " ^ detail)
;;

let test_config_writes_are_dropped () =
  let open Keeper_meta_contract in
  let meta = base_meta () in
  let written =
    { meta with
      autoboot_enabled = not meta.autoboot_enabled
    ; mention_targets = [ "someone" ]
    ; always_allow = Some true
    ; voice_always_allow = Some true
    ; max_context_override = Some 4242
    ; telemetry_feedback_enabled = Some true
    ; telemetry_feedback_window_hours = Some 7
    ; sandbox_image = Some "written-image"
    ; proactive = { enabled = not meta.proactive.enabled }
    }
  in
  let decoded = round_trip written in
  Alcotest.(check bool) "autoboot_enabled is not durable" true decoded.autoboot_enabled;
  Alcotest.(check (list string)) "mention_targets is not durable" [] decoded.mention_targets;
  Alcotest.(check bool) "always_allow is not durable" true (decoded.always_allow = None);
  Alcotest.(check bool) "voice_always_allow is not durable" true (decoded.voice_always_allow = None);
  Alcotest.(check bool)
    "max_context_override is not durable" true (decoded.max_context_override = None);
  Alcotest.(check bool)
    "telemetry_feedback_enabled is not durable"
    true
    (decoded.telemetry_feedback_enabled = None);
  Alcotest.(check bool)
    "telemetry_feedback_window_hours is not durable"
    true
    (decoded.telemetry_feedback_window_hours = None);
  Alcotest.(check bool) "sandbox_image is not durable" true (decoded.sandbox_image = None)
;;

let test_state_writes_do_survive () =
  let open Keeper_meta_contract in
  let meta = base_meta () in
  let task_id =
    match Keeper_id.Task_id.of_string "task-77" with
    | Ok id -> id
    | Error detail -> Alcotest.fail ("task id fixture failed: " ^ detail)
  in
  let written = { meta with paused = not meta.paused; current_task_id = Some task_id } in
  let decoded = round_trip written in
  Alcotest.(check bool) "paused is durable" written.paused decoded.paused;
  Alcotest.(check bool)
    "current_task_id is durable"
    true
    (Option.equal Keeper_id.Task_id.equal decoded.current_task_id (Some task_id))
;;

let () =
  Alcotest.run
    "keeper-meta-config-not-durable"
    [ ( "round trip"
      , [ Alcotest.test_case "config writes are dropped" `Quick test_config_writes_are_dropped
        ; Alcotest.test_case "state writes survive" `Quick test_state_writes_do_survive
        ] )
    ]
;;

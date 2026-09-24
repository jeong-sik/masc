(** Config fields do not survive the durable keeper-meta round trip.

    TOML owns keeper config; the runtime JSON carries runtime state only.
    [Keeper_meta_contract.effective_meta_of_profile_defaults] overlays config on
    the way out, so [meta_to_json] does not write these fields and
    [meta_of_json] fills them from placeholders.

    The record does not say so. [{ meta with activation_mode = Masc.Keeper_activation_mode.Manual }]
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
      activation_mode = Masc.Keeper_activation_mode.Manual
    ; input_policy = Keeper_input_policy.Wide
    ; mention_targets = [ "someone" ]
    ; board_interests = [ "MASC runtime" ]
    ; always_allow = Some true
    ; voice_always_allow = Some true
    ; max_context_override = Some 4242
    ; telemetry_feedback_enabled = Some true
    ; telemetry_feedback_window_hours = Some 7
    ; sandbox_image = Some "written-image"
    }
  in
  let decoded = round_trip written in
  Alcotest.(check bool) "input policy is TOML-owned" true (decoded.input_policy = Keeper_input_policy.Small);
  let defaults = {Keeper_types_profile.empty_keeper_profile_defaults with
    sandbox_profile=Some Keeper_types_profile.Docker;
    sandbox_image=Some "masc-sandbox:general";
    input_policy=Some Keeper_input_policy.Wide} in
  let effective defaults meta = match Keeper_meta_contract.effective_meta_of_profile_defaults defaults meta with
    | Ok effective -> effective | Error detail -> Alcotest.fail detail in
  let wide = effective defaults decoded in
  Alcotest.(check bool) "TOML wide policy overlays runtime state" true (wide.input_policy = Keeper_input_policy.Wide);
  let small = effective {defaults with input_policy=None} wide in
  Alcotest.(check bool) "omission resets cached policy to declared default" true (small.input_policy = Keeper_input_policy.Small);
  Alcotest.(check bool) "autoboot_enabled is not durable" true (Masc.Keeper_activation_mode.restore_owner decoded.activation_mode);
  Alcotest.(check (list string)) "mention_targets is not durable" [] decoded.mention_targets;
  Alcotest.(check (list string)) "board_interests is not durable" [] decoded.board_interests;
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

(* board_interests is a config field like the others above -- the raw
   snapshot never carries it -- but [effective_meta_of_profile_defaults] is
   the overlay that is supposed to restore it from the keeper's own TOML
   profile. Until #37586 it mirrored [mention_targets]: an empty profile
   default preserved whatever the caller already had. #37586 added
   [board_interests] to this same overlay but wrote an unconditional
   [defaults.board_interests] instead of [mention_targets]'s fallback match,
   so any keeper without a profile-declared value had it wiped to [] on
   every overlay call -- including the one inside
   [wakeup_relevant_keeper_for_board_signal], which is why an explicitly
   interested Keeper's Board attention candidate stopped being recorded
   (task-1670, test_board_dispatch / test_keeper_board_discoverable_cursor /
   test_keeper_keepalive_helpers). *)
let test_board_interests_survive_an_empty_profile_default () =
  let open Keeper_meta_contract in
  let effective defaults meta =
    match effective_meta_of_profile_defaults defaults meta with
    | Ok effective -> effective
    | Error detail -> Alcotest.fail detail
  in
  let meta = { (base_meta ()) with board_interests = [ "thread review" ] } in
  (* [effective_meta_of_profile_defaults] rejects an unresolved sandbox
     profile before it ever reaches board_interests (Ok sandbox_profile
     guard), so every defaults value needs one, same as
     test_config_writes_are_dropped above. *)
  let defaults_with_profile board_interests =
    { Keeper_types_profile.empty_keeper_profile_defaults with
      sandbox_profile = Some Keeper_types_profile.Docker
    ; sandbox_image = Some "masc-sandbox:general"
    ; board_interests
    }
  in
  let overlaid = effective (defaults_with_profile []) meta in
  Alcotest.(check (list string))
    "an empty profile default does not clear an existing board_interests"
    [ "thread review" ]
    overlaid.board_interests;
  let replaced = effective (defaults_with_profile [ "release" ]) meta in
  Alcotest.(check (list string))
    "a profile-declared board_interests still overrides"
    [ "release" ]
    replaced.board_interests
;;

(* #37523. A profile that runs a container has to name its image: boot
   refuses a docker or microvm keeper whose TOML names none rather than
   handing it the general image. The cases split on the two inputs that
   decide it -- the profile, and whether an image is declared -- so a rule
   that refused everything, or nothing, fails here. *)
let test_a_container_profile_must_name_its_image () =
  let open Keeper_meta_contract in
  let meta = base_meta () in
  let defaults ?sandbox_image ?remote_endpoint sandbox_profile =
    { Keeper_types_profile.empty_keeper_profile_defaults with
      sandbox_profile = Some sandbox_profile
    ; sandbox_image
    ; remote_endpoint
    }
  in
  let contains ~affix text =
    let n = String.length affix and m = String.length text in
    let rec at i = i + n <= m && (String.sub text i n = affix || at (i + 1)) in
    at 0
  in
  let refused label defaults =
    match effective_meta_of_profile_defaults defaults meta with
    | Ok _ -> Alcotest.failf "%s: boot must refuse a keeper with no image" label
    | Error detail ->
      Alcotest.(check bool)
        (label ^ ": the refusal names the missing key")
        true
        (contains ~affix:"sandbox_image is required" detail)
  in
  refused "docker, no image" (defaults Keeper_types_profile.Docker);
  refused "docker, blank image" (defaults ~sandbox_image:"  " Keeper_types_profile.Docker);
  (* The microvm arm goes through the shared rule directly: boot checks the
     guest backend first, and whether this host has a default backend is not
     what this case is about. *)
  Alcotest.(check bool)
    "microvm, no image: refused by the shared rule"
    true
    (Option.is_some
       (missing_required_sandbox_image_error ~keeper_name:"cfg-keeper"
          Keeper_types_profile.Micro_vm
          (defaults Keeper_types_profile.Micro_vm)));
  (match
     effective_meta_of_profile_defaults
       (defaults ~sandbox_image:"masc-keeper-sandbox:local" Keeper_types_profile.Docker)
       meta
   with
   | Ok effective ->
     Alcotest.(check (option string))
       "a declared image is the one the keeper runs in"
       (Some "masc-keeper-sandbox:local")
       effective.sandbox_image
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check (option string))
    "remote_ssh runs no image and is not asked for one"
    None
    (missing_required_sandbox_image_error ~keeper_name:"cfg-keeper"
       Keeper_types_profile.Remote_ssh
       (defaults ~remote_endpoint:"fixture" Keeper_types_profile.Remote_ssh))
;;

let () =
  Alcotest.run
    "keeper-meta-config-not-durable"
    [ ( "round trip"
      , [ Alcotest.test_case "config writes are dropped" `Quick test_config_writes_are_dropped
        ; Alcotest.test_case "state writes survive" `Quick test_state_writes_do_survive
        ; Alcotest.test_case "board_interests survives an empty profile default"
            `Quick test_board_interests_survive_an_empty_profile_default
        ] )
    ; ( "sandbox image"
      , [ Alcotest.test_case "a container profile must name its image" `Quick
            test_a_container_profile_must_name_its_image
        ] )
    ]
;;

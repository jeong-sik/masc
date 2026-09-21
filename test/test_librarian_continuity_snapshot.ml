open Alcotest
module S = Masc.Librarian_continuity_snapshot
module B = Masc.Keeper_turn_boundaries
module T = Agent_core.Types

let trace_id = "continuity-fixture"
let state = "Await publication approval; the build passed."
let msg role text = T.make_message ~role [T.Text text]
let pinned = msg T.System "Keep the current instructions."
let user = msg T.User "Build before publishing."
let assistant = msg T.Assistant "Checking the build."
let tool = msg T.Tool "Build passed."
let history = [pinned; user; assistant; tool]

let boundary ?(trace = trace_id) ?(turn = 1) ?(fresh = true) messages =
  let position = match B.position_of_messages messages with
    | Ok position -> position | Error detail -> fail detail in
  Ok { B.recorded_at = 1.; event = B.Turn_ended
    { turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
    ; history_at_start = if fresh then B.Fresh_history else B.Continued_history
    ; position } }
;;
let lines = [1, boundary history]
let require = function Ok value -> value | Error error -> fail (S.error_to_string error)
let capture () = S.capture ~trace_id ~lines ~messages:history ~working_state:state |> require
let restore ?(trace_id = trace_id) ?(lines = lines) messages snapshot =
  S.restore ~trace_id ~lines ~messages snapshot
;;
let expect_error label = function
  | Error _ -> () | Ok _ -> fail label
;;

let test_restore_append_and_all_covered () =
  let snapshot = capture () in
  let all = restore history snapshot |> require in
  check bool "all old atoms removed, pinned retained" true (all.messages = [pinned]);
  check string "working state paired with frontier" state all.working_state;
  let next = msg T.User "What remains before publication?" in
  let appended = history @ [next] in
  let restored = restore ~lines:(lines @ [2, boundary ~fresh:false appended]) appended snapshot |> require in
  check bool "append retained without duplicated covered atoms" true (restored.messages = [pinned; next]);
  let in_flight = restore appended snapshot |> require in
  check bool "unfinished appended atom retained too" true (in_flight.messages = [pinned; next])
;;

let test_identity_rejections () =
  let snapshot = capture () in
  (match restore ~trace_id:"another-trace" history snapshot with
   | Error S.Trace_mismatch -> () | _ -> fail "cross-trace snapshot accepted");
  (match restore ~lines:(lines @ [2, boundary history]) history snapshot with
   | Error S.History_changed -> () | _ -> fail "same-text restart accepted");
  (match restore ~lines:[1, boundary ~turn:2 history] history snapshot with
   | Error S.History_changed -> () | _ -> fail "same endpoint with different turn identity accepted");
  let moved_endpoint = [1, Ok { B.recorded_at = 1.; event = B.History_restarted {trace_id} };
                        2, boundary ~fresh:false history] in
  (match restore ~lines:moved_endpoint history snapshot with
   | Error S.History_changed -> () | _ -> fail "ending boundary moved to another row");
  let rewritten = [pinned; user; assistant; msg T.Tool "Build failed."] in
  (match restore rewritten snapshot with
   | Error S.Prefix_changed -> () | _ -> fail "changed tool result accepted with identical atom opener");
  expect_error "shortened history accepted" (restore [pinned; user] snapshot);
  expect_error "missing covered boundary accepted"
    (restore ~lines:[1, Ok { B.recorded_at = 1.; event = B.History_restarted {trace_id} };
                     2, boundary ~fresh:false (history @ [msg T.User "new"])]
       (history @ [msg T.User "new"]) snapshot)
;;

let test_capture_requires_witness () =
  expect_error "baseline substituted for captured work"
    (S.capture ~trace_id ~lines:[1, boundary ~fresh:false history]
       ~messages:history ~working_state:state);
  expect_error "empty boundary log admitted"
    (S.capture ~trace_id ~lines:[] ~messages:history ~working_state:state);
  expect_error "malformed boundary admitted"
    (S.capture ~trace_id ~lines:(lines @ [2, Error (B.Not_json "bad")])
       ~messages:history ~working_state:state)
;;

let test_exact_codec () =
  let snapshot = capture () in
  let fields = match S.to_json snapshot with `Assoc fields -> fields | _ -> fail "object" in
  let invalid =
    [ `Null; `Assoc []; `Assoc (("extra", `Bool true) :: fields)
    ; `Assoc (("end_atom", `Int 2) :: fields)
    ; `Assoc (List.map (fun (key, value) -> key, if key = "end_atom" then `Int 0 else value) fields)
    ; `Assoc (List.map (fun (key, value) -> key, if key = "end_boundary_line" then `Int 0 else value) fields)
    ; `Assoc (List.map (fun (key, value) -> key, if key = "end_turn_ref" then Ids.Turn_ref.to_yojson (Ids.Turn_ref.make ~trace_id:"other" ~absolute_turn:1) else value) fields)
    ; `Assoc (List.map (fun (key, value) -> key, if key = "end_turn_ref" then `Int 1 else value) fields)
    ; `Assoc (List.map (fun (key, value) -> key, if key = "prefix_sha256" then `String "invalid" else value) fields)
    ] in
  List.iter (fun json -> expect_error "malformed snapshot accepted" (S.of_json json)) invalid;
  let decoded = S.of_json (S.to_json snapshot) |> require in
  check bool "strict codec keeps the pair" true (decoded = snapshot)
;;

let test_file_pair () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "continuity-pair-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    let path = Filename.concat dir "pair.json" in
    expect_error "missing snapshot became an empty state" (S.load ~path);
    let snapshot = capture () in
    S.save ~path snapshot |> require;
    let loaded = S.load ~path |> require in
    check bool "frontier and work are read from one file" true (snapshot = loaded);
    let next = msg T.User "Approval received." in
    let messages = history @ [next] in
    let newer = S.capture ~trace_id ~lines:(lines @ [2, boundary ~fresh:false messages])
      ~messages ~working_state:"Publish the already built artifact." |> require in
    S.save ~path newer |> require;
    check bool "replacement does not mix revisions" true ((S.load ~path |> require) = newer);
    Out_channel.with_open_bin path (fun oc -> output_string oc "{");
    expect_error "corrupt snapshot accepted" (S.load ~path))
;;

let test_captured_partial_prefix () =
  let lines=[1, boundary ~fresh:false history] in
  let snapshot=S.capture_checkpoint_prefix ~end_atom:1 ~trace_id ~lines ~messages:history
    ~working_state:state () |> require in
  check int "real completed anchor" 2 snapshot.covering_end_atom;
  check int "cut at whole first atom" 1 snapshot.end_atom;
  let restored=S.restore ~trace_id ~lines ~messages:history snapshot |> require in
  check bool "assistant and tool result retained together" true
    (restored.messages=[pinned;assistant;tool]);
  expect_error "changed captured prefix accepted"
    (S.restore ~trace_id ~lines ~messages:[pinned;msg T.User "Changed";assistant;tool] snapshot);
  expect_error "different real covering turn accepted"
    (S.restore ~trace_id ~lines:[1,boundary ~fresh:false ~turn:2 history] ~messages:history snapshot);
  check bool "explicit source survives codec" true ((S.of_json (S.to_json snapshot) |> require) = snapshot);
  expect_error "cut outside completed prefix accepted"
    (S.capture_checkpoint_prefix ~end_atom:3 ~trace_id ~lines ~messages:history ~working_state:state ());
  let whole=S.capture_checkpoint_prefix ~trace_id ~lines ~messages:history ~working_state:state () |> require in
  check bool "whole assistant atom includes tool result" true
    ((S.restore ~trace_id ~lines ~messages:history whole |> require).messages=[pinned])
;;

let () = run "offline continuity snapshot"
  ["pair", [test_case "captured partial prefix" `Quick test_captured_partial_prefix;test_case "append and complete prefix" `Quick test_restore_append_and_all_covered;
            test_case "source identities" `Quick test_identity_rejections;
            test_case "restart witness required" `Quick test_capture_requires_witness;
            test_case "strict codec" `Quick test_exact_codec;
            test_case "atomic file pair" `Quick test_file_pair]]

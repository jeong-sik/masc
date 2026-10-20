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
    { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
    ; history_at_start = if fresh then B.Fresh_history else B.Continued_history
    ; position } }
;;
let lines = [1, boundary history]

(* An official-client turn writes no atom position at its end. The history it
   started from is the only line that states where the checkpoint's atoms end. *)
let official_client_turn ?(turn = 2) messages =
  match B.position_of_messages messages with
  | Ok (B.Atom_history { end_atom; last_atom_digest }) ->
    Ok { B.recorded_at = 2.; event = B.Turn_ended
      { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
      ; history_at_start =
          B.Continued_history_from { start_atom = end_atom; start_atom_digest = last_atom_digest }
      ; position = B.No_atom_history } }
  | Ok (B.Empty_atom_history | B.No_atom_history | B.Stale_noop) | Error _ ->
    fail "history states no atom position"
;;
let require = function Ok value -> value | Error error -> fail (S.error_to_string error)
let capture () = S.capture ~unread_messages:[] ~trace_id ~lines ~messages:history ~working_state:state |> require
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

let test_digest_matches_checkpoint_array () =
  let request = T.make_message ~role:T.User
    ~metadata:["source", `Assoc ["quoted", `String "\"한글\\\n"; "enabled", `Bool true]]
    [T.Text "검토: \"path\\name\"\n\t\000"] in
  let call = T.make_message ~role:T.Assistant
    [T.ToolUse {id = "read-1"; name = "read_file";
      input = `Assoc ["path", `String "문서/수정.json"; "lines", `List [`Int 1; `Int 2]]}] in
  let result body =
    { (T.make_message ~role:T.Tool
         [T.ToolResult {tool_use_id = "read-1"; content = body;
           outcome = T.Tool_succeeded; json = Some (`Assoc ["answer", `Null]);
           content_blocks = None}]) with tool_call_id = Some "read-1" } in
  let answer = result "결과\n\"quoted\"\\escaped" in
  let injected = msg T.System "Pinned context between an assistant and its tool." in
  let messages = [pinned; request; call; injected; answer] in
  let lines = [1, boundary messages] in
  let array_digest prefix =
    let json = `List (List.map Agent_core.Checkpoint.message_to_json prefix) in
    Digestif.SHA256.(digest_string (Yojson.Safe.to_string json) |> to_hex) in
  let check_prefix end_atom prefix remaining =
    let expected = array_digest prefix in
    let snapshot = S.capture_checkpoint_prefix ~unread_messages:[] ~end_atom ~catch_up_end_atom:None
      ~trace_id ~lines ~messages ~working_state:state () |> require in
    check string "stored digest matches checkpoint array bytes" expected snapshot.prefix_sha256;
    let saved = match S.to_json snapshot with
      | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
          key, if key = "prefix_sha256" then `String expected else value) fields)
      | _ -> fail "snapshot object" in
    let loaded = S.of_json saved |> require in
    let restored = S.restore ~trace_id ~lines ~messages loaded |> require in
    check bool "array-digested snapshot restores exact suffix and pinned context" true
      (restored.messages = remaining)
  in
  check_prefix 1 [request] [pinned; call; injected; answer];
  check_prefix 2 [request; call; answer] [pinned; injected];
  let snapshot = S.capture ~unread_messages:[] ~trace_id ~lines ~messages ~working_state:state |> require in
  (match S.restore ~trace_id ~lines
     ~messages:[pinned; request; call; injected; result "changed result"] snapshot with
   | Error S.Prefix_changed -> ()
   | Ok _ | Error _ -> fail "modified tool result must invalidate the whole-prefix digest")
;;

let test_capture_requires_witness () =
  expect_error "baseline substituted for captured work"
    (S.capture ~unread_messages:[] ~trace_id ~lines:[1, boundary ~fresh:false history]
       ~messages:history ~working_state:state);
  expect_error "empty boundary log admitted"
    (S.capture ~unread_messages:[] ~trace_id ~lines:[] ~messages:history ~working_state:state);
  expect_error "malformed boundary admitted"
    (S.capture ~unread_messages:[] ~trace_id ~lines:(lines @ [2, Error (B.Not_json "bad")])
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
    let newer = S.capture ~unread_messages:[] ~trace_id ~lines:(lines @ [2, boundary ~fresh:false messages])
      ~messages ~working_state:"Publish the already built artifact." |> require in
    S.save ~path newer |> require;
    check bool "replacement does not mix revisions" true ((S.load ~path |> require) = newer);
    Out_channel.with_open_bin path (fun oc -> output_string oc "{");
    expect_error "corrupt snapshot accepted" (S.load ~path))
;;

let test_captured_partial_prefix () =
  let lines=[1, boundary ~fresh:false history] in
  let snapshot=S.capture_checkpoint_prefix ~unread_messages:[] ~end_atom:1 ~catch_up_end_atom:None ~trace_id ~lines ~messages:history
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
    (S.capture_checkpoint_prefix ~unread_messages:[] ~end_atom:3 ~catch_up_end_atom:None ~trace_id ~lines ~messages:history ~working_state:state ());
  let whole=S.capture_checkpoint_prefix ~unread_messages:[] ~catch_up_end_atom:None ~trace_id ~lines ~messages:history ~working_state:state () |> require in
  check bool "whole assistant atom includes tool result" true
    ((S.restore ~trace_id ~lines ~messages:history whole |> require).messages=[pinned])
;;

let test_official_client_start_state_is_the_covering_line () =
  let lines = [1, official_client_turn history] in
  let snapshot =
    S.capture_checkpoint_prefix ~unread_messages:[] ~catch_up_end_atom:None ~trace_id ~lines ~messages:history
      ~working_state:state ()
    |> require in
  check int "the start state of the turn is the covering line" 1 snapshot.end_boundary_line;
  check int "the whole prefix is covered" 2 snapshot.end_atom;
  check bool "covered atoms removed, pinned retained" true
    ((restore ~lines history snapshot |> require).messages = [pinned]);
  let later = lines @ [2, official_client_turn ~turn:3 history] in
  check bool "a later turn from the same position leaves the covering line alone" true
    ((restore ~lines:later history snapshot |> require).messages = [pinned]);
  (match restore ~lines:[1, official_client_turn ~turn:3 history] history snapshot with
   | Error S.History_changed -> ()
   | Ok _ | Error _ -> fail "another turn accepted as the covering line")
;;

(* An earlier generation ended at the same atom and digest that the current
   generation's official-client turn started from. Both lines state the same
   position, and the end line comes first. The line that covers the checkpoint
   is the current generation's start state: the earlier end line states a
   position of a history that is gone. *)
let test_earlier_generation_end_does_not_hide_the_current_start_state () =
  let restarted = Ok { B.recorded_at = 1.5; event = B.History_restarted { trace_id } } in
  let earlier = [1, boundary history] in
  let current = [1, boundary history; 2, restarted; 3, official_client_turn history] in
  let snapshot =
    S.capture_checkpoint_prefix ~unread_messages:[] ~catch_up_end_atom:None ~trace_id ~lines:current ~messages:history
      ~working_state:state ()
    |> require in
  check int "the current generation's start state is the covering line" 3 snapshot.end_boundary_line;
  check int "the whole prefix is covered" 2 snapshot.end_atom;
  check bool "covered atoms removed, pinned retained" true
    ((restore ~lines:current history snapshot |> require).messages = [pinned]);
  let before_restart =
    S.capture_checkpoint_prefix ~unread_messages:[] ~catch_up_end_atom:None ~trace_id ~lines:earlier ~messages:history
      ~working_state:state ()
    |> require in
  (match restore ~lines:current history before_restart with
   | Error S.History_changed -> ()
   | Ok _ | Error _ -> fail "a snapshot of the earlier generation restored after the restart")
;;

(* A rewrite from atom 0 carries where requests started when it began. The
   key is written only while the snapshot is short of it, so an ordinary
   snapshot keeps the shape it always had. *)
let test_catch_up_target_codec () =
  let lines=[1, boundary ~fresh:false history] in
  let capture target = S.capture_checkpoint_prefix ~unread_messages:[] ~end_atom:1 ~catch_up_end_atom:target
    ~trace_id ~lines ~messages:history ~working_state:state () |> require in
  let catching_up = capture (Some 2) in
  check (option int) "a target past the end is kept" (Some 2) catching_up.catch_up_end_atom;
  let fields = match S.to_json catching_up with `Assoc fields -> fields | _ -> fail "not an object" in
  check bool "the target is on the wire" true (List.mem_assoc "catch_up_end_atom" fields);
  check bool "and survives the codec" true ((S.of_json (S.to_json catching_up) |> require) = catching_up);
  let reached = capture (Some 1) in
  check (option int) "a target the end already reached is dropped" None reached.catch_up_end_atom;
  (match S.to_json reached with
   | `Assoc fields -> check bool "an ordinary snapshot has no such key" false (List.mem_assoc "catch_up_end_atom" fields)
   | _ -> fail "not an object");
  let with_target value = `Assoc (List.map (fun (key, v) ->
    if key = "catch_up_end_atom" then key, value else key, v) fields) in
  expect_error "a target not past the end accepted" (S.of_json (with_target (`Int 1)));
  expect_error "a target that is not an integer accepted" (S.of_json (with_target (`String "2")))
;;

(* The prefix hash encodes every covered message, so it runs on the shared CPU
   pool: the caller's fiber waits for it while the caller's domain runs its
   other fibers. Run in place it never yields, and a fiber beside it never
   runs until it returns. The history is long enough that the pool cannot
   answer before the caller starts waiting. *)
let long_history_turns = 1_000
let long_history_text_bytes = 1_000

let test_prefix_hash_leaves_the_callers_domain () =
  let long_history =
    pinned
    :: List.concat
         (List.init long_history_turns (fun turn ->
            [ msg T.User (Printf.sprintf "turn %d %s" turn (String.make long_history_text_bytes 'x'))
            ; msg T.Assistant (Printf.sprintf "answer %d" turn)
            ]))
  in
  let long_lines = [ 1, boundary long_history ] in
  let capture_long () =
    S.capture ~unread_messages:[] ~trace_id ~lines:long_lines ~messages:long_history ~working_state:state |> require
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let in_place = capture_long () in
  let previous = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some pool -> Domain_pool_ref.set pool)
    (fun () ->
      Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
      let beside = ref 0 and finished = ref false in
      let runs_beside f =
        let before = !beside in
        let value = f () in
        value, !beside - before
      in
      Eio.Fiber.both
        (fun () ->
          while not !finished do
            incr beside;
            Eio.Fiber.yield ()
          done)
        (fun () ->
          let pooled, during_capture = runs_beside capture_long in
          let _, during_restore =
            runs_beside (fun () -> restore ~lines:long_lines long_history pooled |> require)
          in
          finished := true;
          check string "the pool computes the same digest"
            in_place.S.prefix_sha256 pooled.S.prefix_sha256;
          check bool "capture lets the fiber beside it run" true (during_capture > 0);
          check bool "restore lets the fiber beside it run" true (during_restore > 0)))
;;

let test_unread_snapshot_source_binding () =
  let module H = Masc.Keeper_librarian_unread in
  let get = function Ok value -> value | Error detail -> fail detail in
  let hole = H.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:1
    ~message_in_atom:1 ~messages:history
    ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] |> get in
  let holes = [hole] in
  let captured = S.capture ~unread_messages:holes ~trace_id ~lines ~messages:history
    ~working_state:state |> require in
  let decoded = S.of_json (S.to_json captured) |> require in
  let restored = restore history decoded |> require in
  check bool "the pair restores exact unread records" true (restored.unread_messages = holes);
  check bool "only pinned messages remain after the declared end" true (restored.messages = [pinned]);
  (match hole.source with
   | H.Atom {message_sha256;_} -> check string "hash covers the exact tool message, not its atom opener"
       Digestif.SHA256.(digest_string (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json tool)) |> to_hex)
       message_sha256
   | H.Official_turn _ -> fail "wrong source identity");
  let fields = match S.to_json decoded with `Assoc fields -> fields | _ -> fail "snapshot object" in
  List.iter (fun key -> expect_error "missing schema or unread list became all-read"
    (S.of_json (`Assoc (List.remove_assoc key fields)))) ["schema_version";"unread_messages"];
  expect_error "another schema silently became current"
    (S.of_json (`Assoc (("schema_version", `Int 1) :: List.remove_assoc "schema_version" fields)));
  let hole_fields = match H.to_json hole with `Assoc fields -> fields | _ -> fail "hole object" in
  List.iter (fun reasons ->
    check bool "unknown, empty or duplicate causes cannot authorize omission" true
      (Result.is_error (H.of_json (`Assoc (("reasons", reasons) :: List.remove_assoc "reasons" hole_fields)))))
    [`List []; `List [`String "invalid_request"]; `List [`String "request_body_refused";`String "request_body_refused"]];
  check bool "no named size refusal cannot record a hole" true
    (Result.is_error (H.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:1
      ~message_in_atom:1 ~messages:history ~reasons:[]));
  expect_error "duplicate coordinates cannot become two holes"
    (S.capture ~unread_messages:[hole;hole] ~trace_id ~lines ~messages:history ~working_state:state);
  let foreign = H.for_atom ~trace_id ~history_start_boundary_line:2 ~atom:1
    ~message_in_atom:1 ~messages:history ~reasons:hole.reasons |> get in
  expect_error "another history generation cannot supply a hole"
    (S.capture ~unread_messages:[foreign] ~trace_id ~lines ~messages:history ~working_state:state);
  expect_error "a hole beyond a partial snapshot end cannot be stored"
    (S.capture_checkpoint_prefix ~unread_messages:holes ~end_atom:1 ~catch_up_end_atom:None
      ~trace_id ~lines ~messages:history ~working_state:state ());
  let wrong_hash = match H.to_json hole with
    | `Assoc fields ->
      let source = match List.assoc "source" fields with
        | `Assoc source -> `Assoc (("message_sha256", `String (String.make 64 '0')) ::
            List.remove_assoc "message_sha256" source)
        | _ -> fail "source object" in
      `Assoc (("source", source) :: List.remove_assoc "source" fields)
    | _ -> fail "hole object" in
  let forged = S.of_json (`Assoc (("unread_messages", `List [wrong_hash]) ::
    List.remove_assoc "unread_messages" fields)) |> require in
  expect_error "valid prefix hash cannot certify a hole naming another message"
    (restore history forged);
  let official = H.for_official_turn ~turn_ref:(Ids.Turn_ref.make ~trace_id ~absolute_turn:3)
    ~boundary_line:4 ~message_in_turn:1 ~messages:[user;assistant]
    ~reasons:hole.reasons |> get in
  check bool "official source has a strict distinct identity" true
    (H.of_json (H.to_json official) |> get = official);
  expect_error "official source cannot be laundered into atom coverage"
    (S.capture ~unread_messages:[official] ~trace_id ~lines ~messages:history ~working_state:state);
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  let dir = Filename.temp_dir "continuity-unread-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) @@ fun () ->
  let path = Filename.concat dir "state.json" in
  S.save ~path decoded |> require;
  let loaded = S.load ~path |> require in
  check bool "one durable replacement preserves state, coverage and exact holes" true (loaded = decoded)
;;

let digest_prefix_atoms = 64
let digest_prefix_atom_bytes = 16 * 1024

(* The digest a restore verified extends, over the same message values, to a
   later end without encoding the covered atoms again, and gives the digest a
   full read gives. *)
let test_a_verified_prefix_digest_extends_over_the_same_values () =
  (* [Gc.allocated_bytes] counts this domain alone, so the bound below
     measures the work only while no worker pool would run it elsewhere. *)
  check bool "no worker pool is installed" true (Option.is_none (Domain_pool_ref.get ()));
  let atoms = List.init digest_prefix_atoms (fun atom ->
    msg T.User (Printf.sprintf "atom %d %s" atom (String.make digest_prefix_atom_bytes 'd'))) in
  let messages = pinned :: atoms in
  let lines = [1, boundary ~fresh:false messages] in
  let capture ?prefix end_atom =
    S.capture_checkpoint_prefix ?prefix ~unread_messages:[] ~end_atom ~catch_up_end_atom:None
      ~trace_id ~lines ~messages ~working_state:state () |> require in
  let before_last = capture (digest_prefix_atoms - 1) in
  let verified = S.restore ~trace_id ~lines ~messages before_last |> require in
  let whole = capture digest_prefix_atoms in
  let covered_bytes = float_of_int ((digest_prefix_atoms - 1) * digest_prefix_atom_bytes) in
  let allocated f =
    let before = Gc.allocated_bytes () in
    let value = f () in
    value, Gc.allocated_bytes () -. before in
  let extended, capture_bytes = allocated (fun () ->
    capture ~prefix:verified.covered_prefix digest_prefix_atoms) in
  check string "the extended digest is the full digest" whole.prefix_sha256 extended.prefix_sha256;
  check bool "the extension does not encode the covered atoms" true (capture_bytes < covered_bytes);
  let restored, restore_bytes = allocated (fun () ->
    S.restore ~prefix:verified.covered_prefix ~trace_id ~lines ~messages whole |> require) in
  check bool "a restore over the same values keeps its answer" true
    ((S.restore ~trace_id ~lines ~messages whole |> require).messages = restored.messages);
  check bool "the restore does not encode the covered atoms" true (restore_bytes < covered_bytes)

(* A digest kept with other values, even equal ones, is never trusted: [0.0]
   and [-0.0] compare equal and encode one byte apart, so the whole prefix is
   read again and the change refuses the snapshot. *)
let test_a_prefix_digest_over_other_values_is_read_again () =
  let call zero = T.make_message ~role:T.Assistant
    [T.ToolUse {id = "measure-1"; name = "measure"; input = `Assoc ["offset", `Float zero]}] in
  let history zero = [pinned; user; call zero; msg T.User "Report the offset."; assistant] in
  let original = history 0.0 and signed = history (-0.0) in
  check bool "the two histories compare equal" true (original = signed);
  let lines = [1, boundary original] in
  let snapshot = S.capture_checkpoint_prefix ~unread_messages:[] ~catch_up_end_atom:None ~trace_id ~lines
      ~messages:original ~working_state:state () |> require in
  let verified = S.restore ~trace_id ~lines ~messages:original snapshot |> require in
  (match S.restore ~prefix:verified.covered_prefix ~trace_id ~lines ~messages:signed snapshot with
   | Error S.Prefix_changed -> ()
   | Ok _ | Error _ -> fail "a digest of other values was trusted");
  (match S.restore ~trace_id ~lines ~messages:signed snapshot with
   | Error S.Prefix_changed -> ()
   | Ok _ | Error _ -> fail "the full read accepts other bytes");
  let copied = List.map (fun (message : T.message) -> {message with role = message.role}) original in
  check bool "equal bytes in other values still fit" true
    (Result.is_ok (S.restore ~prefix:verified.covered_prefix ~trace_id ~lines ~messages:copied snapshot))

let () = run "offline continuity snapshot"
  ["pair", [test_case "unread source binding and atomic pair" `Quick test_unread_snapshot_source_binding;
            test_case "captured partial prefix" `Quick test_captured_partial_prefix;
            test_case "official-client start state" `Quick test_official_client_start_state_is_the_covering_line;
            test_case "earlier generation end vs current start state" `Quick test_earlier_generation_end_does_not_hide_the_current_start_state;
            test_case "append and complete prefix" `Quick test_restore_append_and_all_covered;
            test_case "source identities" `Quick test_identity_rejections;
            test_case "checkpoint array digest and restore" `Quick test_digest_matches_checkpoint_array;
            test_case "restart witness required" `Quick test_capture_requires_witness;
            test_case "strict codec" `Quick test_exact_codec;
            test_case "catch-up target codec" `Quick test_catch_up_target_codec;
            test_case "atomic file pair" `Quick test_file_pair;
            test_case "prefix hash on the pool" `Quick test_prefix_hash_leaves_the_callers_domain;
            test_case "verified prefix digest extends" `Quick test_a_verified_prefix_digest_extends_over_the_same_values;
            test_case "other values are read again" `Quick test_a_prefix_digest_over_other_values_is_read_again]]

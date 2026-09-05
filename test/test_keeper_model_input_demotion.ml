(** Tests for {!Keeper_model_input_demotion} (RFC-0363).

    The load-bearing property is soundness of the size bound: {!Demotion.plan}
    substitutes a placeholder, the window chooses a cut against that
    measurement, and only then are the real markers written. If the
    placeholder ever measures smaller than the marker that replaces it, a
    request that fit the plan exceeds the cap after materialization. Every
    other case here is an input shape that was found — during the RFC's
    adversarial review — to break that direction. *)

module Demotion = Masc.Keeper_model_input_demotion
module Types = Agent_core.Types
module Window = Runtime_model_input_tail_window

(* The production encoder, not a test-local one: the bound is only meaningful
   against the encoder the window will use, and a simplified stand-in would
   hide exactly the JSON escaping that makes a marker larger than it looks. *)
let measure_message_bytes (m : Types.message) =
  String.length
    (Yojson.Safe.to_string (Masc.Keeper_context_core.message_to_json m))
;;

let tool_message ?(content_blocks = None) ~id body : Types.message =
  { role = Types.Tool
  ; content =
      [ Types.ToolResult
          { tool_use_id = id
          ; content = body
          ; outcome = Types.Tool_succeeded
          ; json = None
          ; content_blocks
          }
      ]
  ; name = None
  ; tool_call_id = Some id
  ; metadata = []
  }
;;

let assistant text : Types.message =
  { role = Types.Assistant
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let history_with_tool_bodies bodies =
  List.concat
    (List.mapi
       (fun i body ->
          [ assistant (Printf.sprintf "call %d" i)
          ; tool_message ~id:(Printf.sprintf "call-%d" i) body
          ])
       bodies)
;;

let content_of (m : Types.message) =
  List.filter_map
    (fun (block : Types.content_block) ->
       match block with
       | Types.ToolResult { content; _ } -> Some content
       | _ -> None)
    m.content
;;

let markers messages = List.concat_map content_of messages

(* --- Turn boundary: the keeper keeps what it is working on --------------- *)

(* The assembly demotes results from earlier turns and leaves this turn's
   alone. Stated against the seeded history rather than a count of recent
   results: a keeper that read a file this turn has to still see what it read,
   and a keeper that read one three turns ago has an address for it. *)
let this_turns_results_survive_the_boundary () =
  let body i = String.make 4_000 (Char.chr (Char.code 'a' + i)) in
  let earlier = history_with_tool_bodies [ body 0; body 1 ] in
  let this_turn = history_with_tool_bodies [ body 2 ] in
  let messages = earlier @ this_turn in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let planned =
    Demotion.plan ~measure_message_bytes ~demote_before messages
  in
  let transmitted = markers planned.Demotion.messages in
  Alcotest.(check int)
    "every result is still present"
    3
    (List.length transmitted);
  Alcotest.(check bool)
    "this turn's result is verbatim"
    true
    (List.exists (fun body -> String.equal body (String.make 4_000 'c')) transmitted);
  Alcotest.(check int)
    "and both earlier ones became addresses"
    2
    (List.length planned.Demotion.pending)
;;

(* A turn that has produced nothing yet must not demote its own seed out from
   under itself before it has read anything. *)
let a_turn_that_produced_nothing_demotes_everything_before_it () =
  let messages = history_with_tool_bodies [ String.make 4_000 'a' ] in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length messages)
  in
  let planned =
    Demotion.plan ~measure_message_bytes ~demote_before messages
  in
  Alcotest.(check int)
    "the seeded history is all earlier work"
    1
    (List.length planned.Demotion.pending)
;;

(* [earlier] ends
   with an Assistant that issued a call whose Tool answer has not been
   recorded yet — the checkpoint captured a dangling tool cycle at the turn
   boundary, exactly the shape [Keeper_transcript_unit]'s [protected_suffix]
   exists to handle elsewhere. On request 1 (before the answer exists)
   [first_atom_at_or_after] returns one value; once the answer lands on
   request 2, it returns a different one. Confirm the drift is real, then
   confirm it is inert: the disputed atom has no [ToolResult] content on the
   request where the value differs, so [plan] demotes the same set either
   way, and the completed atom is never split once it exists. *)
let a_split_atom_at_the_boundary_never_gets_demoted_half () =
  let earlier =
    history_with_tool_bodies [ String.make 4_000 'e' ] @ [ assistant "dangling call" ]
  in
  let dangling_result = tool_message ~id:"dangling" (String.make 4_000 'd') in
  let boundary = List.length earlier in
  let messages_request_1 = earlier in
  let messages_request_2 = earlier @ [ dangling_result ] in
  let demote_before_1 =
    Window.first_atom_at_or_after messages_request_1 ~message_index:boundary
  in
  let demote_before_2 =
    Window.first_atom_at_or_after messages_request_2 ~message_index:boundary
  in
  Alcotest.(check bool)
    "the boundary value does drift across the dangling call"
    true
    (demote_before_1 <> demote_before_2);
  let planned_1 =
    Demotion.plan ~measure_message_bytes ~demote_before:demote_before_1 messages_request_1
  in
  let planned_2 =
    Demotion.plan ~measure_message_bytes ~demote_before:demote_before_2 messages_request_2
  in
  Alcotest.(check int)
    "request 1 has nothing demotable at the disputed atom yet"
    1
    (List.length planned_1.Demotion.pending);
  Alcotest.(check int)
    "request 2 demotes the same count once the answer exists"
    1
    (List.length planned_2.Demotion.pending);
  Alcotest.(check bool)
    "the completed dangling call survives verbatim, not split"
    true
    (List.exists
       (String.equal (String.make 4_000 'd'))
       (markers planned_2.Demotion.messages))
;;

(* --- 1. Bound soundness (RFC-0363 §6 test 2) -------------------------- *)

(* The placeholder must bound the real marker for every byte range, because
   [encode_for_agent_core] renders the preview with [%S] — bytes outside 0x20-0x7E
   expand fourfold — and the JSON encoder then escapes those escapes. A Korean
   body and a body of raw high bytes are the cases that broke the RFC's first
   draft, where the bound was stated as a flat 200-300 bytes. *)
let bound_holds_for body_label body =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let messages = history_with_tool_bodies [ body ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  match planned.Demotion.pending with
  | [] ->
    (* Not demoted: the only admissible reason is that the placeholder did not
       shrink the message, which is itself the bound holding. *)
    ()
  | pending ->
    let planned_bytes =
      List.fold_left
        (fun acc m -> acc + measure_message_bytes m)
        0
        planned.Demotion.messages
    in
    let outcome =
      Demotion.materialize ~store ~pending planned.Demotion.messages
    in
    Alcotest.(check int)
      (body_label ^ ": no revert in a healthy store")
      0
      outcome.Demotion.reverted;
    let real_bytes =
      List.fold_left
        (fun acc m -> acc + measure_message_bytes m)
        0
        outcome.Demotion.messages
    in
    Alcotest.(check bool)
      (Printf.sprintf
         "%s: materialized (%d) must not exceed the planned bound (%d)"
         body_label
         real_bytes
         planned_bytes)
      true
      (real_bytes <= planned_bytes)
;;

(* Guard against a vacuous suite. Every assertion below is of the form "the
   demoted form is no larger" or "this shape is not demoted", and all of them
   hold trivially if [plan] never demotes anything. One case must therefore
   assert the positive direction: a 4,000-byte ASCII body is far larger than
   any marker, so it must be demoted, and the demotion must actually shrink
   the transmitted bytes. *)
let demotion_actually_happens () =
  let body = String.make 4000 'a' in
  let messages = history_with_tool_bodies [ body ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "a 4KB ASCII tool body is demoted"
    1
    (List.length planned.Demotion.pending);
  let before =
    List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
  in
  let after =
    List.fold_left
      (fun acc m -> acc + measure_message_bytes m)
      0
      planned.Demotion.messages
  in
  Alcotest.(check bool)
    (Printf.sprintf "and it shrinks the transmitted view (%d -> %d)" before after)
    true
    (after < before);
  Alcotest.(check bool)
    "the body is gone from the transmitted view"
    false
    (List.exists (fun c -> String.equal c body) (markers planned.Demotion.messages))
;;

let bound_is_sound () =
  bound_holds_for "ascii" (String.make 4000 'a');
  bound_holds_for "korean" (String.concat "" (List.init 500 (fun _ -> "한국어 실측 ")));
  bound_holds_for
    "all-byte-values"
    (String.init 4000 (fun i -> Char.chr (i mod 256)));
  bound_holds_for "newlines" (String.concat "\n" (List.init 800 (fun i -> string_of_int i)))
;;

(* --- 2. content_blocks = Some is excluded (§6 test 3) ------------------ *)

(* When [content_blocks] is [Some], the provider encoder emits the blocks and
   never serializes [content]. Demoting it would free nothing while the plan
   credited a saving — an under-estimate, the direction that lets a
   materialized request exceed the cap. *)
let structured_results_are_not_demoted () =
  let body = String.make 4000 'a' in
  let blocks = Some [ Types.Text "structured" ] in
  let messages = [ assistant "call"; tool_message ~content_blocks:blocks ~id:"c0" body ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "structured tool result yields no pending demotion"
    0
    (List.length planned.Demotion.pending);
  Alcotest.(check (list string))
    "its body is untouched"
    [ body ]
    (markers planned.Demotion.messages)
;;

(* --- 3. Invalid markers are excluded (§6 test 4) ----------------------- *)

(* A marker-shaped payload that fails to parse must not be stored: giving a
   corrupt body a permanent content address hides the corruption instead of
   leaving it visible. *)
let invalid_markers_are_not_demoted () =
  let corrupt = Tool_output.marker_prefix ^ " sha256=not-a-digest bytes=x]" in
  Alcotest.(check bool)
    "fixture really is marker-shaped"
    true
    (Tool_output.is_marker corrupt);
  (match Tool_output.decode_from_agent_core corrupt with
   | Tool_output.Invalid_marker _ -> ()
   | Tool_output.Not_marker | Tool_output.Decoded _ ->
     Alcotest.fail "fixture must decode as Invalid_marker");
  let messages = history_with_tool_bodies [ corrupt ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "corrupt marker yields no pending demotion"
    0
    (List.length planned.Demotion.pending)
;;

(* --- 4. Already-demoted results are not re-stored ---------------------- *)

let stored_results_are_not_demoted_again () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let marker =
    Tool_output.encode_for_agent_core
      (Tool_blob_store.put store ~bytes:(String.make 4000 'a') ~mime:"text/plain")
  in
  let messages = history_with_tool_bodies [ marker ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "an existing marker is not demoted again"
    0
    (List.length planned.Demotion.pending)
;;

(* --- 5. Atoms retained by the raw cut keep their bodies ---------------- *)

let raw_cut_retained_atoms_are_verbatim () =
  let old_body = String.make 4000 'a' in
  let retained_body = String.make 4000 'b' in
  let messages = history_with_tool_bodies [ old_body; retained_body ] in
  let planned = Demotion.plan ~measure_message_bytes ~demote_before:1 messages in
  Alcotest.(check int)
    "only the atom below the raw cut is demoted"
    1
    (List.length planned.Demotion.pending);
  Alcotest.(check bool)
    "the raw-cut-retained body stays verbatim"
    true
    (List.exists
       (fun content -> String.equal content retained_body)
       (markers planned.Demotion.messages))
;;

(* --- 6. [plan] honours whatever boundary it is handed ------------------- *)

let plan_honours_a_monotonic_boundary () =
  let body = String.make 4000 'a' in
  let build atoms =
    List.concat
      (List.init atoms (fun i ->
         [ assistant (Printf.sprintf "call %d" i)
         ; tool_message ~id:(Printf.sprintf "c%d" i) body
         ]))
  in
  let bytes messages =
    List.fold_left (fun total message -> total + measure_message_bytes message) 0 messages
  in
  (* Sixty atoms plus slack for the fixed preamble fit; a sixty-first 4KB
     result does not. The authoritative cut must therefore stay at 60 while
     the raw suffix grows from 10 through 60 atoms, then jump to 120. *)
  let capacity_bytes = bytes (build Window.atoms_per_window) + 1024 in
  let projected atoms =
    let messages = build atoms in
    match
      Window.project_with_drop
        ~measure_message_bytes
        ~capacity_bytes
        ~reserved_bytes:0
        messages
    with
    | Error error ->
      Alcotest.fail (Window.budget_error_to_string error)
    | Ok raw ->
      let planned =
        Demotion.plan
          ~measure_message_bytes
          ~demote_before:raw.dropped_atoms
          messages
      in
      raw.dropped_atoms, List.length planned.Demotion.pending
  in
  let first_cut = Window.atoms_per_window in
  List.iter
    (fun atoms ->
       let dropped, demoted = projected atoms in
       Alcotest.(check int)
         (Printf.sprintf "raw cut stays fixed at %d atoms" atoms)
         first_cut
         dropped;
       Alcotest.(check int)
         (Printf.sprintf "demotion stays anchored at %d atoms" atoms)
         first_cut
         demoted)
    [ first_cut + 10; first_cut + 11; first_cut + 27; first_cut * 2 ];
  let dropped, demoted = projected ((first_cut * 2) + 1) in
  Alcotest.(check int) "raw cut advances by one window" (first_cut * 2) dropped;
  Alcotest.(check int)
    "demotion advances only with that raw cut"
    (first_cut * 2)
    demoted
;;

(* 길이를 재려고 메시지를 문자열로 만들던 것을 재사용 버퍼로 바꿨다
   ([message_measurer]). [Yojson.Safe.to_string] 이 곧 [to_buffer] 다음
   [Buffer.contents] 이므로 바이트 수가 같아야 한다. 이스케이프가 필요한 문자와
   멀티바이트에서 특히 그렇고, 버퍼를 비우지 않으면 두 번째 측정부터 커진다. *)
let measurer_counts_the_same_bytes_as_to_string () =
  let measure =
    Masc.Keeper_turn_driver_try_provider.For_testing.message_measurer ()
  in
  let cases =
    [ "empty body", assistant ""
    ; "plain ascii", assistant "a plain assistant body"
    ; "quotes and backslashes", assistant {|he said "hi\\" and left|}
    ; "control characters", assistant "line\nbreak\ttab\r"
    ; "multibyte", assistant "\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4, emoji \xf0\x9f\x99\x82"
    ; "long tool result", tool_message ~id:"call-long" (String.make 5000 'x')
    ; "short after long", assistant "short"
    ]
  in
  List.iter
    (fun (label, message) ->
       Alcotest.(check int) label (measure_message_bytes message) (measure message))
    cases;
  (* 같은 measurer 로 같은 메시지를 다시 재도 같아야 한다: 버퍼가 쌓이면 깨진다. *)
  let repeated = assistant "measured twice" in
  Alcotest.(check int)
    "a measurer reused on one message"
    (measure repeated)
    (measure repeated)
;;

(* The production pipeline measures the raw history, rewrites only atoms below
   that cut, then measures the planned list. This fixture makes every atom
   eligible so the per-projection identity cache must reuse every candidate
   measurement without retaining independently allocated equal messages. *)
let projection_reuses_candidate_measurements () =
  let bodies = List.init 20 (fun _ -> String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  let raw_measurements = ref 0 in
  let measured message =
    incr raw_measurements;
    measure_message_bytes message
  in
  let measure_message_bytes =
    Masc.Keeper_turn_driver_try_provider.For_testing
    .memoize_message_measurement measured
  in
  let planned =
    Demotion.plan ~measure_message_bytes ~demote_before:max_int messages
  in
  Alcotest.(check int)
    "fixture creates one candidate per aged tool result"
    20
    (List.length planned.Demotion.pending);
  (match
     Window.project
       ~measure_message_bytes
       ~capacity_bytes:max_int
       ~reserved_bytes:0
       planned.Demotion.messages
   with
  | Error error ->
     Alcotest.fail (Window.budget_error_to_string error)
   | Ok _ -> ());
  let expected_unique_measurements =
    List.length messages + List.length planned.Demotion.pending + 1
    (* The window's synthetic preamble. *)
  in
  Alcotest.(check int)
    "each original, candidate, and preamble identity is encoded once"
    expected_unique_measurements
    !raw_measurements
;;

(* --- 7. Last resort: the newest atom does not fit (#28845) ------------- *)

(* The alpha incident shape: parallel WebSearch results joined the assistant
   atom that called them, and that one atom (indivisible to the tail window)
   outgrew the whole history budget. Ordinary demotion cannot help — its
   boundary excludes the current turn (RFC-0351 §4) — so composition refused
   the turn outright. The last-resort path retries the composition once with
   the boundary moved past the newest atom, and the turn's own results leave
   as externalized markers instead of the turn failing. *)
module Try_provider = Masc.Keeper_turn_driver_try_provider

let compose ~base_path ~capacity_bytes ~demote_before messages =
  Try_provider.For_testing.plan_and_window_model_input
    ~measure_message_bytes
    ~capacity_bytes
    ~reserved_bytes:0
    ~base_path
    ~demote_before
    messages
;;

let bytes_of messages =
  List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
;;

let newest_bodies = [ 24_000; 31_000; 47_000; 7_000 ]

let oversized_newest_history () =
  (* Earlier atoms carry tiny bodies, so nothing below the turn boundary is
     demotable and every pending entry the composition produces belongs to the
     newest atom. *)
  let earlier = history_with_tool_bodies [ "tick"; "tock" ] in
  let newest =
    assistant "search batch"
    :: List.mapi
         (fun i size ->
            tool_message
              ~id:(Printf.sprintf "search-%d" i)
              (String.make size (Char.chr (Char.code 'a' + i))))
         newest_bodies
  in
  earlier, earlier @ newest, bytes_of newest
;;

let oversized_newest_atom_is_demoted_as_last_resort () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  (* [capacity] admits the newest atom only demoted: the raw history budget is
     exactly the atom's own bytes, which the charged preamble pushes over. *)
  let capacity_bytes = newest_bytes in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  (match
     Window.project_with_drop
       ~measure_message_bytes
       ~capacity_bytes
       ~reserved_bytes:0
       messages
   with
   | Error (Window.Newest_atom_exceeds_available _) -> ()
   | Error error -> Alcotest.fail (Window.budget_error_to_string error)
   | Ok _ -> Alcotest.fail "fixture must not fit without the last resort");
  match
    compose
      ~base_path:(Filename.temp_dir "demote" "")
      ~capacity_bytes
      ~demote_before
      messages
  with
  | Error error -> Alcotest.fail (Window.budget_error_to_string error)
  | Ok (planned, windowed, history_atom_count) ->
    Alcotest.(check int)
      "each of the newest atom's results is demoted"
      (List.length newest_bodies)
      (List.length planned.Demotion.pending);
    Alcotest.(check int)
      "the denominator is still the whole history"
      3
      history_atom_count;
    let outcome =
      Demotion.materialize ~store ~pending:planned.Demotion.pending windowed.Window.messages
    in
    Alcotest.(check int) "a healthy store reverts nothing" 0 outcome.Demotion.reverted;
    let transmitted = markers outcome.Demotion.messages in
    List.iteri
      (fun i size ->
         let body = String.make size (Char.chr (Char.code 'a' + i)) in
         Alcotest.(check bool)
           (Printf.sprintf "body %d left as a reference, not its bytes" i)
           false
           (List.exists (String.equal body) transmitted))
      newest_bodies;
    Alcotest.(check int)
      "the references are readable blob markers"
      (List.length newest_bodies)
      (List.length (List.filter Tool_output.is_marker transmitted))
;;

(* The last resort is not a blank cheque: an oversized atom with nothing
   demotable in it keeps the typed refusal, with the original measured
   values. *)
let oversized_atom_without_demotable_body_still_refuses () =
  let newest = [ assistant (String.make 50_000 'x') ] in
  let messages = history_with_tool_bodies [ "tick" ] @ newest in
  let capacity_bytes = bytes_of newest in
  match
    compose
      ~base_path:(Filename.temp_dir "demote" "")
      ~capacity_bytes
      ~demote_before:1
      messages
  with
  | Ok _ -> Alcotest.fail "an atom with no tool results cannot be demoted"
  | Error (Window.Newest_atom_exceeds_available { newest_atom_bytes; _ }) ->
    Alcotest.(check int)
      "the refusal carries the atom's real bytes"
      capacity_bytes
      newest_atom_bytes
  | Error error -> Alcotest.fail (Window.budget_error_to_string error)
;;

(* Without a blob store there is nothing a marker could reference, so the
   refusal stands exactly as it did before #28845. *)
let last_resort_requires_a_blob_store () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  match
    compose ~base_path:"" ~capacity_bytes:newest_bytes ~demote_before messages
  with
  | Ok _ -> Alcotest.fail "demotion without a store would dangle its markers"
  | Error (Window.Newest_atom_exceeds_available _) -> ()
  | Error error -> Alcotest.fail (Window.budget_error_to_string error)
;;

(* Demotion can shrink an atom only down to its non-demotable residue. When
   that residue alone exceeds the budget, the last resort still refuses — and
   the refusal must carry the atom's true bytes, not the placeholder-saturated
   measurement the re-cut saw. *)
let still_oversized_after_demotion_reports_true_magnitude () =
  let earlier = history_with_tool_bodies [ "tick" ] in
  let residue = assistant (String.make 50_000 'x') in
  let newest =
    residue
    :: [ tool_message ~id:"big-0" (String.make 4_000 'a')
       ; tool_message ~id:"big-1" (String.make 4_000 'b')
       ]
  in
  let messages = earlier @ newest in
  let _, atom_count = Window.annotate messages in
  (* [plan] is pure, so this probe is exactly the plan the last-resort arm
     computes: it proves the composition took the demotion branch and still
     refused, rather than refusing for want of anything demotable. *)
  let probe =
    Demotion.plan ~measure_message_bytes ~demote_before:atom_count messages
  in
  Alcotest.(check int)
    "the atom carries demotable results, so the last resort planned demotions"
    2
    (List.length probe.Demotion.pending);
  (* [capacity] admits neither the raw atom nor its demoted residue: even the
     assistant text alone overruns the budget once the preamble is charged. *)
  let capacity_bytes = bytes_of [ residue ] in
  match
    compose
      ~base_path:(Filename.temp_dir "demote" "")
      ~capacity_bytes
      ~demote_before:1
      messages
  with
  | Ok _ -> Alcotest.fail "the residue alone exceeds the budget"
  | Error (Window.Newest_atom_exceeds_available { newest_atom_bytes; _ }) ->
    Alcotest.(check int)
      "the refusal carries the atom's true bytes, not the demoted measurement"
      (bytes_of newest)
      newest_atom_bytes
  | Error error -> Alcotest.fail (Window.budget_error_to_string error)
;;

let () =
  Alcotest.run
    "keeper_model_input_demotion"
    [ ( "bound"
      , [ Alcotest.test_case
            "demotion actually fires (suite is not vacuous)"
            `Quick
            demotion_actually_happens
        ; Alcotest.test_case "placeholder bounds the real marker" `Quick bound_is_sound
        ; Alcotest.test_case
            "this turn's results survive the boundary"
            `Quick
            this_turns_results_survive_the_boundary
        ; Alcotest.test_case
            "a turn that produced nothing demotes everything before it"
            `Quick
            a_turn_that_produced_nothing_demotes_everything_before_it
        ; Alcotest.test_case
            "a split atom at the boundary never gets demoted half"
            `Quick
            a_split_atom_at_the_boundary_never_gets_demoted_half
        ] )
    ; ( "exclusions"
      , [ Alcotest.test_case
            "content_blocks = Some is not demoted"
            `Quick
            structured_results_are_not_demoted
        ; Alcotest.test_case
            "invalid markers are not demoted"
            `Quick
            invalid_markers_are_not_demoted
        ; Alcotest.test_case
            "existing markers are not demoted again"
            `Quick
            stored_results_are_not_demoted_again
        ; Alcotest.test_case
            "raw-cut-retained atoms keep their bodies"
            `Quick
            raw_cut_retained_atoms_are_verbatim
        ] )
    ; ( "stability"
      , [ Alcotest.test_case
            "plan honours a monotonic boundary"
            `Quick
            plan_honours_a_monotonic_boundary
        ; Alcotest.test_case
            "projection reuses candidate measurements"
            `Quick
            projection_reuses_candidate_measurements
         ] )
    ; ( "last_resort"
      , [ Alcotest.test_case
            "oversized newest atom is demoted as a last resort"
            `Quick
            oversized_newest_atom_is_demoted_as_last_resort
        ; Alcotest.test_case
            "oversized atom without a demotable body still refuses"
            `Quick
            oversized_atom_without_demotable_body_still_refuses
        ; Alcotest.test_case
            "last resort requires a blob store"
            `Quick
            last_resort_requires_a_blob_store
        ; Alcotest.test_case
            "still oversized after demotion reports the true magnitude"
            `Quick
            still_oversized_after_demotion_reports_true_magnitude
        ] )
    ; ( "measurement"
      , [ Alcotest.test_case
            "the measurer counts the same bytes as to_string"
            `Quick
            measurer_counts_the_same_bytes_as_to_string
        ] )
    ]
;;

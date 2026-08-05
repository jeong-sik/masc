(** Tests for {!Keeper_model_input_demotion} (RFC-0363).

    The load-bearing property is soundness of the size bound: {!Demotion.plan}
    substitutes a placeholder, the window chooses a cut against that
    measurement, and only then are the real markers written. If the
    placeholder ever measures smaller than the marker that replaces it, a
    request that fit the plan exceeds the cap after materialization. Every
    other case here is an input shape that was found — during the RFC's
    adversarial review — to break that direction. *)

module Demotion = Masc.Keeper_model_input_demotion
module Types = Agent_sdk.Types
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

(* --- 1. Bound soundness (RFC-0363 §6 test 2) -------------------------- *)

(* The placeholder must bound the real marker for every byte range, because
   [encode_for_oas] renders the preview with [%S] — bytes outside 0x20-0x7E
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
  (match Tool_output.decode_from_oas corrupt with
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
    Tool_output.encode_for_oas
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

(* --- 6. The demotion boundary moves only with the raw cut -------------- *)

let boundary_moves_only_with_the_raw_cut () =
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

(* The production pipeline first compares original/demoted messages, then
   measures the planned list again to place the byte window. A per-projection
   identity cache must reuse every candidate measurement without retaining
   structurally equal but independently allocated messages. *)
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
  let planned = Demotion.plan ~measure_message_bytes messages in
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
  Alcotest.(check int)
    "each original, candidate, and preamble identity is encoded once"
    122
    !raw_measurements
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
            "demotion boundary moves only with the raw cut"
            `Quick
            boundary_moves_only_with_the_raw_cut
        ; Alcotest.test_case
            "projection reuses candidate measurements"
            `Quick
            projection_reuses_candidate_measurements
         ] )
    ]
;;

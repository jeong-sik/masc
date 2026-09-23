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
      Demotion.materialize
        ~store
        ~addresses:(Demotion.create_address_memo ())
        ~pending
        planned.Demotion.messages
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

(* [materialize] finds each marker's body by its tool_use_id among every
   pending demotion. A lookup that answered with another entry would still
   write a well-formed marker, pointing at another result's bytes, so each
   stored blob is read back and compared with the body its message held. *)
let each_marker_stores_its_own_body () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let bodies = List.init 40 (fun i -> Printf.sprintf "result %d:" i ^ String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  let planned =
    Demotion.plan ~measure_message_bytes ~demote_before:(List.length bodies) messages
  in
  Alcotest.(check int)
    "every aged body is planned"
    (List.length bodies)
    (List.length planned.Demotion.pending);
  let outcome =
    Demotion.materialize
      ~store
      ~addresses:(Demotion.create_address_memo ())
      ~pending:planned.Demotion.pending
      planned.Demotion.messages
  in
  Alcotest.(check int) "no revert in a healthy store" 0 outcome.Demotion.reverted;
  let stored =
    List.map
      (fun content ->
         match Tool_output.decode_from_agent_core content with
         | Tool_output.Decoded reference ->
           (match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "a marker names a blob the store does not hold"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
         | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
           Alcotest.fail "every planned body leaves as a marker")
      (markers outcome.Demotion.messages)
  in
  Alcotest.(check (list string)) "each marker stores its own body" bodies stored
;;

(* Addressing a body is a sha256 over the whole of it; the write is skipped for
   an address this process already wrote, so on a long-lived keeper the hashing
   is all [materialize] does, and doing it on the calling fiber held the main
   Eio domain for 0.7 to 1.6 seconds per provider request (rtev, 2026-09-16).
   With the pool's only worker busy, materialize waits for it. *)
let busy_worker_polls = 50
let busy_worker_poll_interval_s = 0.01

(* A request the memo answers does no pool work at all, so any wait here is the
   regression, not slowness. *)
let memo_hit_budget_s = 5.0

let materialize_addresses_each_body_once_per_attempt () =
  let store = Tool_blob_store.create ~base_path:(Filename.temp_dir "demote" "") in
  let bodies = List.init 8 (fun i -> Printf.sprintf "body %d:" i ^ String.make 4000 'a') in
  let messages = history_with_tool_bodies bodies in
  let planned =
    Demotion.plan ~measure_message_bytes ~demote_before:(List.length bodies) messages
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous)
  @@ fun () ->
  Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  let addresses = Demotion.create_address_memo () in
  let materialize () =
    Demotion.materialize
      ~store
      ~addresses
      ~pending:planned.Demotion.pending
      planned.Demotion.messages
  in
  let first = ref None in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.both
    (fun () -> first := Some (materialize ()))
    (fun () ->
      let rec wait polls =
        if polls > 0 && Option.is_none !first
        then (
          Eio.Time.sleep clock busy_worker_poll_interval_s;
          wait (polls - 1))
      in
      wait busy_worker_polls;
      Alcotest.(check bool)
        "the first request waits for the busy worker"
        true
        (Option.is_none !first);
      Eio.Promise.resolve release_u ());
  let first =
    match !first with
    | None -> Alcotest.fail "materialize never finished"
    | Some outcome -> outcome
  in
  (* The attempt's later requests demote the same aged results. With the
     worker occupied again, a second materialize through the same memo
     finishes anyway: it addressed nothing. *)
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  (* A bounded wait, not an unbounded one: if the memo ever stops answering,
     this call submits a job the occupied worker can never run, and without the
     timeout the suite would hang until CI kills it rather than name the
     regression. *)
  let second =
    match
      Eio.Time.with_timeout clock memo_hit_budget_s (fun () -> Ok (materialize ()))
    with
    | Ok outcome -> outcome
    | Error `Timeout ->
      Eio.Promise.resolve release_u ();
      Alcotest.fail "a second request through the memo waited for the pool"
  in
  Eio.Promise.resolve release_u ();
  let stored outcome =
    List.map
      (fun content ->
         match Tool_output.decode_from_agent_core content with
         | Tool_output.Decoded reference ->
           (match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
            | Ok (Some bytes) -> bytes
            | Ok None -> Alcotest.fail "a marker names a blob the store does not hold"
            | Error error ->
              Alcotest.fail (Tool_blob_store.fetch_error_to_string error))
         | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
           Alcotest.fail "every planned body leaves as a marker")
      (markers outcome.Demotion.messages)
  in
  Alcotest.(check int) "no revert in a healthy store" 0 first.Demotion.reverted;
  Alcotest.(check int) "nor on the second request" 0 second.Demotion.reverted;
  Alcotest.(check (list string)) "each marker stores its own body" bodies (stored first);
  Alcotest.(check (list string)) "and the memo names the same ones" bodies (stored second)
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
    Masc.Keeper_context_core.message_measurer ()
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

(* 요청마다 [Complete_common.transmitted_history] 가 메시지 레코드를 전부 새로
   만든다. live 체크포인트처럼 [name] 과 [tool_call_id] 가 없는 메시지로, 새로
   만든 레코드가 앞 요청의 측정을 그대로 쓰는지 본다. *)
let rebuilt_records_reuse_measurements () =
  let envelope_free role text : Types.message =
    { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
  in
  let history =
    List.init 200 (fun i ->
      envelope_free
        (if i mod 2 = 0 then Types.Assistant else Types.Tool)
        (Printf.sprintf "message %d" i))
  in
  let raw_measurements = ref 0 in
  let measure_message_bytes =
    Masc.Keeper_turn_driver_try_provider.For_testing.memoize_message_measurement
      (fun message ->
         incr raw_measurements;
         measure_message_bytes message)
  in
  let request () =
    List.iter
      (fun (message : Types.message) ->
         ignore (measure_message_bytes { message with content = message.content }))
      history
  in
  request ();
  request ();
  request ();
  Alcotest.(check int)
    "three requests encode each message once"
    (List.length history)
    !raw_measurements
;;

(* 캐시 조회는 해시가 같은 항목을 전부 비교한다. [name] 과 [tool_call_id] 가 없는
   메시지는 content 로만 구분되므로, 해시가 content 를 안 읽으면 역할마다 값이
   하나가 되고 조회가 그 역할의 히스토리 전체를 훑는다. 짧은 id 와 긴 본문 모두
   서로 다른 값이 나와야 한다. *)
let measurement_hash_reads_content () =
  let hash = Masc.Keeper_turn_driver_try_provider.For_testing.message_measurement_hash in
  let distinct messages =
    List.sort_uniq Int.compare (List.map hash messages) |> List.length
  in
  let short_texts = List.init 200 (fun i -> assistant (Printf.sprintf "message %d" i)) in
  let tool_results =
    List.init 200 (fun i ->
      tool_message ~id:(Printf.sprintf "call_%08d" i) (String.make 5000 'x'))
    |> List.map (fun (message : Types.message) -> { message with tool_call_id = None })
  in
  Alcotest.(check int) "short texts" 200 (distinct short_texts);
  Alcotest.(check int) "tool results that differ only by id" 200 (distinct tool_results)
;;

(* The production pipeline measures the raw history, rewrites only atoms below
   that cut, then measures the planned list. This fixture makes every atom
   eligible so the memo must reuse every candidate measurement. *)
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
    "each original, candidate, and preamble is encoded once"
    expected_unique_measurements
    !raw_measurements
;;

(* --- 7. The current turn's results after a size refusal (#28845) -------- *)

(* The alpha incident shape: parallel WebSearch results joined the assistant
   atom that called them, and that one atom (indivisible to the range) was
   refused on its own. Ordinary demotion cannot help — its boundary excludes
   the current turn (RFC-0351 §4) — so the turn was stuck, and a failed turn
   writes no boundary line, so the next turn composed the same range and was
   refused again. After a size refusal the compositions demote every tool
   result the refused request carried, and the same candidate is asked once
   more. *)
module Try_provider = Masc.Keeper_turn_driver_try_provider

let demoted_after_refusal messages =
  Try_provider.Current_turn_demoted
    { refused_atom_count = snd (Window.annotate messages) }
;;

(* The composition carries a range (RFC keeper-context-window-in-tokens
   §10.4), never refuses, and measures the request against nothing;
   [front] is the oldest atom the range starts at and [current_turn_results]
   is what the refusal path decided. *)
let compose ~base_path ~front ~current_turn_results ~demote_before messages =
  let front_digest =
    match Window.atom_opening_digest messages front with
    | Some digest -> digest
    | None -> Alcotest.fail "the front is an atom of the history"
  in
  Try_provider.For_testing.compose_carried_model_input
    ~measure_message_bytes
    ~front:
      (Some
         { Masc.Keeper_carried_front.first_atom = front
         ; front_digest
         ; source = Masc.Keeper_carried_front.Ledger
         })
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results
    ~base_path
    ~demote_before
    ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = demote_before })
    messages
;;

let bytes_of messages =
  List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
;;

(* What the refusal path asks of the refused range: would demoting its tool
   results change it. *)
let demotion_after_refusal ~base_path ~front ~demote_before messages =
  Try_provider.For_testing.current_turn_demotion
    ~refused:
      (compose ~base_path ~front ~current_turn_results:Try_provider.Current_turn_verbatim
         ~demote_before messages)
    ~demoted:
      (compose ~base_path ~front ~current_turn_results:(demoted_after_refusal messages)
         ~demote_before messages)
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

let oversized_newest_atom_is_demoted_after_refusal () =
  let earlier, messages, _ = oversized_newest_history () in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let store = Tool_blob_store.create ~base_path in
  Alcotest.(check (option int)) "the refused range carries demotable results" (Some 3)
    (demotion_after_refusal ~base_path ~front:2 ~demote_before messages);
  (* The range is the newest atom alone, as a walk that evicted every older
     block and a halving that reached one atom leave it. *)
  let composed =
    compose ~base_path ~front:2 ~current_turn_results:(demoted_after_refusal messages)
      ~demote_before messages
  in
  Alcotest.(check int)
    "each of the newest atom's results is demoted"
    (List.length newest_bodies)
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check int)
    "the denominator is still the whole history"
    3
    composed.Try_provider.history_atom_count;
  let outcome =
    Demotion.materialize
      ~store
      ~addresses:(Demotion.create_address_memo ())
      ~pending:composed.Try_provider.planned.Demotion.pending
      composed.Try_provider.projection.Window.messages
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

(* Without a refusal, the current turn's own results stay verbatim whatever
   their size: the boundary excludes them (RFC-0351 §4). *)
let an_ordinary_composition_keeps_the_current_turn_verbatim () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  let demote_before =
    Window.first_atom_at_or_after
      messages
      ~message_index:(List.length earlier)
  in
  let composed =
    compose ~base_path:(Filename.temp_dir "demote" "") ~front:2
      ~current_turn_results:Try_provider.Current_turn_verbatim ~demote_before messages
  in
  Alcotest.(check int) "nothing is demoted" 0
    (List.length composed.Try_provider.planned.Demotion.pending);
  (* A range that starts mid-history goes out with the window's synthetic
     preamble in front of it, so the request is the newest atom verbatim plus
     that one message — not the atom's bytes alone. *)
  let projected = composed.Try_provider.projection.Window.messages in
  let newest = List.filter (fun m -> not (List.mem m earlier)) messages in
  let preamble = List.filter (fun m -> not (List.mem m newest)) projected in
  Alcotest.(check int) "one preamble rides with the range"
    (List.length newest + 1) (List.length projected);
  Alcotest.(check int) "the newest atom goes whole beside the preamble"
    (newest_bytes + bytes_of preamble) composed.Try_provider.transmitted_bytes
;;

(* A refused atom with nothing demotable in it gives the resend nothing to
   change, and the refusal path is told so before a request is spent. *)
let an_atom_without_demotable_body_demotes_nothing () =
  let newest = [ assistant (String.make 50_000 'x') ] in
  let messages = history_with_tool_bodies [ "tick" ] @ newest in
  let base_path = Filename.temp_dir "demote" "" in
  Alcotest.(check (option int)) "nothing to demote" None
    (demotion_after_refusal ~base_path ~front:1 ~demote_before:1 messages);
  let composed =
    compose ~base_path ~front:1 ~current_turn_results:(demoted_after_refusal messages)
      ~demote_before:1 messages
  in
  Alcotest.(check int) "and a demoting composition plans nothing" 0
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check int)
    "the newest atom is what is transmitted"
    (List.length newest + 1 (* the preamble: the kept head is an assistant *))
    (List.length composed.Try_provider.projection.Window.messages)
;;

(* Without a blob store there is nothing a marker could reference. *)
let demotion_after_refusal_requires_a_blob_store () =
  let _, messages, _ = oversized_newest_history () in
  Alcotest.(check (option int)) "nothing to demote without a store" None
    (demotion_after_refusal ~base_path:"" ~front:2 ~demote_before:2 messages);
  let composed =
    compose ~base_path:"" ~front:2 ~current_turn_results:(demoted_after_refusal messages)
      ~demote_before:2 messages
  in
  Alcotest.(check int) "nothing is planned without a store" 0
    (List.length composed.Try_provider.planned.Demotion.pending)
;;

(* A provider that refuses any request carrying more than [window] bytes,
   driven through the refusal path's sequence the way the Agent Core lane
   drives it: the first request composes the range as it is, a size refusal
   asks whether demoting the refused request's results would change it, and
   the resend composes under that decision. [window] is the fake provider's
   limit, not anything masc measures. *)
type sent =
  { mutable compositions : Try_provider.composed list
  ; mutable demoted_through : int list
  }

let drive ?(gate = fun () -> true) ?(refuse_resend = false) ~base_path ~front ~demote_before
      ~window messages =
  let results = ref Try_provider.Current_turn_verbatim in
  let sent = { compositions = []; demoted_through = [] } in
  let overflow =
    Agent_core.Error.Api
      (Agent_core.Retry.ContextOverflow { message = "prompt is too long"; limit = None })
  in
  let attempt () =
    let composed =
      compose ~base_path ~front ~current_turn_results:!results ~demote_before messages
    in
    sent.compositions <- composed :: sent.compositions;
    let refused_after_demotion = refuse_resend && List.length sent.compositions > 1 in
    if composed.Try_provider.transmitted_bytes > window || refused_after_demotion
    then Error overflow
    else Ok composed
  in
  let outcome =
    Try_provider.current_turn_demotion_sequence
      ~same_run_retry_authorized:gate
      ~demotable:(fun () -> demotion_after_refusal ~base_path ~front ~demote_before messages)
      ~demote:(fun _error ~refused_atom_count ->
        sent.demoted_through <- refused_atom_count :: sent.demoted_through;
        results := Try_provider.Current_turn_demoted { refused_atom_count })
      ~first:attempt
      ~resend:attempt
      ()
  in
  outcome, sent
;;

let current_turn_setup () =
  let earlier, messages, newest_bytes = oversized_newest_history () in
  let demote_before =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  messages, demote_before, newest_bytes / 2
;;

let a_refused_turn_resends_its_results_as_markers_once () =
  let messages, demote_before, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent = drive ~base_path ~front:0 ~demote_before ~window messages in
  Alcotest.(check int) "refused, then resent once" 2 (List.length sent.compositions);
  Alcotest.(check (list int)) "demoted through the refused request's atoms" [ 3 ]
    sent.demoted_through;
  (match List.rev sent.compositions with
   | [ refused; resent ] ->
     Alcotest.(check int) "the refused request carried the current turn verbatim" 0
       (List.length refused.Try_provider.planned.Demotion.pending);
     Alcotest.(check bool) "the refused request was over the window" true
       (refused.Try_provider.transmitted_bytes > window);
     Alcotest.(check int) "the range is not narrowed"
       refused.Try_provider.projection.Window.dropped_atoms
       resent.Try_provider.projection.Window.dropped_atoms;
     (* The earlier turns' bodies are too small for a marker to shorten, so
        every planned demotion is one of this turn's results. *)
     Alcotest.(check int) "every current-turn result goes as a marker"
       (List.length newest_bodies)
       (List.length resent.Try_provider.planned.Demotion.pending);
     Alcotest.(check bool) "the resend fits the window" true
       (resent.Try_provider.transmitted_bytes <= window)
   | _ -> Alcotest.fail "two compositions");
  match outcome with
  | Ok accepted ->
    let transmitted =
      markers
        (Demotion.materialize
           ~store:(Tool_blob_store.create ~base_path)
           ~addresses:(Demotion.create_address_memo ())
           ~pending:accepted.Try_provider.planned.Demotion.pending
           accepted.Try_provider.projection.Window.messages)
          .Demotion.messages
    in
    Alcotest.(check int) "the accepted request names each current-turn body by marker"
      (List.length newest_bodies)
      (List.length (List.filter Tool_output.is_marker transmitted))
  | Error _ -> Alcotest.fail "the demoted resend was accepted"
;;

let a_refused_turn_with_nothing_to_demote_is_not_resent () =
  let newest = [ assistant (String.make 50_000 'x') ] in
  let messages = history_with_tool_bodies [ "tick" ] @ newest in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent = drive ~base_path ~front:0 ~demote_before:1 ~window:25_000 messages in
  Alcotest.(check bool) "the refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked once" 1 (List.length sent.compositions);
  Alcotest.(check (list int)) "nothing demoted" [] sent.demoted_through
;;

let a_refused_resend_returns_the_refusal () =
  let messages, demote_before, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent =
    drive ~refuse_resend:true ~base_path ~front:0 ~demote_before ~window messages
  in
  Alcotest.(check bool) "the resend's refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked twice, never a third time" 2 (List.length sent.compositions)
;;

let no_resend_after_a_checkpoint_or_another_error () =
  let messages, demote_before, window = current_turn_setup () in
  let base_path = Filename.temp_dir "demote" "" in
  let outcome, sent =
    drive ~gate:(fun () -> false) ~base_path ~front:0 ~demote_before ~window messages
  in
  Alcotest.(check bool) "the refusal is returned" true (Result.is_error outcome);
  Alcotest.(check int) "asked once after a durable checkpoint" 1 (List.length sent.compositions);
  let asked = ref 0 in
  let rate_limited =
    Try_provider.current_turn_demotion_sequence
      ~same_run_retry_authorized:(fun () -> true)
      ~demotable:(fun () -> Some 3)
      ~demote:(fun _ ~refused_atom_count:_ -> Alcotest.fail "a rate limit demoted")
      ~first:(fun () ->
        incr asked;
        Error
          (Agent_core.Error.Api
             (Agent_core.Retry.RateLimited { retry_after = None; message = "slow down" })))
      ~resend:(fun () -> Alcotest.fail "a rate limit was resent")
      ()
  in
  Alcotest.(check bool) "a rate limit is returned" true (Result.is_error rate_limited);
  Alcotest.(check int) "asked once" 1 !asked
;;

(* A Wide keeper keeps earlier turns verbatim: its ordinary boundary is 0.
   A refused request that carried earlier-turn and current-turn tool results
   demotes only the current turn's: from the turn boundary, or the newest atom
   alone when the boundary could not be read. *)
let only_the_current_turn_is_demoted () =
  let earlier_bodies = [ String.make 20_000 'e'; String.make 21_000 'f' ] in
  let earlier = history_with_tool_bodies earlier_bodies in
  let current =
    assistant "search batch"
    :: List.mapi
         (fun i size ->
            tool_message
              ~id:(Printf.sprintf "search-%d" i)
              (String.make size (Char.chr (Char.code 'a' + i))))
         newest_bodies
  in
  let messages = earlier @ current in
  let turn_start =
    Window.first_atom_at_or_after messages ~message_index:(List.length earlier)
  in
  let base_path = Filename.temp_dir "demote" "" in
  let compose_with turn_boundary =
    Try_provider.For_testing.compose_carried_model_input
      ~input_policy:Masc.Keeper_input_policy.Wide
      ~measure_message_bytes
      ~front:
        (Some
           { Masc.Keeper_carried_front.first_atom = 0
           ; front_digest = Option.get (Window.atom_opening_digest messages 0)
           ; source = Masc.Keeper_carried_front.Ledger
           })
      ~history_digest_at:(Window.atom_opening_digest messages)
      ~current_turn_results:(demoted_after_refusal messages)
      ~base_path
      ~demote_before:0
      ~turn_boundary
      messages
  in
  let composed =
    compose_with (Masc.Keeper_carried_front.Turn_boundary { end_atom = turn_start })
  in
  Alcotest.(check int) "the range still opens on the earlier turns" 0
    composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check int) "the demotion starts at the turn boundary" turn_start
    composed.Try_provider.demote_from;
  Alcotest.(check int) "only the current turn's results are planned"
    (List.length newest_bodies)
    (List.length composed.Try_provider.planned.Demotion.pending);
  let carried = markers composed.Try_provider.projection.Window.messages in
  List.iter
    (fun body ->
       Alcotest.(check bool) "an earlier-turn body goes verbatim" true
         (List.exists (String.equal body) carried))
    earlier_bodies;
  List.iteri
    (fun i size ->
       let body = String.make size (Char.chr (Char.code 'a' + i)) in
       Alcotest.(check bool)
         (Printf.sprintf "current-turn body %d leaves" i)
         false
         (List.exists (String.equal body) carried))
    newest_bodies;
  let unknown =
    compose_with (Masc.Keeper_carried_front.Turn_boundary_unknown { reason = "unreadable" })
  in
  Alcotest.(check int) "an unknown boundary demotes the newest atom alone"
    (snd (Window.annotate messages) - 1)
    unknown.Try_provider.demote_from
;;

(* Demotion can shrink an atom only down to its non-demotable residue. The
   demoted view goes out and the provider judges it. *)
let still_oversized_after_demotion_is_transmitted_demoted () =
  let earlier = history_with_tool_bodies [ "tick" ] in
  let residue = assistant (String.make 50_000 'x') in
  let newest =
    residue
    :: [ tool_message ~id:"big-0" (String.make 4_000 'a')
       ; tool_message ~id:"big-1" (String.make 4_000 'b')
       ]
  in
  let messages = earlier @ newest in
  let composed =
    compose ~base_path:(Filename.temp_dir "demote" "") ~front:1
      ~current_turn_results:(demoted_after_refusal messages) ~demote_before:1 messages
  in
  Alcotest.(check int) "both results were demoted" 2
    (List.length composed.Try_provider.planned.Demotion.pending);
  Alcotest.(check bool) "the demoted view is smaller than the raw atom" true
    (composed.Try_provider.transmitted_bytes < bytes_of newest)
;;

(* A front measured at an atom this history does not have names no atom of
   it: the composition starts over without it and says which seed it dropped
   and why. *)
let a_front_the_history_shrank_under_starts_over () =
  let _, messages, _ = oversized_newest_history () in
  let composed =
    Try_provider.For_testing.compose_carried_model_input
      ~measure_message_bytes
      ~front:
        (Some
           { Masc.Keeper_carried_front.first_atom = 3_100
           ; front_digest = String.make 64 'f'
           ; source = Masc.Keeper_carried_front.Ledger
           })
      ~history_digest_at:(Window.atom_opening_digest messages)
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~base_path:""
      ~demote_before:0
      ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = 0 })
      messages
  in
  Alcotest.(check bool) "everything goes, from the turn start at atom 0" true
    (composed.Try_provider.origin = Masc.Keeper_carried_front.Turn_start { end_atom = 0 });
  Alcotest.(check int) "nothing dropped" 0 composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check bool) "the dropped seed is on record, with the missing atom as its reason" true
    (match composed.Try_provider.outlived_seed with
     | Some (_, Masc.Keeper_carried_front.Front_atom_missing) -> true
     | Some (_, Masc.Keeper_carried_front.Front_message_differs) | None -> false)
;;

(* The history has an atom at the front, but it opens with another message
   than the one the front was measured on: atoms before it were removed. The
   composition starts over and records that reason, not the missing-atom one. *)
let a_front_that_opens_with_another_message_starts_over () =
  let _, messages, _ = oversized_newest_history () in
  let composed =
    Try_provider.For_testing.compose_carried_model_input
      ~measure_message_bytes
      ~front:
        (Some
           { Masc.Keeper_carried_front.first_atom = 1
           ; front_digest = String.make 64 'f'
           ; source = Masc.Keeper_carried_front.Ledger
           })
      ~history_digest_at:(Window.atom_opening_digest messages)
      ~current_turn_results:Try_provider.Current_turn_verbatim
      ~base_path:""
      ~demote_before:0
      ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = 0 })
      messages
  in
  Alcotest.(check bool) "atom 1 exists" true
    (Option.is_some (Window.atom_opening_digest messages 1));
  Alcotest.(check bool) "everything goes, from the turn start at atom 0" true
    (composed.Try_provider.origin = Masc.Keeper_carried_front.Turn_start { end_atom = 0 });
  Alcotest.(check int) "nothing dropped" 0 composed.Try_provider.projection.Window.dropped_atoms;
  Alcotest.(check bool) "the dropped seed is on record, with the other message as its reason" true
    (match composed.Try_provider.outlived_seed with
     | Some (_, Masc.Keeper_carried_front.Front_message_differs) -> true
     | Some (_, Masc.Keeper_carried_front.Front_atom_missing) | None -> false)
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
            "each marker stores its own body"
            `Quick
            each_marker_stores_its_own_body
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
    ; ( "current_turn_after_refusal"
      , [ Alcotest.test_case
            "oversized newest atom is demoted after a refusal"
            `Quick
            oversized_newest_atom_is_demoted_after_refusal
        ; Alcotest.test_case
            "a refused turn resends its results as markers once"
            `Quick
            a_refused_turn_resends_its_results_as_markers_once
        ; Alcotest.test_case
            "only the current turn is demoted"
            `Quick
            only_the_current_turn_is_demoted
        ; Alcotest.test_case
            "a refused turn with nothing to demote is not resent"
            `Quick
            a_refused_turn_with_nothing_to_demote_is_not_resent
        ; Alcotest.test_case
            "the resend is refused too and the refusal stands"
            `Quick
            a_refused_resend_returns_the_refusal
        ; Alcotest.test_case
            "no resend after a durable checkpoint or a non-size error"
            `Quick
            no_resend_after_a_checkpoint_or_another_error
        ; Alcotest.test_case
            "an ordinary composition keeps the current turn verbatim"
            `Quick
            an_ordinary_composition_keeps_the_current_turn_verbatim
        ; Alcotest.test_case
            "an atom without a demotable body demotes nothing"
            `Quick
            an_atom_without_demotable_body_demotes_nothing
        ; Alcotest.test_case
            "demotion after a refusal requires a blob store"
            `Quick
            demotion_after_refusal_requires_a_blob_store
        ; Alcotest.test_case
            "still oversized after demotion is transmitted demoted"
            `Quick
            still_oversized_after_demotion_is_transmitted_demoted
        ; Alcotest.test_case
            "a front the history shrank under starts over"
            `Quick
            a_front_the_history_shrank_under_starts_over
        ; Alcotest.test_case
            "a front that opens with another message starts over"
            `Quick
            a_front_that_opens_with_another_message_starts_over
        ] )
    ; ( "measurement"
      , [ Alcotest.test_case
            "the measurer counts the same bytes as to_string"
            `Quick
            measurer_counts_the_same_bytes_as_to_string
        ; Alcotest.test_case
            "rebuilt records reuse earlier measurements"
            `Quick
            rebuilt_records_reuse_measurements
        ; Alcotest.test_case
            "the measurement hash reads content"
            `Quick
            measurement_hash_reads_content
        ] )
    ; ( "materialize"
      , [ Alcotest.test_case
            "each body is addressed once per attempt, off this domain"
            `Quick
            materialize_addresses_each_body_once_per_attempt
        ] )
    ]
;;

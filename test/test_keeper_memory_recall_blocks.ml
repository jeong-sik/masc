(** The texts a judged turn adds to its context: who gets them, what they say,
    and what a Keeper that gets none costs. The judgment and the store are
    functions the test passes in. *)

open Masc
module Blocks = Keeper_memory_recall_blocks
module Turn = Keeper_memory_recall_turn
module Render = Keeper_memory_recall_render
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module C = Keeper_memory_recall_candidates
module T = Keeper_memory_os_types
module Codec = Keeper_memory_recall_jev_codec
module Eval = Keeper_memory_recall_evaluation
module Types = Typesafeai_types
module Client = Typesafeai_client
module U = Yojson.Safe.Util

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-blocks" ~absolute_turn:3
let now = 1_700_000_000.0
let keeper_id = "recall-blocks-keeper"

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

(* A sentence is found by rendering its fragment, never by copying its words. *)
let fragment key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail -> Alcotest.fail detail

(* ---- facts and judgments ---- *)

let fact claim =
  T.observed ~claim ~category:T.Lesson ~now ~origin:{ T.kind = T.Authored; trace_id = "trace" }

let first = fact "the staging deploy needs a manual approval"
let second = fact "merge only squash"
let facts = [ first; second ]
let id = T.memory_id

let judgment ~first_decision ~turn =
  let results =
    [ J.Decided { id = id first; decision = first_decision }
    ; J.Decided { id = id second; decision = J.Not_needed }
    ]
  in
  match J.reduce ~candidates:results ~turn with
  | Some status -> { Flow.status; results; turn; marks = [ id first, J.Marked J.Standing ] }
  | None -> Alcotest.fail "no candidates"

let carrying_the_first =
  judgment ~first_decision:J.Possibly_needed ~turn:(J.Turn_answered J.Needs_knowledge)

let carrying_nothing =
  judgment ~first_decision:J.Not_needed ~turn:(J.Turn_answered J.Needs_knowledge)

(* ---- the policy ---- *)

let recall scope =
  { Runtime_schema.default_typesafeai with memory_recall = Runtime_schema.Memory_recall_on scope }

let with_policy ?(key = Some "synthetic-jev-key") policy f =
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" key (fun () ->
    Masc_test_deps.with_typesafeai_policy policy f)

(* ---- the stand-ins for the judgment and the store ---- *)

type probe =
  { reads : int ref
  ; judgments : int ref
  ; candidates_seen : string list ref
  }

let probe () = { reads = ref 0; judgments = ref 0; candidates_seen = ref [] }

let reading probe result () =
  incr probe.reads;
  result

let judging probe answer candidates =
  incr probe.judgments;
  probe.candidates_seen := List.map C.id candidates;
  answer

let prepare ?(memory_search_available = true) ~probe ~facts_result ~answer () =
  Blocks.prepare_with
    ~judge:(judging probe answer)
    ~read_facts:(reading probe facts_result)
    ~keeper_id
    ~turn_ref
    ~memory_search_available

let some_or_fail = function
  | Some blocks -> blocks
  | None -> Alcotest.fail "expected texts"

(* ---- who gets the texts ---- *)

let test_a_keeper_that_is_not_judged_reads_nothing_and_asks_nothing () =
  List.iter
    (fun (label, policy) ->
      with_policy policy (fun () ->
        let p = probe () in
        let result =
          prepare ~probe:p ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged carrying_the_first)) ()
        in
        Alcotest.(check bool) (label ^ ": no texts") true (Option.is_none result);
        Alcotest.(check int) (label ^ ": no read") 0 !(p.reads);
        Alcotest.(check int) (label ^ ": no judgment") 0 !(p.judgments)))
    [ "switch off", Runtime_schema.default_typesafeai
    ; "scope names others", recall (Runtime_schema.Listed_keepers ("someone-else", []))
    ]

let test_a_keeper_without_a_key_is_not_judged_either () =
  with_policy ~key:None (recall Runtime_schema.All_keepers) (fun () ->
    let p = probe () in
    let result =
      prepare ~probe:p ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged carrying_the_first)) ()
    in
    Alcotest.(check bool) "no texts" true (Option.is_none result);
    Alcotest.(check int) "no read" 0 !(p.reads);
    Alcotest.(check int) "no judgment" 0 !(p.judgments))

(* The older recall notice has a kill switch for all recall injection. A judged
   Keeper must not get recalled memory text while it is off. *)
let test_the_recall_kill_switch_stops_the_judged_texts () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    Masc_test_deps.with_process_env "MASC_KEEPER_MEMORY_OS_RECALL" (Some "0") (fun () ->
      let p = probe () in
      let result =
        prepare ~probe:p ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged carrying_the_first)) ()
      in
      Alcotest.(check bool) "no texts" true (Option.is_none result);
      Alcotest.(check int) "no read" 0 !(p.reads);
      Alcotest.(check int) "no judgment" 0 !(p.judgments)))

(* ---- what the texts are ---- *)

let test_a_judged_keeper_gets_the_status_and_the_body_the_renderer_makes () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let p = probe () in
    let blocks =
      prepare ~probe:p ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged carrying_the_first)) ()
      |> some_or_fail
    in
    Alcotest.(check string) "the status"
      (Render.status ~memory_search_available:true ~turn_ref carrying_the_first)
      blocks.Blocks.status;
    Alcotest.(check (option string)) "the body"
      (Render.body facts carrying_the_first)
      blocks.Blocks.body;
    Alcotest.(check bool) "the body is there, since a memory was carried" true
      (Option.is_some blocks.Blocks.body);
    Alcotest.(check (list string)) "the judgment saw every fact, in the store's order"
      (List.map id facts) !(p.candidates_seen);
    Alcotest.(check int) "one read" 1 !(p.reads);
    Alcotest.(check int) "one judgment" 1 !(p.judgments))

let test_a_judgment_that_carried_nothing_has_a_status_and_no_body () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let blocks =
      prepare ~probe:(probe ()) ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged carrying_nothing)) ()
      |> some_or_fail
    in
    Alcotest.(check string) "the status"
      (Render.status ~memory_search_available:true ~turn_ref carrying_nothing)
      blocks.Blocks.status;
    Alcotest.(check (option string)) "no body" None blocks.Blocks.body)

let test_the_search_tool_being_offered_reaches_the_status () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let status ~memory_search_available =
      (prepare ~memory_search_available ~probe:(probe ()) ~facts_result:(Ok facts)
         ~answer:(Ok (Turn.Judged carrying_nothing)) ()
       |> some_or_fail).Blocks.status
    in
    Alcotest.(check string) "offered"
      (Render.status ~memory_search_available:true ~turn_ref carrying_nothing)
      (status ~memory_search_available:true);
    Alcotest.(check string) "not offered"
      (Render.status ~memory_search_available:false ~turn_ref carrying_nothing)
      (status ~memory_search_available:false))

(* A retry in the turn gets the judgment the turn kept, and reads the facts
   again: the store may have changed in between. *)
let test_a_kept_judgment_is_worded_from_the_facts_read_now () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let blocks =
      prepare ~probe:(probe ()) ~facts_result:(Ok [ second ])
        ~answer:(Ok (Turn.Judged carrying_the_first)) ()
      |> some_or_fail
    in
    Alcotest.(check (option string)) "the body names the memory that is gone"
      (Render.body [ second ] carrying_the_first)
      blocks.Blocks.body;
    Alcotest.(check bool) "and is a body, not a failure" true (Option.is_some blocks.Blocks.body))

(* ---- when there is nothing to say ---- *)

let test_nothing_to_judge_and_a_judgment_that_is_off_give_no_texts () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    List.iter
      (fun (label, answer) ->
        let result = prepare ~probe:(probe ()) ~facts_result:(Ok facts) ~answer () in
        Alcotest.(check bool) label true (Option.is_none result))
      [ "nothing to judge", Ok Turn.Nothing_to_judge
      ; "off", Ok (Turn.Off Typesafeai_config.Memory_recall_disabled)
      ])

let test_facts_that_cannot_be_read_give_no_texts_and_no_judgment () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let p = probe () in
    let result =
      prepare ~probe:p ~facts_result:(Error "unreadable") ~answer:(Ok (Turn.Judged carrying_the_first)) ()
    in
    Alcotest.(check bool) "no texts" true (Option.is_none result);
    Alcotest.(check int) "it read" 1 !(p.reads);
    Alcotest.(check int) "and asked nothing" 0 !(p.judgments))

let test_a_request_that_cannot_be_built_gives_no_texts () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    List.iter (fun error ->
      let result = prepare ~probe:(probe ()) ~facts_result:(Ok facts) ~answer:(Error error) () in
      Alcotest.(check bool) "no status or fabricated decision" true (Option.is_none result))
      [Codec.Duplicate_candidate_id (id first); Codec.Guidance_unavailable "missing managed recall policy"])

(* The recall must not end the turn it is meant to help: whatever raises in it
   is logged and the Keeper goes on without the texts. *)
let prepare_raising ?(judge = fun _ -> Ok Turn.Nothing_to_judge) ~read_facts () =
  Blocks.prepare_with ~judge ~read_facts ~keeper_id ~turn_ref ~memory_search_available:true

let test_something_that_raises_gives_no_texts_and_does_not_end_the_turn () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    Alcotest.(check bool) "the read raises" true
      (Option.is_none (prepare_raising ~read_facts:(fun () -> failwith "lock timeout") ()));
    Alcotest.(check bool) "the judgment raises" true
      (Option.is_none
         (prepare_raising
            ~judge:(fun _ -> failwith "client crashed")
            ~read_facts:(fun () -> Ok facts)
            ())))

(* A cancellation belongs to the turn that is being stopped; swallowing it
   would keep a stopped turn running. *)
let test_a_cancellation_is_the_turns_own_and_is_raised_again () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let cancelled = Eio.Cancel.Cancelled (Failure "turn stopped") in
    Alcotest.check_raises "from the read" cancelled (fun () ->
      ignore (prepare_raising ~read_facts:(fun () -> raise cancelled) ()));
    Alcotest.check_raises "from the judgment" cancelled (fun () ->
      ignore (prepare_raising ~judge:(fun _ -> raise cancelled) ~read_facts:(fun () -> Ok facts) ())))

(* ---- the prompt blocks ---- *)

let test_the_texts_become_the_two_prompt_blocks () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    let blocks_of judgment =
      prepare ~probe:(probe ()) ~facts_result:(Ok facts) ~answer:(Ok (Turn.Judged judgment)) ()
      |> some_or_fail
    in
    let carrying = blocks_of carrying_the_first in
    (match carrying.Blocks.body, Blocks.prompt_blocks carrying with
     | Some body, [ (status_block, status); (body_block, text) ] ->
       Alcotest.(check string) "the status line is the status block" "recalled_memory_status"
         (Prompt_block_id.to_string status_block);
       Alcotest.(check string) "with the status text" carrying.Blocks.status status;
       Alcotest.(check string) "the body is the memory block" "recalled_memory"
         (Prompt_block_id.to_string body_block);
       Alcotest.(check string) "with the body text" body text
     | _ -> Alcotest.fail "expected the status block, then the body block");
    let nothing = blocks_of carrying_nothing in
    match Blocks.prompt_blocks nothing with
    | [ (status_block, status) ] ->
      Alcotest.(check string) "a judgment that carried nothing has only the status block"
        "recalled_memory_status" (Prompt_block_id.to_string status_block);
      Alcotest.(check string) "with its text" nothing.Blocks.status status
    | blocks -> Alcotest.failf "expected one block, got %d" (List.length blocks))

(* ---- the purpose and the store ---- *)

let test_the_purpose_is_the_input_the_instructions_and_the_turn_and_nothing_else () =
  let purpose =
    Blocks.purpose ~current_input:"review the open pull request" ~keeper_instructions:"be brief" ~turn_ref
  in
  Alcotest.(check (list string)) "the keys"
    [ "current_input"; "keeper_instructions"; "turn_ref" ]
    (List.sort String.compare (List.map fst (U.to_assoc purpose)));
  Alcotest.(check string) "the input" "review the open pull request"
    (U.to_string (U.member "current_input" purpose));
  Alcotest.(check string) "the instructions" "be brief"
    (U.to_string (U.member "keeper_instructions" purpose));
  Alcotest.(check bool) "the turn" true
    (Yojson.Safe.equal (Ids.Turn_ref.to_yojson turn_ref) (U.member "turn_ref" purpose))

let with_keepers_dir f =
  Eio_main.run @@ fun _env ->
  let path = Filename.temp_dir "memory-recall-blocks-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)

let claims facts = List.map (fun (fact : T.fact) -> fact.claim) facts

let test_the_facts_are_read_from_the_snapshot_and_a_keeper_without_one_has_none () =
  with_keepers_dir (fun keepers_dir ->
    (match Blocks.read_facts ~keepers_dir ~keeper_id with
     | Ok [] -> ()
     | Ok _ -> Alcotest.fail "a Keeper with no snapshot has no facts"
     | Error detail -> Alcotest.failf "no snapshot is not an error: %s" detail);
    (match
       Keeper_memory_os_current.replace
         ~keepers_dir
         ~keeper_id
         ~expected_revision:None
         ~now
         ~source:{ Keeper_memory_os_current.kind = Keeper_memory_os_current.Explicit_write; trace_id = "trace" }
         ~facts
         ()
     with
     | Ok _ -> ()
     | Error detail -> Alcotest.failf "the snapshot could not be stored: %s" detail);
    match Blocks.read_facts ~keepers_dir ~keeper_id with
    | Ok read ->
      Alcotest.(check (list string)) "the stored facts, by claim"
        (List.sort String.compare (claims facts))
        (List.sort String.compare (claims read))
    | Error detail -> Alcotest.failf "the snapshot could not be read: %s" detail)

(* ---- the whole path: a stored snapshot, the real judgment, a scripted client ---- *)

let destination : Client.destination =
  { endpoint = "https://fixture.invalid/evaluate"; model = "fixture"; api_key = "private-fixture-key" }

let choice label probabilities =
  Types.Choice_answer { choice = label; probabilities; confidence = 0.9 }

let possibly = choice "possibly_needed" [ "possibly_needed", 0.8; "not_needed", 0.2 ]
let unrelated = choice "not_needed" [ "possibly_needed", 0.3; "not_needed", 0.7 ]
let yes = choice "yes" [ "yes", 0.7; "no", 0.2; "unsure", 0.1 ]
let standing = choice "standing" [ "standing", 0.9; "time_bound", 0.1 ]

let evaluated answers : Client.evaluated =
  { response =
      { Types.model = "jev-fixture"
      ; answers
      ; usage = Some { Types.input_tokens = 12; output_tokens = 3 }
      }
  ; destination = Client.identify destination
  ; request_body_sha256 = "fixture-request"
  ; passed_over = []
  }

(* The client answers by the shape of the request: this stands in for Jev. It
   carries the candidate [carried]. *)
let scripted ~carried ~destinations:_ ~state ~questions () =
  let is_candidate_question =
    match state with
    | `Assoc fields -> List.mem_assoc "purpose" fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
  in
  let is_turn_question = List.map fst questions = [ "turn" ] in
  let answer (question_id, _) =
    question_id,
    if is_turn_question then yes
    else if is_candidate_question then (if String.equal question_id carried then possibly else unrelated)
    else standing
  in
  Ok (evaluated (List.map answer questions))

let with_directories f =
  Eio_main.run @@ fun _env ->
  let base = Filename.temp_dir "memory-recall-blocks-base-" "" in
  let keepers_dir = Filename.temp_dir "memory-recall-blocks-keepers-" "" in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.remove_tree base;
      Fs_compat.remove_tree keepers_dir)
    (fun () -> f (Workspace.default_config base) keepers_dir)

let store ~keepers_dir facts =
  match
    Keeper_memory_os_current.replace
      ~keepers_dir
      ~keeper_id
      ~expected_revision:None
      ~now
      ~source:{ Keeper_memory_os_current.kind = Keeper_memory_os_current.Explicit_write; trace_id = "trace" }
      ~facts
      ()
  with
  | Ok _ -> ()
  | Error detail -> Alcotest.failf "the snapshot could not be stored: %s" detail

let test_a_judged_turn_asks_once_and_a_retry_gets_the_same_status_from_the_facts_it_reads () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    with_directories (fun config keepers_dir ->
      let retry_dir = Filename.temp_dir "memory-recall-blocks-retry-" "" in
      Fun.protect ~finally:(fun () -> Fs_compat.remove_tree retry_dir) (fun () ->
        store ~keepers_dir facts;
        store ~keepers_dir:retry_dir [ second ];
        let requests = ref 0 in
        let call ~destinations ~state ~questions () =
          incr requests;
          scripted ~carried:(id first) ~destinations ~state ~questions ()
        in
        let memo = Turn.create_memo () in
        let purpose =
          Blocks.purpose ~current_input:"review the open pull request" ~keeper_instructions:"be brief" ~turn_ref
        in
        let prepare ~keepers_dir =
          Blocks.prepare_with
            ~judge:
              (Turn.judge_with
                 ~evaluate:(fun record -> Eval.evaluate_with ~call record)
                 ~memo
                 ~config
                 ~keeper_id
                 ~turn_ref
                 ~purpose)
            ~read_facts:(fun () -> Blocks.read_facts ~keepers_dir ~keeper_id)
            ~keeper_id
            ~turn_ref
            ~memory_search_available:true
        in
        let first_call = prepare ~keepers_dir |> some_or_fail in
        let asked = !requests in
        Alcotest.(check bool) "the judgment sent requests" true (asked > 0);
        Alcotest.(check bool) "the status names the carried memory" true
          (contains first_call.Blocks.status (id first));
        Alcotest.(check bool) "and not the one left out" false
          (contains first_call.Blocks.status (id second));
        (match first_call.Blocks.body with
         | Some body ->
           Alcotest.(check bool) "the body holds the carried claim" true (contains body first.claim);
           Alcotest.(check bool) "and not the other" false (contains body second.claim)
         | None -> Alcotest.fail "the carried memory has a body");
        (* A retry in the same turn: the store no longer holds the carried memory. *)
        let retry = prepare ~keepers_dir:retry_dir |> some_or_fail in
        Alcotest.(check int) "the turn's judgment is given back without a request" asked !requests;
        Alcotest.(check string) "the same status" first_call.Blocks.status retry.Blocks.status;
        match retry.Blocks.body with
        | Some body ->
          Alcotest.(check bool) "the body names the memory the store lost" true
            (contains body (fragment Prompt_names.keeper_recall_body_omitted [ "ids", id first ]));
          Alcotest.(check bool) "and shows none of its claim" false (contains body first.claim)
        | None -> Alcotest.fail "a retry still has a body, naming the memory that is gone")))

(* The client puts a time limit on a request only with a clock, so a judged
   Keeper with none sends nothing. This test runs outside the server, where the
   Eio context holds no clock. *)
let test_a_judged_keeper_without_a_clock_gets_no_texts () =
  with_policy (recall Runtime_schema.All_keepers) (fun () ->
    with_directories (fun config keepers_dir ->
      Alcotest.(check bool) "the test has no ambient clock" true
        (Option.is_none (Eio_context.get_clock_opt ()));
      store ~keepers_dir facts;
      let result =
        Blocks.prepare
          ~memo:(Turn.create_memo ())
          ~config
          ~keepers_dir
          ~keeper_id
          ~turn_ref
          ~purpose:(Blocks.purpose ~current_input:"review" ~keeper_instructions:"be brief" ~turn_ref)
          ~memory_search_available:true
      in
      Alcotest.(check bool) "no texts" true (Option.is_none result)))

let () =
  Alcotest.run "keeper_memory_recall_blocks"
    [ ( "who gets the texts"
      , [ Alcotest.test_case "a keeper that is not judged reads nothing and asks nothing" `Quick
            test_a_keeper_that_is_not_judged_reads_nothing_and_asks_nothing
        ; Alcotest.test_case "a keeper without a key is not judged either" `Quick
            test_a_keeper_without_a_key_is_not_judged_either
        ; Alcotest.test_case "the recall kill switch stops the judged texts" `Quick
            test_the_recall_kill_switch_stops_the_judged_texts
        ] )
    ; ( "what the texts are"
      , [ Alcotest.test_case "a judged keeper gets the status and the body the renderer makes" `Quick
            test_a_judged_keeper_gets_the_status_and_the_body_the_renderer_makes
        ; Alcotest.test_case "a judgment that carried nothing has a status and no body" `Quick
            test_a_judgment_that_carried_nothing_has_a_status_and_no_body
        ; Alcotest.test_case "the search tool being offered reaches the status" `Quick
            test_the_search_tool_being_offered_reaches_the_status
        ; Alcotest.test_case "a kept judgment is worded from the facts read now" `Quick
            test_a_kept_judgment_is_worded_from_the_facts_read_now
        ] )
    ; ( "when there is nothing to say"
      , [ Alcotest.test_case "nothing to judge and a judgment that is off give no texts" `Quick
            test_nothing_to_judge_and_a_judgment_that_is_off_give_no_texts
        ; Alcotest.test_case "facts that cannot be read give no texts and no judgment" `Quick
            test_facts_that_cannot_be_read_give_no_texts_and_no_judgment
        ; Alcotest.test_case "a request that cannot be built gives no texts" `Quick
            test_a_request_that_cannot_be_built_gives_no_texts
        ; Alcotest.test_case "something that raises gives no texts and does not end the turn" `Quick
            test_something_that_raises_gives_no_texts_and_does_not_end_the_turn
        ; Alcotest.test_case "a cancellation is the turn's own and is raised again" `Quick
            test_a_cancellation_is_the_turns_own_and_is_raised_again
        ] )
    ; ( "the prompt blocks"
      , [ Alcotest.test_case "the texts become the two prompt blocks" `Quick
            test_the_texts_become_the_two_prompt_blocks
        ] )
    ; ( "the purpose and the store"
      , [ Alcotest.test_case "the purpose is the input, the instructions and the turn and nothing else" `Quick
            test_the_purpose_is_the_input_the_instructions_and_the_turn_and_nothing_else
        ; Alcotest.test_case "the facts are read from the snapshot and a keeper without one has none" `Quick
            test_the_facts_are_read_from_the_snapshot_and_a_keeper_without_one_has_none
        ] )
    ; ( "the whole path"
      , [ Alcotest.test_case "a judged turn asks once and a retry gets the same status from the facts it reads" `Quick
            test_a_judged_turn_asks_once_and_a_retry_gets_the_same_status_from_the_facts_it_reads
        ; Alcotest.test_case "a judged keeper without a clock gets no texts" `Quick
            test_a_judged_keeper_without_a_clock_gets_no_texts
        ] )
    ]

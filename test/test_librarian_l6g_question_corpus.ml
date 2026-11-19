(* L6g synthetic corpus & prompt integration built directly through L6c's
   [Librarian_question.make] (RFC librarian-call-only-proposes §5.5, §6.1, §6.2;
   #53578 L6c; #53538).

   Unlike the standalone corpus atop main, this test renders the real
   [config/prompts/librarian.ask.md] via [Prompt_registry] as [lane.prompt],
   passes structured [Librarian_read_unit.t] values into
   [Masc.Librarian_question.make], verifies the exact single-User-message wire
   layout and JSON unit shapes produced for the model, and feeds the resulting
   [question.id] and [question.shown] back into [Librarian_answer],
   [Librarian_plan], and [Librarian_scoring].

   Note on [seen] (#53543): [seen] is merged on [main] but not yet stacked
   into [feat/librarian-l6c-question] (#53578), so [seen] op scoring cases
   wait until the L6 stack rebases atop #53543. *)

open Alcotest
module Question = Masc.Librarian_question
module Question_id = Masc.Librarian_question_id
module Read_result = Masc.Librarian_read_result
module Read_unit = Masc.Librarian_read_unit
module Missing = Masc.Librarian_unit
module Log = Masc.Librarian_log
module Lane = Masc.Librarian_memory_lane
module Answer = Masc.Librarian_answer
module Effects = Masc.Librarian_effects
module Scoring = Masc.Librarian_scoring
module Current = Masc.Keeper_memory_os_current_types
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Digest = Agent_core.Checkpoint_objects
module Agent = Agent_core.Types

let render_ask_prompt () =
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ();
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       match Prompt_registry.render_prompt_template "librarian.ask" [] with
       | Ok rendered -> rendered
       | Error detail -> failf "failed to render librarian.ask: %s" detail)
;;

let make_lane prompt : Lane.question_side =
  { prompt
  ; answer_schema = `Assoc [ "type", `String "object" ]
  ; max_output_tokens = 4096
  ; thinking = Some false
  }
;;

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'c') with
  | Some id -> id
  | None -> fail "test log id must be 32 lowercase hex chars"
;;

let mark closed_messages : Turn_log.mark =
  { trace = "trace-l6g"
  ; closed_messages
  ; session = "session-l6g"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let from_commit ?(working_state = Some "PR release blockers under review") () : Log.line =
  Log.Committed
    { seq = 1
    ; at = 1_763_400_000.0
    ; basis = Digest.digest_of_bytes "before"
    ; after = Digest.digest_of_bytes "after"
    ; revision = 2
    ; cause = Log.Adopt { by = "operator"; observed = Digest.digest_of_bytes "after" }
    ; effects = Effects.empty
    ; turn_log
    ; turn_log_offset = 0
    ; covers_through = Log.Before_first
    ; covered = mark 0
    ; working_state
    }
;;

let reach : Read_result.reach =
  { line = 420; within = Log.Whole; covered = mark 4; turn_log_offset = 512 }
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "trace-l6g" }

let held ?(first_seen = 1_763_400_000.0) ?(category = Types.Fact) claim : Types.fact =
  Types.observed ~claim ~category ~now:first_seen ~origin:authored
;;

let memory_of facts : Current.t =
  { revision = 2
  ; updated_at = 1_763_400_000.0
  ; source = { kind = Current.Librarian; trace_id = "trace-l6g" }
  ; facts
  ; change = { added = []; removed = []; retained = 0; invalidated = [] }
  }
;;

let opened ?(runtime = "glm") () : Read_unit.opened =
  { runtime; task = Turn_log.No_task; stimuli = [] }
;;

let make_question ?(working_state = Some "PR release blockers under review") prompt facts units =
  let lane = make_lane prompt in
  match
    Question.make ~lane ~memory:(memory_of facts)
      ~from:(from_commit ~working_state ())
      ~reach ~trace:"trace-l6g" units
  with
  | Question.Made { question; text } -> question, text
  | Question.Nothing_readable _ -> fail "expected Question.Made for non-empty units"
;;

let extract_trailing_lines prompt text =
  let prefix = prompt ^ "\nquestion: " in
  check bool "User message starts directly with rendered librarian.ask.md + question: line"
    true (String.starts_with ~prefix text);
  let rest = String.sub text (String.length prompt + 1) (String.length text - String.length prompt - 1) in
  match String.split_on_char '\n' (String.trim rest) with
  | [ q; mem; ws; units; q_end ] -> q, mem, ws, units, q_end
  | lines -> failf "expected 5 trailer lines after prompt, got %d" (List.length lines)
;;

let json_after_label label line =
  check bool ("line starts with " ^ label) true (String.starts_with ~prefix:label line);
  let raw = String.sub line (String.length label) (String.length line - String.length label) in
  Yojson.Safe.from_string raw
;;

let answer_json (question : Read_result.question) ?(working_state = "null") ops =
  Printf.sprintf
    {|{"question":%S,"question_end":%S,"working_state":%s,"ops":[%s]}|}
    question.id.front question.id.back working_state (String.concat "," ops)
;;

let score_ok (case : Scoring.case) answer_text =
  match Scoring.score case answer_text with
  | Scoring.Read r -> r
  | Scoring.Thrown_away rej ->
    failf "%s unexpectedly thrown away: %s" case.name (Answer.rejection_kind rej)
;;

let test_question_envelope_and_unit_wire_shapes () =
  let prompt = render_ask_prompt () in
  let existing = held ~category:Types.Constraint "Do not force-push to protected main" in
  let units : Read_unit.t list =
    [ { line = 100
      ; at = 1_763_600_000.0
      ; kind =
          Read_unit.Turn
            { turn = 10
            ; outcome = Turn_log.Completed
            ; opened = opened ()
            ; unattributed = []
            ; own =
                [ { index = 0
                  ; body =
                      Read_unit.Message
                        (Agent.make_message
                           ~origin:Agent.System_context
                           ~role:Agent.User
                           [ Agent.text_block "Recalled Memory: Do not force-push to protected main" ])
                  }
                ; { index = 1
                  ; body = Read_unit.Message (Agent.user_msg "Switch Staging smoke port to 18935 tomorrow")
                  }
                ; { index = 2
                  ; body =
                      Read_unit.Message
                        (Agent.make_message
                           ~role:Agent.Assistant
                           [ Agent.ToolUse { id = "call-9"; name = "health_probe"; input = `Null } ])
                  }
                ; { index = 3
                  ; body =
                      Read_unit.Message
                        (Agent.tool_result_msg ~tool_use_id:"call-9" ~content:"HTTP 200" ())
                  }
                ]
            }
      ; missing = []
      }
    ; { line = 220
      ; at = 1_763_600_120.0
      ; kind =
          Read_unit.Turn
            { turn = 18
            ; outcome = Turn_log.Close_missing
            ; opened = opened ~runtime:"claude_code" ()
            ; unattributed = []
            ; own = [ { index = 0; body = Read_unit.Message (Agent.user_msg "process crashed") } ]
            }
      ; missing = []
      }
    ; { line = 340
      ; at = 1_763_600_240.0
      ; kind =
          Read_unit.Reset
            { cause = Turn_log.Cleared
            ; items = [ { index = 0; body = Read_unit.Message (Agent.user_msg "context cleared") } ]
            }
      ; missing =
          [ Missing.Bundle { bundle = Digest.digest_of_bytes "b"; skip = 0; take = 2 }
          ; Missing.Chat_bytes { from = 10; until = 90 }
          ]
      }
    ]
  in
  let question, text = make_question prompt [ existing ] units in
  let q_line, mem_line, ws_line, units_line, q_end_line = extract_trailing_lines prompt text in
  check string "question line" ("question: " ^ question.id.front) q_line;
  check string "question-end line" ("question-end: " ^ question.id.back) q_end_line;
  let open Yojson.Safe.Util in
  let mem_json = json_after_label "memory: " mem_line |> to_list in
  check int "1 held fact in memory" 1 (List.length mem_json);
  check string "memory fact m1 name" "m1" (List.hd mem_json |> member "name" |> to_string);
  check string "working_state compact json" "PR release blockers under review"
    (json_after_label "working_state: " ws_line |> to_string);
  let units_json = json_after_label "units: " units_line |> to_list in
  check int "3 units emitted" 3 (List.length units_json);
  let u1 = List.nth units_json 0 in
  let u2 = List.nth units_json 1 in
  let u3 = List.nth units_json 2 in
  check string "u1 kind" "turn" (u1 |> member "kind" |> to_string);
  check bool "u1 carries closed_at string" true
    (match u1 |> member "closed_at" with `String s -> String.length s > 0 | _ -> false);
  let u1_own = u1 |> member "own" |> to_list in
  check string "System_context item omits prose and emits runtime_context" "system_context"
    (List.hd u1_own |> member "runtime_context" |> to_string);
  check bool "System_context item omits content field" true
    (List.hd u1_own |> member "content" = `Null);
  check string "u2 Close_missing emits closed_after_admission" "turn"
    (u2 |> member "kind" |> to_string);
  check bool "u2 omits own field" true (u2 |> member "own" = `Null);
  check int "u2 closed_after_admission has 1 item" 1
    (u2 |> member "closed_after_admission" |> to_list |> List.length);
  check string "u3 kind reset" "reset" (u3 |> member "kind" |> to_string);
  check string "u3 cause cleared" "cleared" (u3 |> member "cause" |> to_string);
  check int "u3 missing lists 2 descriptors" 2 (u3 |> member "missing" |> to_list |> List.length)
;;

let test_l6g_corpus_via_librarian_question_make () =
  let prompt = render_ask_prompt () in
  (* 1. Upcoming dated usable-until record preserved before closed_at + new fact added *)
  let f_hold =
    held ~category:Types.Goal "Run soak verification before release cutoff 2026-11-23"
  in
  let u_before_cutoff : Read_unit.t list =
    [ { line = 100
      ; at = 1_763_510_400.0 (* 2025-11-19 style closed timestamp well before cutoff *)
      ; kind =
          Read_unit.Turn
            { turn = 1
            ; outcome = Turn_log.Completed
            ; opened = opened ()
            ; unattributed = []
            ; own = [ { index = 0; body = Read_unit.Message (Agent.user_msg "Pin canary metrics port to 18935") } ]
            }
      ; missing = []
      }
    ]
  in
  let q1, _ = make_question prompt [ f_hold ] u_before_cutoff in
  let c1 : Scoring.case =
    { name = "upcoming_usable_until_via_question_make"
    ; question = q1.id
    ; shown = q1.shown
    ; facts = [ f_hold ]
    ; planted = [ "18935" ]
    ; must_keep = []
    }
  in
  let a1 =
    answer_json q1
      [ {|{"op":"add","claim":"Canary metrics run on port 18935","category":"fact","basis":{"kind":"observed"},"from":["u1"]}|} ]
  in

  (* 2. Completed dated record dropped causally *)
  let f_done = held ~category:Types.Goal "Execute staging deploy by 2026-11-18 and check health" in
  let u_completed : Read_unit.t list =
    [ { line = 140
      ; at = 1_763_600_000.0
      ; kind =
          Read_unit.Turn
            { turn = 2
            ; outcome = Turn_log.Completed
            ; opened = opened ()
            ; unattributed = []
            ; own = [ { index = 0; body = Read_unit.Message (Agent.user_msg "Staging deploy finished green on 2026-11-18") } ]
            }
      ; missing = []
      }
    ]
  in
  let q2, _ = make_question prompt [ f_done ] u_completed in
  let c2 : Scoring.case =
    { name = "completed_usable_until_dropped_causally"
    ; question = q2.id
    ; shown = q2.shown
    ; facts = [ f_done ]
    ; planted = []
    ; must_keep = []
    }
  in
  let a2 =
    answer_json q2 [ {|{"op":"drop","ref":"m1","reason":"u1 completed staging deploy and confirmed green"}|} ]
  in

  (* 3. Cross-category merge preserving progressive aspect + numeric qualifiers *)
  let f_con = held ~category:Types.Constraint "Do not force-push protected main" in
  let f_pref = held ~category:Types.Preference "Team prefers stacked PRs and currently migrating 3/5 lanes" in
  let q3, _ = make_question prompt [ f_con; f_pref ] u_before_cutoff in
  let c3 : Scoring.case =
    { name = "cross_category_progressive_merge"
    ; question = q3.id
    ; shown = q3.shown
    ; facts = [ f_con; f_pref ]
    ; planted = []
    ; must_keep =
        [ Types.memory_id f_con, [ "protected main"; "force-push" ]
        ; Types.memory_id f_pref, [ "stacked PR"; "currently migrating"; "3/5" ]
        ]
    }
  in
  let a3 =
    answer_json q3
      [ {|{"op":"merge","refs":["m1","m2"],"claim":"Do not force-push protected main; use stacked PRs while currently migrating 3/5 lanes","category":"constraint","basis":{"kind":"observed"},"from":["u1"]}|} ]
  in

  (* 4. System_context self-echo without external grounding yields empty ops: [] *)
  let u_echo : Read_unit.t list =
    [ { line = 180
      ; at = 1_763_600_100.0
      ; kind =
          Read_unit.Turn
            { turn = 3
            ; outcome = Turn_log.Completed
            ; opened = opened ()
            ; unattributed = []
            ; own =
                [ { index = 0
                  ; body =
                      Read_unit.Message
                        (Agent.make_message
                           ~origin:Agent.System_context
                           ~role:Agent.User
                           [ Agent.text_block f_con.claim ])
                  }
                ; { index = 1
                  ; body = Read_unit.Message (Agent.assistant_msg "Remembered: do not force-push protected main.")
                  }
                ]
            }
      ; missing = []
      }
    ]
  in
  let q4, _ = make_question prompt [ f_con ] u_echo in
  let c4 : Scoring.case =
    { name = "runtime_context_self_echo_empty_ops"
    ; question = q4.id
    ; shown = q4.shown
    ; facts = [ f_con ]
    ; planted = []
    ; must_keep = []
    }
  in
  let a4 = answer_json q4 [] in

  let results = [ c1, a1; c2, a2; c3, a3; c4, a4 ] in
  let tally =
    Scoring.tally (List.map (fun (c, a) -> c, Scoring.score c a) results)
  in
  check int "4 answers evaluated" 4 tally.answers;
  check (list (pair string int)) "0 thrown away" [] tally.thrown_away;
  check (list (pair string int)) "0 ops left out" [] tally.not_applied;
  check int "all planted recovered (1/1)" tally.planted tally.recovered;
  check int "all merge_kept preserved (5/5)" tally.merge_expected tally.merge_kept;
  let r4 = score_ok c4 a4 in
  check bool "self-echo empty ops makes no Memory changes" false r4.changed;
  (* Guardrail: code-fenced reply rejected as not_json *)
  (match Scoring.score c1 ("```json\n" ^ a1 ^ "\n```") with
   | Scoring.Thrown_away Answer.Not_json -> ()
   | _ -> fail "code fence must be rejected as Not_json");
  (* Guardrail: swapped halves rejected as echo_mismatch *)
  let swapped =
    Printf.sprintf {|{"question":%S,"question_end":%S,"working_state":null,"ops":[]}|}
      q1.id.back q1.id.front
  in
  (match Scoring.score c1 swapped with
   | Scoring.Thrown_away Answer.Echo_mismatch -> ()
   | _ -> fail "swapped id halves must fail Echo_mismatch")
;;

let () =
  run "librarian_l6g_question_corpus"
    [ ( "question_make"
      , [ test_case "L6c Librarian_question.make prompt + unit JSON wire shapes" `Quick
            test_question_envelope_and_unit_wire_shapes
        ; test_case "L6g synthetic corpus round-tripped through Librarian_question.make" `Quick
            test_l6g_corpus_via_librarian_question_make
        ] )
    ]
;;

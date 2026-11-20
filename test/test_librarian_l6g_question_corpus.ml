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

   Note on [seen] (#53543): [seen] is present in the stacked [#53605] base
   ([Librarian_answer] accepts [add]/[seen]/[revise]/[merge]/[drop]), and
   [config/prompts/librarian.ask.md] documents all five ops and
   [test_prompt_contract] verifies the [seen] contract. *)

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
module Plan = Masc.Librarian_plan
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
    ; must_remain = [ "2026-11-23" ]
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
    ; must_remain = []
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
    ; must_remain = [ "protected main"; "currently migrating" ]
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
    ; must_remain = [ "protected main" ]
    }
  in
  let a4 = answer_json q4 [] in

  (* 5. Paired Case A: Keeper says "모른다/정보가 없다" after clear without Memory injection -> preserve all 3 Korean rules *)
  let f_rule1 = held ~category:Types.Constraint "주 브랜치(main)에는 강제 푸시를 금지한다." in
  let f_rule2 = held ~category:Types.Constraint "배포 승인은 두 명 이상의 리뷰 확인 뒤 진행한다." in
  let f_rule3 = held ~category:Types.Constraint "운영 포트 8935와 운영 베이스 경로는 테스트에서 건드리지 않는다." in
  let u_unknowing : Read_unit.t list =
    [ { line = 220
      ; at = 1_763_600_200.0
      ; kind =
          Read_unit.Turn
            { turn = 4
            ; outcome = Turn_log.Completed
            ; opened = opened ~runtime:"ollama" ()
            ; unattributed = []
            ; own =
                [ { index = 0
                  ; body = Read_unit.Message (Agent.user_msg "배포 규칙이 뭐였죠?")
                  }
                ; { index = 1
                  ; body =
                      Read_unit.Message
                        (Agent.assistant_msg "제공된 정보에 배포 규칙이 없어 모릅니다.")
                  }
                ]
            }
      ; missing = []
      }
    ]
  in
  let q5, _ = make_question ~working_state:None prompt [ f_rule1; f_rule2; f_rule3 ] u_unknowing in
  let c5 : Scoring.case =
    { name = "unknowing_keeper_reply_preserves_korean_rules"
    ; question = q5.id
    ; shown = q5.shown
    ; facts = [ f_rule1; f_rule2; f_rule3 ]
    ; planted = []
    ; must_keep = []
    ; must_remain = [ "강제 푸시"; "두 명 이상"; "8935" ]
    }
  in
  let a5 = answer_json q5 [] in
  (* Contrast check: overwriting m1..m3 into English "Provided context lacks..." destroys all 3 constraints *)
  let a5_bad =
    answer_json q5
      [ {|{"op":"revise","ref":"m1","claim":"Provided context lacks deployment rules","category":"constraint","basis":{"kind":"observed"},"from":["u1"]}|}
      ; {|{"op":"revise","ref":"m2","claim":"Provided context lacks approval rules","category":"constraint","basis":{"kind":"observed"},"from":["u1"]}|}
      ; {|{"op":"revise","ref":"m3","claim":"Provided context lacks runtime rules","category":"constraint","basis":{"kind":"observed"},"from":["u1"]}|}
      ]
  in
  (match Answer.of_string ~asked:q5.id a5_bad with
   | Error rej -> failf "bad unknowing answer failed decode: %s" (Answer.rejection_kind rej)
   | Ok decoded_bad ->
     let bad_plan =
       Plan.of_answer ~shown:q5.shown ~facts:[ f_rule1; f_rule2; f_rule3 ]
         ~removed_since:[] ~at:1_763_600_250.0 ~trace_id:"trace-l6g" decoded_bad
     in
     check bool "bad English overwrite erases rule1" false
       (List.exists (fun (f : Types.fact) -> String.equal f.claim f_rule1.claim) bad_plan.facts);
     check bool "bad English overwrite erases rule2" false
       (List.exists (fun (f : Types.fact) -> String.equal f.claim f_rule2.claim) bad_plan.facts);
     check bool "bad English overwrite erases rule3" false
       (List.exists (fun (f : Types.fact) -> String.equal f.claim f_rule3.claim) bad_plan.facts));

  (* 6. Paired Case B: Same 3 Korean rules + explicit operator retraction of m2 and update of m3 *)
  let u_operator_retract : Read_unit.t list =
    [ { line = 260
      ; at = 1_763_600_300.0
      ; kind =
          Read_unit.Turn
            { turn = 5
            ; outcome = Turn_log.Completed
            ; opened = opened ()
            ; unattributed = []
            ; own =
                [ { index = 0
                  ; body =
                      Read_unit.Message
                        (Agent.user_msg
                           "운영자 공지: 두 명 리뷰 규칙(m2)은 철회하고, 격리 포트 범위는 18935~18940으로 바꾼다.")
                  }
                ; { index = 1
                  ; body = Read_unit.Message (Agent.assistant_msg "네, 격리 포트 범위 18935~18940을 확인했고 m2는 철회하겠습니다.")
                  }
                ]
            }
      ; missing = []
      }
    ]
  in
  let q6, _ =
    make_question ~working_state:None prompt [ f_rule1; f_rule2; f_rule3 ] u_operator_retract
  in
  let c6 : Scoring.case =
    { name = "explicit_operator_retraction_updates_korean_rules"
    ; question = q6.id
    ; shown = q6.shown
    ; facts = [ f_rule1; f_rule2; f_rule3 ]
    ; planted = [ "18935~18940" ]
    ; must_keep = []
    ; must_remain = [ "강제 푸시"; "8935" ]
    }
  in
  let a6 =
    answer_json q6
      [ {|{"op":"drop","ref":"m2","reason":"단위 u1에서 운영자가 두 명 리뷰 규칙을 명시적으로 철회함"}|}
      ; {|{"op":"revise","ref":"m3","claim":"운영 포트 8935와 운영 베이스는 건드리지 않으며 격리 포트는 18935~18940을 사용한다.","category":"constraint","basis":{"kind":"observed"},"from":["u1"]}|}
      ]
  in

  let results = [ c1, a1; c2, a2; c3, a3; c4, a4; c5, a5; c6, a6 ] in
  let tally =
    Scoring.tally (List.map (fun (c, a) -> c, Scoring.score c a) results)
  in
  check int "6 answers evaluated" 6 tally.answers;
  check (list (pair string int)) "0 thrown away" [] tally.thrown_away;
  check (list (pair string int)) "0 ops left out" [] tally.not_applied;
  check int "all planted recovered (2/2)" tally.planted tally.recovered;
  check int "all merge_kept preserved (5/5)" tally.merge_expected tally.merge_kept;
  check int "all must_remain preserved" tally.remain_expected tally.remain_kept;
  let r4 = score_ok c4 a4 in
  check bool "self-echo empty ops makes no Memory changes" false r4.changed;
  let r5 = score_ok c5 a5 in
  check bool "unknowing reply empty ops keeps all rules untouched" false r5.changed;
  let r5_bad = score_ok c5 a5_bad in
  check int "bad English overwrite loses all 3 must_remain rules" 0 r5_bad.remain_kept;
  let r6 = score_ok c6 a6 in
  check bool "explicit operator retraction changes Memory" true r6.changed;
  (* Seen op (#53543) round-trip through Answer.of_string + Plan.of_answer *)
  (match Answer.of_string ~asked:q1.id (answer_json q1 [ {|{"op":"seen","ref":"m1","from":["u1"]}|} ]) with
   | Error rej -> failf "valid seen answer rejected: %s" (Answer.rejection_kind rej)
   | Ok decoded_seen ->
     let seen_plan =
       Plan.of_answer ~shown:q1.shown ~facts:[ f_hold ] ~removed_since:[]
         ~at:1_763_600_500.0 ~trace_id:"trace-l6g" decoded_seen
     in
     check int "seen op has 0 not_applied" 0 (List.length seen_plan.effects.not_applied);
     (match seen_plan.facts with
      | [ updated ] ->
        check string "seen keeps memory_id" (Types.memory_id f_hold) (Types.memory_id updated);
        check (float 0.001) "seen preserves first_seen" f_hold.first_seen updated.first_seen;
        check (float 0.001) "seen advances last_seen" 1_763_600_500.0 updated.last_seen
      | facts -> failf "expected 1 fact after seen, got %d" (List.length facts)));
  (match Answer.of_string ~asked:q1.id (answer_json q1 [ {|{"op":"seen","ref":"m1","from":[]}|} ]) with
   | Error (Answer.Schema_violation _) -> ()
   | Error rej -> failf "seen with empty from expected Schema_violation, got %s" (Answer.rejection_kind rej)
   | Ok _ -> fail "seen with empty from must fail Schema_violation");
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

let test_prompt_contract () =
  let contains_substring ~needle haystack = Astring.String.is_infix ~affix:needle haystack in
  let ask_path = Masc_test_deps.source_path "config/prompts/librarian.ask.md" in
  let old_l6_path = Masc_test_deps.source_path "config/prompts/librarian-l6.md" in
  let legacy_path = Masc_test_deps.source_path "config/prompts/librarian.md" in
  check bool "config/prompts/librarian.ask.md exists" true (Sys.file_exists ask_path);
  check bool "old config/prompts/librarian-l6.md removed" false (Sys.file_exists old_l6_path);
  check bool "config/prompts/librarian.md exists" true (Sys.file_exists legacy_path);
  let ask_text = Masc_test_deps.read_file ask_path in
  let legacy_text = Masc_test_deps.read_file legacy_path in
  List.iter
    (fun legacy_token ->
       check bool ("legacy librarian.md retains " ^ legacy_token) true
         (contains_substring ~needle:legacy_token legacy_text))
    [ "new_claims"; "supersedes"; "absorbs"; "working_contexts"; "admission_policy" ];
  List.iter
    (fun wire_or_rule_token ->
       check bool ("librarian.ask.md documents contract token " ^ wire_or_rule_token) true
         (contains_substring ~needle:wire_or_rule_token ask_text))
    [ {|"question"|}
    ; {|"question_end"|}
    ; {|"working_state"|}
    ; {|"ops"|}
    ; {|"ops": []|}
    ; "빈 답 금지 규정을 따르지 않습니다"
    ; {|"add"|}
    ; {|"seen"|}
    ; {|"op": "seen"|}
    ; {|"drop"|}
    ; {|"merge"|}
    ; {|"revise"|}
    ; {|"from": []|}
    ; "자기 발언에서 그대로 인용·되풀이한 것은 새 사실이 아니므로"
    ; "모른다·없다고 한 말은 그 기억을 바꾸거나 지울 근거가 아닙니다"
    ; "수락·응답 문구를 옮겨 적지 말고"
    ; "단위의 언어로"
    ; "중복 행은 새 재확인이 아니라 하나의 관측으로"
    ; "last_seen"
    ; {|"observed"|}
    ; "m1"
    ; "u1"
    ; "closed_at"
    ; "closed_after_admission"
    ; "unattributed"
    ; "runtime_context"
    ; "missing"
    ; "tool_observation"
    ; "no_wall_clock_death"
    ; "상대 날짜"
    ; "절대 날짜"
    ; "진행형"
    ; "한정어"
    ; "곁다리 fact"
    ; "원천에서 다시 얻을 수 있는 세부"
    ; "`claim` 내용 그대로"
    ; "Memory fact 로도 함께 두고"
    ];
  List.iter
    (fun disallowed_token ->
       check bool ("librarian.ask.md omits unsupported/legacy key " ^ disallowed_token) false
         (contains_substring ~needle:disallowed_token ask_text))
    [ {|"new_claims"|}
    ; {|"working_contexts"|}
    ; {|"supersedes"|}
    ; {|"absorbs"|}
    ];
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ();
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       check bool "librarian.ask resolves from File source" true
         (match Prompt_registry.prompt_source "librarian.ask" with
          | Prompt_registry.File -> true
          | Prompt_registry.Override | Prompt_registry.Missing -> false);
       check bool "old librarian-l6 key is Missing" true
         (match Prompt_registry.prompt_source "librarian-l6" with
          | Prompt_registry.Missing -> true
          | Prompt_registry.File | Prompt_registry.Override -> false);
       (match Prompt_registry.render_prompt_template "librarian.ask" [] with
        | Ok rendered ->
          check bool "rendered librarian.ask prompt is non-empty" true
            (String.trim rendered <> "")
        | Error detail -> failf "librarian.ask failed to render: %s" detail);
       let ask_issues =
         Prompt_registry.validate_prompt_templates ()
         |> List.filter (fun (key, (_ : string)) -> String.equal key "librarian.ask")
       in
       check int "librarian.ask has zero undeclared template variables" 0
         (List.length ask_issues))
;;

let () =
  run "librarian_l6g_question_corpus"
    [ ( "question_make"
      , [ test_case "L6c Librarian_question.make prompt + unit JSON wire shapes" `Quick
            test_question_envelope_and_unit_wire_shapes
        ; test_case "L6g synthetic corpus round-tripped through Librarian_question.make" `Quick
            test_l6g_corpus_via_librarian_question_make
        ] )
    ; "prompt_contract", [ test_case "librarian.ask.md wire & registry contract" `Quick test_prompt_contract ]
    ]
;;

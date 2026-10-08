(* [하네스 H2-J — task-2184] 실행 저널(keeper_tool_execution_journal)의
   재개 경계를 관측한다. Board 계약 H2-S1(중복 dispatch 금지)·S2(손상·스키마
   불일치 때 incomplete 유지)의 기계 관측. 판정은 리뷰어·검증자 몫. *)

module Journal = Masc.Keeper_tool_execution_journal
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor
module Descriptor = Masc.Keeper_tool_descriptor
module Timing = Tool_timing

let log fmt =
  Printf.ksprintf (fun s -> print_endline ("H2J " ^ s)) fmt
;;

let stage name = log "STAGE %s" name
;;

let fail message = failwith message
;;

let journal_dir () =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_h2_journal_%d" (Unix.getpid ()))
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error _ -> ()
;;

let fresh_dir_s suffix =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_h2_journal_%d_%s" (Unix.getpid ()) suffix)
  in
  remove_tree dir;
  Unix.mkdir dir 0o755;
  dir
;;

let fresh_dir () = fresh_dir_s "shared"

let request_id = "req-h2-journal-001"

let markers_dir dir = Filename.concat dir "markers"

let effect_file dir = Filename.concat (markers_dir dir) "effects"
;;

let ensure_markers dir =
  if not (Sys.file_exists (markers_dir dir)) then Unix.mkdir (markers_dir dir) 0o755
;;

let marker_lines path =
  match open_in_bin path with
  | exception _ -> []
  | channel ->
    let content = really_input_string channel (in_channel_length channel) in
    close_in channel;
    content |> String.split_on_char '\n' |> List.filter (fun s -> s <> "")
;;

let append_marker path line =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  output_string oc (line ^ "\n");
  close_out oc
;;

let count marker path =
  List.length (List.filter (fun m -> String.equal m marker) (marker_lines path))
;;

(* --- descriptor/plan: H2 하네스와 같은 canonical lane/search 쌍 --- *)

let lane_descriptor () =
  match
    List.find_opt
      (fun d -> String.equal d.Descriptor.id "keeper.lane.status")
      (Descriptor.all_descriptors ())
  with
  | Some d -> d
  | None -> fail "descriptor not found: keeper.lane.status"
;;

let search_descriptor () =
  match
    List.find_opt
      (fun d -> String.equal d.Descriptor.id "masc.board.search")
      (Descriptor.all_descriptors ())
  with
  | Some d -> d
  | None -> fail "descriptor not found: masc.board.search"
;;

let make_plan () =
  let a = match Plan.Node_id.make "lane" with Ok id -> id | Error Empty -> fail "empty id" in
  let b = match Plan.Node_id.make "search" with Ok id -> id | Error Empty -> fail "empty id" in
  let input_a = Plan.Json_template.literal (`Assoc []) in
  let profile_pointer =
    match Plan.Json_pointer.of_string "/profile" with
    | Ok pointer -> pointer
    | Error _ -> fail "pointer syntax rejected"
  in
  let input_b =
    match
      Plan.Json_template.object_
        [ ("query", Plan.Json_template.output ~node_id:a ~pointer:profile_pointer) ]
    with
    | Ok template -> template
    | Error (Duplicate_field field) -> fail ("duplicate field: " ^ field)
  in
  let node_a = Plan.node ~id:a ~tool_name:"keeper_lane_status" ~input:input_a () in
  let node_b = Plan.node ~id:b ~tool_name:"masc_board_search" ~after:[ a ] ~input:input_b () in
  match Plan.create ~descriptors:[ lane_descriptor (); search_descriptor () ] [ node_a; node_b ] with
  | Ok plan -> (plan, a, b)
  | Error error -> fail ("plan: " ^ Plan.error_to_string error)
;;

let node_id_string = Plan.Node_id.to_string

let decision_name = function
  | Journal.Skip_node_settled _ -> "Skip_node_settled"
  | Journal.Redo_node_pre_effect _ -> "Redo_node_pre_effect"
  | Journal.Refuse_unknown_effect _ -> "Refuse_unknown_effect"
  | Journal.Identity_mismatch _ -> "Identity_mismatch"
  | Journal.No_journal -> "No_journal"
;;

(* identity: plan fingerprint(안정 구조 내용)·노드 입력 sha·owner.
   Plan.t 에는 create 때 새로 찍히는 비결정 identity(int 카운터,
   keeper_tool_plan.ml:921)가 있어 Marshal 직렬화는 매번 다른 값을 낸다 —
   fingerprint 는 노드 id·tool 이름·의존성·입력 템플릿의 구조 내용만
   문자열로 모아 해시한다(재시작 뒤 같은 계획 재구성에서도 동일해야 하는
   것이 계약의 취지다). 입력은 실제 resolve 된 JSON 을 해시해 스스로
   결속한다. *)
let digest s = Digest.to_hex (Digest.string s)

let rec template_string (t : Plan.Json_template.t) =
  match t with
  | Literal json -> "literal:" ^ Yojson.Safe.to_string json
  | Output { node_id; pointer } ->
    "output:" ^ Plan.Node_id.to_string node_id ^ ":" ^ Plan.Json_pointer.to_string pointer
  | Param { name } -> "param:" ^ name
  | Object fields ->
    "object:{"
    ^ String.concat ","
        (List.map (fun (name, t) -> name ^ "=" ^ template_string t) fields)
    ^ "}"
  | Array items ->
    "array:[" ^ String.concat "," (List.map template_string items) ^ "]"
;;

let plan_revision_of plan =
  let nodes = Plan.nodes plan in
  let node_string (node : Plan.node) =
    "node:" ^ Plan.Node_id.to_string node.Plan.id
    ^ " tool=" ^ node.Plan.tool_name
    ^ " after=["
    ^ String.concat "," (List.map Plan.Node_id.to_string (Plan.dependencies node))
    ^ "] input=" ^ template_string node.Plan.input
  in
  digest (String.concat "\n" (List.map node_string nodes))
;;

let identity_for ~plan ~input =
  let plan_revision = plan_revision_of plan in
  let input_sha = digest (Yojson.Safe.to_string input) in
  let owner = Sys.getenv_opt "H2J_OWNER" |> Option.value ~default:"h2j-owner-a" in
  { Journal.plan_revision; input_sha; owner }
;;

(* journal_s1: 실제 executor 2회 구동 — 1차는 crash 주입, 2차는 같은
   request_id 의 저널로 재개. 저널 연결부(dispatch 전 begin_node, 정산 후
   settle_node)는 dispatch 내부에서 실제 순서로 통과한다. *)

let run_attempt ~dir ~request_id ~crash_marker ~crash_flag_file =
  let plan, _a, _b = make_plan () in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
    let id = node_id_string node.Plan.id in
    (* 저널: dispatch 전 begin_node. lane 은 readonly 라 dispatch-전 분류가
       Proven_pre_effect(중단 뒤 redo 안전), search 는 효과 가능이라 unknown.
       Skip 면 dispatch 없이 저장 결과로 정산하고, Refuse 면 dispatch 없이
       노드를 실패시킨다 — 효과 불명 단계를 두 번 치지 않는 집행점. *)
    let pre_effect_disposition =
      if String.equal id "lane" then Tool_result.Proven_pre_effect
      else Tool_result.Effect_outcome_unknown
    in
    let identity = identity_for ~plan ~input in
    let journal_decision =
      match
        Journal.begin_node ~dir ~request_id ~node_id:id ~pre_effect_disposition ~identity
      with
      | Ok decision -> decision
      | Error error ->
        log "JOURNAL_BEGIN_ERROR %s — fail closed, refusing to dispatch" id;
        ignore error;
        failwith ("journal unreadable: " ^ id)
    in
    let data =
      if String.equal id "lane" then
        `Assoc
          [ "profile", `String "docker"
          ; "lane", `Null
          ; "endpoint", `Null
          ; "probe", `Null
          ; "last_dispatch", `Null
          ; "operator_action", `Null
          ]
      else `String "p-1 · h2 journal post (by keeper-a, 2026-10-07, +0, 0 replies)"
    in
    (match journal_decision with
     | Journal.Skip_node_settled record ->
       log "JOURNAL_SKIP %s (settled, no re-dispatch)" id;
       ignore record;
       (* 저장 결과로 정산: dispatch·효과 없음. *)
       Executor.dispatch_result
         (Tool_result.make_ok
            ~tool_name:node.Plan.tool_name
            ~start_time:(Timing.start ())
            ~data
            ())
     | Journal.Refuse_unknown_effect record ->
       log "JOURNAL_REFUSE %s (attempting/%s: effect may have landed, no re-dispatch)"
         id
         (Journal.effect_disposition_to_string record.Journal.effect_disposition);
       (* fail-closed: dispatch 없이 노드 실패 → 턴은 incomplete 로 끝난다. *)
       Executor.dispatch_result
         (Tool_result.make_err
            ~tool_name:node.Plan.tool_name
            ~class_:Tool_result.Policy_rejection
            ~start_time:(Timing.start ())
            ~effect_disposition:Tool_result.Effect_outcome_unknown
            ("journal refuses re-dispatch of " ^ id ^ ": effect state unknown"))
     | Journal.Identity_mismatch _ ->
       log "JOURNAL_IDENTITY_MISMATCH %s (this journal is not this request's — no reuse, no dispatch)" id;
       Executor.dispatch_result
         (Tool_result.make_err
            ~tool_name:node.Plan.tool_name
            ~class_:Tool_result.Policy_rejection
            ~start_time:(Timing.start ())
            ~effect_disposition:Tool_result.Effect_outcome_unknown
            ("journal identity mismatch on " ^ id ^ ": plan/input/owner differ"))
     | Journal.Redo_node_pre_effect _ | Journal.No_journal -> (
       log "DISPATCH %s input=%s" id (Yojson.Safe.to_string input);
       append_marker (effect_file dir) ("effect:" ^ id);
       let crash_now =
         match crash_marker with
         | Some marker -> String.equal marker id && Sys.file_exists crash_flag_file
         | None -> false
       in
       if crash_now then (
         Sys.remove crash_flag_file;
         failwith ("h2j crash injection: " ^ id));
       let effect_disposition =
         if String.equal id "lane" then Tool_result.Proven_pre_effect
         else Tool_result.Proven_post_effect
       in
       (match
          Journal.settle_node ~dir ~request_id ~node_id:id ~effect_disposition
            ~result_json:data ~identity ()
        with
        | Ok () -> ()
        | Error error -> log "JOURNAL_SETTLE_ERROR %s %s" id error);
       Executor.dispatch_result
         (Tool_result.make_ok
            ~tool_name:node.Plan.tool_name
            ~start_time:(Timing.start ())
            ~data
            ())))
  in
  Eio_main.run (fun _env ->
      match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
      | Ok results ->
        List.iter
          (fun (node : Executor.node_result) ->
            log "SETTLED %s" (node_id_string node.Executor.node_id))
          results;
        `Completed
      | Error _failure ->
        stage "attempt failed (turn incomplete)";
        `Failed)
;;

let journal_s1 () =
  stage "s1: crash during search (lane settled), resume same request id";
  let dir = fresh_dir () in
  ensure_markers dir;
  let crash_flag_file = Filename.concat (markers_dir dir) "crash_search_next" in
  let oc = open_out crash_flag_file in
  output_string oc "1";
  close_out oc;
  (* 1차: lane 은 dispatch+정산(settled)되고 search dispatch 중 crash.
     search 는 attempting/unknown 잔여로 남는다. *)
  let first = run_attempt ~dir ~request_id ~crash_marker:(Some "search") ~crash_flag_file in
  let lane_after_first = count "effect:lane" (effect_file dir) in
  let search_after_first = count "effect:search" (effect_file dir) in
  (* 2차: 같은 request_id. settled lane 은 dispatch 없이 저장 결과로 정산되고,
     attempting/unknown search 는 fail-closed 로 거절된다 — 턴은 incomplete 로
     끝나고 어떤 효과도 두 번 나지 않는다. *)
  let second = run_attempt ~dir ~request_id ~crash_marker:None ~crash_flag_file in
  let lane_effects_total = count "effect:lane" (effect_file dir) in
  let search_effects_total = count "effect:search" (effect_file dir) in
  log "S1_RESULT first=%s lane=%d search=%d | second=%s lane_total=%d search_total=%d lane_redispatched=%b search_redispatched=%b"
    (match first with `Completed -> "completed" | `Failed -> "failed")
    lane_after_first
    search_after_first
    (match second with `Completed -> "completed" | `Failed -> "failed")
    lane_effects_total search_effects_total
    (lane_effects_total > 1)
    (search_effects_total > 1);
  (* 저널 판정 직독: settled lane 은 Skip 이어야 한다. lane 의 실제 resolve
     입력은 literal `Assoc [] 이므로 같은 identity 를 재구성해 대조한다. *)
  let lane_input : Yojson.Safe.t = `Assoc [] in
  let lane_identity =
    let plan, _, _ = make_plan () in
    identity_for ~plan ~input:lane_input
  in
  (match
     Journal.begin_node
       ~dir
       ~request_id
       ~node_id:"lane"
       ~pre_effect_disposition:Tool_result.Proven_pre_effect
       ~identity:lane_identity
   with
   | Ok Journal.(Skip_node_settled record) ->
     log "S1 journal lane decision=Skip_node_settled disposition=%s result_json_present=%b"
       (Journal.effect_disposition_to_string record.Journal.effect_disposition)
       (Option.is_some record.Journal.result_json)
   | Ok other -> log "S1 journal lane decision=%s" (decision_name other)
   | Error _ -> log "S1 journal lane read error");
  (* attempting+pre_effect 노드는 redo, attempting+unknown 노드는 거절. *)
  let redo_identity =
    { Journal.plan_revision = digest "plan-redo"
    ; input_sha = digest "input-redo"
    ; owner = "h2j-owner-a"
    }
  in
  (match
     Journal.begin_node
       ~dir
       ~request_id:"req-h2-journal-redo"
       ~node_id:"retry_node"
       ~pre_effect_disposition:Tool_result.Proven_pre_effect
       ~identity:redo_identity
   with
   | Ok Journal.(Redo_node_pre_effect _) ->
     (match
        Journal.begin_node
          ~dir
          ~request_id:"req-h2-journal-redo"
          ~node_id:"retry_node"
          ~pre_effect_disposition:Tool_result.Proven_pre_effect
          ~identity:redo_identity
      with
      | Ok Journal.(Redo_node_pre_effect _) ->
        log "S1 attempting+pre_effect decision=Redo_node_pre_effect (re-dispatch safe)"
      | Ok other -> log "S1 attempting decision=%s (expected Redo)" (decision_name other)
      | Error _ -> log "S1 attempting read error")
   | Ok other -> log "S1 fresh pre_effect node decision=%s (expected Redo)" (decision_name other)
   | Error _ -> log "S1 fresh pre_effect node read error");
  let refuse_identity =
    { Journal.plan_revision = digest "plan-refuse"
    ; input_sha = digest "input-refuse"
    ; owner = "h2j-owner-a"
    }
  in
  (match
     Journal.begin_node
       ~dir
       ~request_id:"req-h2-journal-refuse"
       ~node_id:"unknown_node"
       ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
       ~identity:refuse_identity
   with
   | Ok Journal.(Redo_node_pre_effect _) ->
     (match
        Journal.begin_node
          ~dir
          ~request_id:"req-h2-journal-refuse"
          ~node_id:"unknown_node"
          ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
          ~identity:refuse_identity
      with
      | Ok Journal.(Refuse_unknown_effect _) ->
        log "S1 attempting+unknown decision=Refuse_unknown_effect (fail-closed)"
      | Ok other -> log "S1 unknown decision=%s (expected Refuse)" (decision_name other)
      | Error _ -> log "S1 unknown read error")
   | Ok other -> log "S1 fresh unknown node decision=%s (expected Redo-then-Refuse)" (decision_name other)
   | Error _ -> log "S1 fresh unknown node read error")
;;

(* journal_s2: 손상 레코드 → 거부, 재작성 없음. *)

let journal_s2 () =
  stage "s2: corrupt record is refused, not rewritten";
  let dir = fresh_dir () in
  let request_dir = Filename.concat dir request_id in
  Unix.mkdir request_dir 0o755;
  let path = Filename.concat request_dir "broken.json" in
  let oc = open_out path in
  output_string oc {|{"schema_version": 1, "request_id": |};
  close_out oc;
  (match Journal.read_record ~dir ~request_id ~node_id:"broken" with
   | Error (Corrupt_record reason) -> log "S2 corrupt refused: %s" reason
   | Error (Schema_mismatch { found }) -> log "S2 schema refused: %s" found
   | Error (Directory_unreadable path) -> log "S2 unreadable: %s" path
   | Ok _ -> log "S2 UNEXPECTED read ok");
  let before = (Unix.stat path).st_size in
  (match
     Journal.begin_node
       ~dir
       ~request_id
       ~node_id:"broken"
       ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
       ~identity:
         { Journal.plan_revision = digest "plan-s2"
         ; input_sha = digest "input-s2"
         ; owner = "h2j-owner-a"
         }
   with
   | Error _ -> log "S2 begin_node refused the corrupt record"
   | Ok _ -> log "S2 UNEXPECTED begin_node accepted corrupt");
  let after = (Unix.stat path).st_size in
  log "S2_RESULT size_before=%d size_after=%d rewritten=%b (incomplete preserved=%b)"
    before after (not (Int.equal before after)) (Int.equal before after)
;;

(* journal_s3: 효과 직후·정산 기록 전 중단을 readback 으로 1회 확정한다.
   1차 프로세스(함수 호출 경계)가 search 효과 직후 죽은 상태를 파일로 만들고
   (attempting/unknown 잔여), 재개 쪽이 목적지 readback 으로 효과 존재를
   증명하면 attempting 기록이 settled 로 승격되고 저장 결과로 정산된다 —
   효과는 여전히 1회. prove_effect=false 면 기록이 그대로 남아(조용한
   재작성 없음) 재개는 fail-closed 로 거절된다. *)

let journal_s3 () =
  stage "s3: effect landed before settle is confirmed by destination readback";
  let dir = fresh_dir () in
  ensure_markers dir;
  let identity =
    { Journal.plan_revision = digest "plan-s3"
    ; input_sha = digest "input-s3"
    ; owner = "h2j-owner-a"
    }
  in
  (* 1차: 효과는 났지만 정산 기록 전 중단한 상태 — attempting/unknown 만 남는다. *)
  (match
     Journal.begin_node
       ~dir
       ~request_id
       ~node_id:"search"
       ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
       ~identity
   with
   | Ok Journal.(Redo_node_pre_effect _) -> append_marker (effect_file dir) "effect:search"
   | Ok other -> log "S3 UNEXPECTED begin decision=%s" (decision_name other)
   | Error _ -> log "S3 UNEXPECTED begin error");
  let effects_before_readback = count "effect:search" (effect_file dir) in
  (* 2차(재개): 목적지 readback 이 효과 존재를 증명 → settled 승격. *)
  let prove_true () = Some true in
  let stored_result : Yojson.Safe.t = `String "p-3 · search result (recovered by readback)" in
  let promoted =
    Journal.confirm_effect_via_readback
      ~dir
      ~request_id
      ~node_id:"search"
      ~identity
      ~prove_effect:prove_true
      ~result_json:(Some stored_result)
  in
  (match promoted with
   | Ok (Some Journal.(Skip_node_settled record)) ->
     log "S3 readback promoted attempting→settled, result_json_present=%b"
       (Option.is_some record.Journal.result_json)
   | Ok (Some other) -> log "S3 UNEXPECTED readback decision=%s" (decision_name other)
   | Ok None -> log "S3 UNEXPECTED readback found nothing"
   | Error _ -> log "S3 UNEXPECTED readback error");
  (* 승격 뒤 재개 판정: Skip (1회 확정) — 이 노드는 다시 dispatch 되지 않는다. *)
  (match
     Journal.begin_node
       ~dir
       ~request_id
       ~node_id:"search"
       ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
       ~identity
   with
   | Ok Journal.(Skip_node_settled _) ->
     log "S3 post-readback decision=Skip_node_settled (single confirmation holds)"
   | Ok other -> log "S3 UNEXPECTED post-readback decision=%s" (decision_name other)
   | Error _ -> log "S3 UNEXPECTED post-readback error");
  (* 부정 경로: prove_effect 가 증명하지 못하면(Some false/None) 기록은 그대로
     — 다음 재개는 Refuse 로 fail-closed. 별도 dir2 로 긍정 경로의 계수 파일을
     지키고, 효과 흔적도 dir2 쪽에 남긴다. *)
  let dir2 = fresh_dir_s "s3neg" in
  ensure_markers dir2;
  let identity_neg = { identity with plan_revision = digest "plan-s3neg" } in
  (match
     Journal.begin_node
       ~dir:dir2
       ~request_id:"req-h2-journal-s3neg"
       ~node_id:"search"
       ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
       ~identity:identity_neg
   with
   | Ok Journal.(Redo_node_pre_effect _) -> append_marker (effect_file dir2) "effect:search-neg"
   | Ok other -> log "S3 UNEXPECTED neg begin decision=%s" (decision_name other)
   | Error _ -> log "S3 UNEXPECTED neg begin error");
  let prove_false () = Some false in
  (match
     Journal.confirm_effect_via_readback
       ~dir:dir2
       ~request_id:"req-h2-journal-s3neg"
       ~node_id:"search"
       ~identity:identity_neg
       ~prove_effect:prove_false
       ~result_json:None
   with
   | Ok None -> (
       match
         Journal.begin_node
           ~dir:dir2
           ~request_id:"req-h2-journal-s3neg"
           ~node_id:"search"
           ~pre_effect_disposition:Tool_result.Effect_outcome_unknown
           ~identity:identity_neg
       with
       | Ok Journal.(Refuse_unknown_effect _) ->
         log "S3 unproven effect stays refuse-closed (no silent rewrite)"
       | Ok other -> log "S3 UNEXPECTED neg decision=%s" (decision_name other)
       | Error _ -> log "S3 UNEXPECTED neg error")
   | Ok (Some _) -> log "S3 UNEXPECTED neg promoted"
   | Error _ -> log "S3 UNEXPECTED neg error");
  let lane_s3 = count "effect:search" (effect_file dir) in
  let neg_s3 = count "effect:search-neg" (effect_file dir2) in
  log "S3_RESULT pos_effects=%d neg_effects=%d (positive single effect holds=%b, negative isolated=%b)"
    lane_s3 neg_s3
    (Int.equal effects_before_readback lane_s3)
    (Int.equal neg_s3 1)
;;

(* journal_s4: identity 불일치 — 다른 계획·입력·소유자가 같은 request_id 의
   저장 결과를 재사용하지 못한다. 각 축을 따로 때려 세 축 모두 거절을 본다. *)

let journal_s4 () =
  stage "s4: identity mismatch refuses reuse across plan/input/owner";
  let dir = fresh_dir () in
  ensure_markers dir;
  let base =
    { Journal.plan_revision = digest "plan-4"
    ; input_sha = digest "input-4"
    ; owner = "h2j-owner-a"
    }
  in
  (match
     Journal.begin_node
       ~dir
       ~request_id
       ~node_id:"lane"
       ~pre_effect_disposition:Tool_result.Proven_pre_effect
       ~identity:base
   with
   | Ok Journal.(Redo_node_pre_effect _) -> append_marker (effect_file dir) "effect:lane"
   | Ok other -> log "S4 UNEXPECTED begin decision=%s" (decision_name other)
   | Error _ -> log "S4 UNEXPECTED begin error");
  let check label identity =
    match
      Journal.begin_node
        ~dir
        ~request_id
        ~node_id:"lane"
        ~pre_effect_disposition:Tool_result.Proven_pre_effect
        ~identity
    with
    | Ok Journal.(Identity_mismatch m) ->
      log "S4 %s refused (stored plan=%s input=%s owner=%s / given plan=%s input=%s owner=%s)"
        label
        (String.escaped m.Journal.stored_plan_revision)
        (String.escaped m.Journal.stored_input_sha)
        (String.escaped m.Journal.stored_owner)
        (String.escaped m.given_plan_revision)
        (String.escaped m.given_input_sha)
        (String.escaped m.given_owner)
    | Ok other -> log "S4 %s UNEXPECTED decision=%s" label (decision_name other)
    | Error _ -> log "S4 %s UNEXPECTED error" label
  in
  check "different-plan" { base with plan_revision = digest "plan-4-OTHER" };
  check "different-input" { base with input_sha = digest "input-4-OTHER" };
  check "different-owner" { base with owner = "h2j-owner-b" };
  let effects = count "effect:lane" (effect_file dir) in
  log "S4_RESULT effect_count=%d (no cross-identity reuse=%b)" effects (Int.equal effects 1)
;;

let () =
  (* dune (test) 스탠자는 인자 없이 실행하므로, 인자가 없으면 전체 시나리오를
     돈다 — runtest 기본 alias 에서 exit 2 가 나지 않게 한다. *)
  let scenario = if Array.length Sys.argv < 2 then "all" else Sys.argv.(1) in
  match scenario with
  | "all" ->
    journal_s1 ();
    journal_s2 ();
    journal_s3 ();
    journal_s4 ()
  | "s1" -> journal_s1 ()
  | "s2" -> journal_s2 ()
  | "s3" -> journal_s3 ()
  | "s4" -> journal_s4 ()
  | other -> fail ("unknown scenario: " ^ other)

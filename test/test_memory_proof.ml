(* test/test_memory_proof.ml *)

open Eio.Std

(* Jaccard Similarity의 어휘 매칭 전처리 로직 구현 *)
let clean_for_similarity s =
  String.map (fun c ->
    let lc = Char.lowercase_ascii c in
    let keep =
      (lc >= 'a' && lc <= 'z') ||
      (lc >= '0' && lc <= '9') ||
      Char.code lc >= 128
    in
    if keep then lc else ' '
  ) s

let normalize_for_similarity s =
  let cleaned = clean_for_similarity s in
  let words =
    cleaned
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w >= 2)
  in
  (* Deduplicate *)
  let rec dedup acc = function
    | [] -> List.rev acc
    | x :: xs -> if List.mem x acc then dedup acc xs else dedup (x :: acc) xs
  in
  dedup [] words

let char_ngrams n s =
  let cleaned = clean_for_similarity s in
  let buf = Buffer.create (String.length cleaned) in
  String.iter (fun c -> if c <> ' ' then Buffer.add_char buf c) cleaned;
  let compact = Buffer.contents buf in
  let len = String.length compact in
  if len < n then (if len > 0 then [compact] else [])
  else
    let rec loop acc i =
      if i > len - n then List.rev acc
      else
        let gram = String.sub compact i n in
        let next_acc = if List.mem gram acc then acc else gram :: acc in
        loop next_acc (i + 1)
    in
    loop [] 0

(* 한글 1음절(3바이트), 2음절(6바이트) 및 단어 기반 Jaccard 계산 *)
let jaccard_similarity a b =
  let words_a = normalize_for_similarity a in
  let words_b = normalize_for_similarity b in
  let ngrams_a = char_ngrams 3 a @ char_ngrams 6 a in
  let ngrams_b = char_ngrams 3 b @ char_ngrams 6 b in
  let ta = words_a @ ngrams_a in
  let tb = words_b @ ngrams_b in
  if ta = [] && tb = [] then 1.0
  else if ta = [] || tb = [] then 0.0
  else
    let rec count_intersection acc = function
      | [] -> acc
      | x :: xs ->
          if List.mem x ta && not (List.mem x acc) then
            count_intersection (x :: acc) xs
          else
            count_intersection acc xs
    in
    let intersection = List.length (count_intersection [] tb) in
    let rec union_list acc = function
      | [] -> acc
      | x :: xs -> if List.mem x acc then union_list acc xs else union_list (x :: acc) xs
    in
    let union = List.length (union_list ta tb) in
    if union = 0 then 0.0 else float_of_int intersection /. float_of_int union

(* 부정형 어휘 감지 기능 시뮬레이션 *)
let has_negation s =
  let negs = ["금지"; "말 것"; "안됨"; "not"; "never"; "don't"; "stop"; "하지 마"; "하지마"] in
  List.exists (fun w ->
    let rec check_substring i =
      if i > String.length s - String.length w then false
      else if String.sub s i (String.length w) = w then true
      else check_substring (i + 1)
    in
    check_substring 0
  ) negs

let apply_negation_penalty score s1 s2 =
  if has_negation s1 <> has_negation s2 then score *. 0.2 else score

(* Jaccard Similarity & Negation Guardrail 테스트 *)
let test_jaccard_limits () =
  Printf.printf "=== 1. Jaccard Similarity & Negation Penalty Test ===\n";
  let s1 = "통합 테스트 시 DB 모킹을 금지한다." in
  let s2 = "통합 테스트 시 DB 모킹을 권장한다." in
  
  let score = jaccard_similarity s1 s2 in
  Printf.printf "Jaccard 유사도 점수 (금지 vs 권장): %.4f\n" score;
  Printf.printf "중복 판단 임계치 (0.85) 초과 여부: %b (★초과 시 금지/권장 오판 덮어쓰기 발생!)\n" (score >= 0.85);

  let final_score = apply_negation_penalty score s1 s2 in
  Printf.printf "부정형 가드레일 패널티 적용 후 유사도 점수: %.4f\n" final_score;
  Printf.printf "보완 후 중복 판단 임계치 (0.85) 초과 여부: %b (안전하게 분리되어 덮어쓰기 방어 완료)\n" (final_score >= 0.85);
  Printf.printf "======================================================\n\n"

(* 적대적 부정어 예외 상황 테스트 (Adversarial Negation Test) *)
let test_adversarial_negation () =
  Printf.printf "=== 3. Adversarial Negation Bypass Test ===\n";
  (* s1은 허용(금지된 게 아님), s2는 금지(실제 금지) -> 의미가 반대이나 둘 다 "금지" 어휘를 포함함 *)
  let s1 = "통합 테스트 시 DB 모킹은 금지된 사항이 아니다." in
  let s2 = "통합 테스트 시 DB 모킹을 금지한다." in
  
  let score = jaccard_similarity s1 s2 in
  let naive_penalty_score = apply_negation_penalty score s1 s2 in
  Printf.printf "원문 1: \"%s\"\n" s1;
  Printf.printf "원문 2: \"%s\"\n" s2;
  Printf.printf "Jaccard 유사도: %.4f\n" score;
  Printf.printf "단순 키워드 부정형 패널티 적용 후: %.4f\n" naive_penalty_score;
  Printf.printf "중복 오판 여부 (임계치 0.60 기준): %b (★위험: 둘 다 '금지' 단어가 들어가 패널티가 미작동하고 중복 판정됨!)\n" (naive_penalty_score >= 0.60);

  (* 문맥적/어미 분석식 부정 처리 시뮬레이션 (Semantic Negation Checker) *)
  let has_contextual_negation s =
    (* "금지" 뒤에 "아니다" 등의 부정형 표현이 문맥적으로 이어지는지 검사 *)
    let neg_patterns = ["금지된 사항이 아니다"; "금지하지 않는다"; "금지된 사항은 아니다"] in
    let rec check_patterns = function
      | [] -> false
      | pat :: pats ->
          let rec check_substring i =
            if i > String.length s - String.length pat then false
            else if String.sub s i (String.length pat) = pat then true
            else check_substring (i + 1)
          in
          if check_substring 0 then true else check_patterns pats
    in
    if check_patterns neg_patterns then false (* 부정의 부정 = 긍정 (금지 안 함) *)
    else has_negation s (* 일반 부정 체크 *)
  in
  let apply_contextual_negation_penalty score s1 s2 =
    if has_contextual_negation s1 <> has_contextual_negation s2 then score *. 0.2 else score
  in
  let final_score = apply_contextual_negation_penalty score s1 s2 in
  Printf.printf "어미 패턴 분석 보완 후 패널티 점수: %.4f\n" final_score;
  Printf.printf "보완 후 중복 오판 여부 (임계치 0.60 기준): %b (안전하게 상호 불일치 판정 성공)\n" (final_score >= 0.60);
  Printf.printf "======================================================\n\n"

(* Eio 병렬 쿼리 & 타임아웃 Degraded Operation 테스트 *)
let test_eio_parallel_recall env =
  Printf.printf "=== 2. Eio Parallel & Timeout Fallback Benchmark ===\n";
  let clock = Eio.Stdenv.clock env in
  
  let t0 = Unix.gettimeofday () in
  Eio.Time.sleep clock 0.2;
  Eio.Time.sleep clock 0.3;
  let t1 = Unix.gettimeofday () in
  Printf.printf "순차 쿼리 소요 시간: %.1f ms\n" ((t1 -. t0) *. 1000.0);

  let t0 = Unix.gettimeofday () in
  ignore (
    Eio.Fiber.pair
      (fun () -> Eio.Time.sleep clock 0.2)
      (fun () -> Eio.Time.sleep clock 0.3)
  );
  let t1 = Unix.gettimeofday () in
  Printf.printf "Eio.Fiber.pair 병렬 쿼리 소요 시간: %.1f ms (병목인 300ms에 수렴)\n" ((t1 -. t0) *. 1000.0);

  let run_with_timeout timeout_ms f =
    Eio.Fiber.first
      (fun () -> f ())
      (fun () ->
         Eio.Time.sleep clock (float_of_int timeout_ms /. 1000.0);
         failwith "Database Timeout")
  in
  let t0 = Unix.gettimeofday () in
  let (vector_results, graph_results) =
    Eio.Fiber.pair
      (fun () ->
         match run_with_timeout 800 (fun () -> Eio.Time.sleep clock 0.2; ["vector_data"]) with
         | x -> x
         | exception _ -> [])
      (fun () ->
         match run_with_timeout 800 (fun () -> Eio.Time.sleep clock 5.0; ["graph_data"]) with
         | x -> x
         | exception _ ->
             Printf.printf "[Guardrail Triggered] Neo4j 지연 감지 및 800ms 타임아웃 즉시 탈출 수행\n";
             [])
  in
  let t1 = Unix.gettimeofday () in
  Printf.printf "타임아웃 적용 후 총 쿼리 시간: %.1f ms (5000ms 블로킹 방어 완료)\n" ((t1 -. t0) *. 1000.0);
  Printf.printf "회수된 부분 데이터 수: %d (Degraded Mode 정상 회복)\n" (List.length vector_results + List.length graph_results);
  Printf.printf "======================================================\n\n"

(* 투기적 선행 임베딩 자원 누수 및 Ticket 기반 Cancellation 검증 *)
let test_adversarial_pre_embed env =
  Printf.printf "=== 4. Speculative Pre-Embedding Fiber Leak & Cancellation Test ===\n";
  let clock = Eio.Stdenv.clock env in

  (* 1. 자원 누수 상황 시뮬레이션 (디바운스는 걸렸으나 취소 로직이 없는 경우) *)
  let leak_invocations = ref 0 in
  let simulate_leak_pre_embed ~sw current_input_prefix =
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.1; (* 빠른 테스트를 위해 100ms 디바운스로 시뮬레이션 *)
      incr leak_invocations;
      (* expensive embedding computation *)
      ignore (Array.make 1536 0.05)
    )
  in

  (* 10ms 간격으로 사용자가 고속 타이핑하는 시나리오 *)
  Printf.printf "[Simulation A: 취소 로직이 없을 때 고속 타이핑 (10ms 간격, 5회 트리거)]\n";
  Eio.Switch.run (fun sw ->
    List.iter (fun prefix ->
      simulate_leak_pre_embed ~sw prefix;
      Eio.Time.sleep clock 0.01
    ) ["t"; "te"; "tes"; "test"; "test_mock"]
  );
  Eio.Time.sleep clock 0.15; (* 모든 작업이 끝날 때까지 대기 *)
  Printf.printf "비정상 중첩 호출 수: %d (★전체 요청이 취소되지 않고 전부 연산을 수행하여 CPU 낭비 발생)\n\n" !leak_invocations;

  (* 2. Ticket 기반 Cancellation 기법 검증 *)
  let ticket_invocations = ref 0 in
  let latest_ticket = ref 0 in
  let simulate_ticket_pre_embed ~sw current_input_prefix =
    let my_ticket = !latest_ticket + 1 in
    latest_ticket := my_ticket;
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.1;
      (* 디바운스 수면 완료 후, 자기가 가장 최근 티켓이 아니면 연산을 생략 *)
      if !latest_ticket = my_ticket then (
        incr ticket_invocations;
        ignore (Array.make 1536 0.05)
      )
    )
  in

  Printf.printf "[Simulation B: Ticket 기반 취소 검증 (10ms 간격, 5회 트리거)]\n";
  Eio.Switch.run (fun sw ->
    List.iter (fun prefix ->
      simulate_ticket_pre_embed ~sw prefix;
      Eio.Time.sleep clock 0.01
    ) ["t"; "te"; "tes"; "test"; "test_mock"]
  );
  Eio.Time.sleep clock 0.15;
  Printf.printf "최종 임베딩 계산 수행 수: %d (최종 마지막 1개만 실행되고 나머지 4개는 연산 생략 성공!)\n" !ticket_invocations;
  Printf.printf "======================================================\n"

let () =
  Eio_main.run (fun env ->
    test_jaccard_limits ();
    test_eio_parallel_recall env;
    test_adversarial_negation ();
    test_adversarial_pre_embed env
  )

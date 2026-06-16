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

(* Jaccard Similarity & Negation Guardrail 테스트 *)
let test_jaccard_limits () =
  Printf.printf "=== 1. Jaccard Similarity & Negation Penalty Test ===\n";
  let s1 = "통합 테스트 시 DB 모킹을 금지한다." in
  let s2 = "통합 테스트 시 DB 모킹을 권장한다." in
  
  let score = jaccard_similarity s1 s2 in
  Printf.printf "Jaccard 유사도 점수 (금지 vs 권장): %.4f\n" score;
  Printf.printf "중복 판단 임계치 (0.85) 초과 여부: %b (★초과 시 금지/권장 오판 덮어쓰기 발생!)\n" (score >= 0.85);

  (* 부정형 어휘 감지 기능 시뮬레이션 *)
  let has_negation s =
    let negs = ["금지"; "말 것"; "안됨"; "not"; "never"; "don't"; "stop"; "하지 마"; "하지마"] in
    List.exists (fun w ->
      (* 단어 포함 검사 *)
      let rec check_substring i =
        if i > String.length s - String.length w then false
        else if String.sub s i (String.length w) = w then true
        else check_substring (i + 1)
      in
      check_substring 0
    ) negs
  in
  let apply_negation_penalty score s1 s2 =
    if has_negation s1 <> has_negation s2 then score *. 0.2 else score
  in
  let final_score = apply_negation_penalty score s1 s2 in
  Printf.printf "부정형 가드레일 패널티 적용 후 유사도 점수: %.4f\n" final_score;
  Printf.printf "보완 후 중복 판단 임계치 (0.85) 초과 여부: %b (안전하게 분리되어 덮어쓰기 방어 완료)\n" (final_score >= 0.85);
  Printf.printf "======================================================\n\n"

(* Eio 병렬 쿼리 & 타임아웃 Degraded Operation 테스트 *)
let test_eio_parallel_recall env =
  Printf.printf "=== 2. Eio Parallel & Timeout Fallback Benchmark ===\n";
  let clock = Eio.Stdenv.clock env in
  
  (* 1. 순차 쿼리 (Sequential Path) 시뮬레이션 *)
  let t0 = Unix.gettimeofday () in
  Eio.Time.sleep clock 0.2;
  Eio.Time.sleep clock 0.3;
  let t1 = Unix.gettimeofday () in
  Printf.printf "순차 쿼리 소요 시간: %.1f ms\n" ((t1 -. t0) *. 1000.0);

  (* 2. Eio.Fiber.pair 병렬 쿼리 시뮬레이션 *)
  let t0 = Unix.gettimeofday () in
  ignore (
    Eio.Fiber.pair
      (fun () -> Eio.Time.sleep clock 0.2)
      (fun () -> Eio.Time.sleep clock 0.3)
  );
  let t1 = Unix.gettimeofday () in
  Printf.printf "Eio.Fiber.pair 병렬 쿼리 소요 시간: %.1f ms (병목인 300ms에 수렴)\n" ((t1 -. t0) *. 1000.0);

  (* 3. 800ms 타임아웃 가드레일 & Degraded Operation 시뮬레이션 *)
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
  Printf.printf "======================================================\n"

let () =
  Eio_main.run (fun env ->
    test_jaccard_limits ();
    test_eio_parallel_recall env
  )

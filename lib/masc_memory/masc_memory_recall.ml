open Masc_memory_types
open Eio.Std

type t = {
  worker : Masc_domain_worker.t;
  env_clock : float Eio.Time.clock_ty Eio.Resource.t;
  supabase_client : unit;
  neo4j_client : unit;
  mutable speculative_cache : (string * float array) option;
  pre_embed_id : int Atomic.t;
}

let create ~worker ~env_clock ~supabase_client ~neo4j_client =
  { worker; env_clock; supabase_client; neo4j_client; speculative_cache = None; pre_embed_id = Atomic.make 0 }

let canonicalize_query s =
  s
  |> String.trim
  |> String.split_on_char ' '
  |> List.filter (fun w -> w <> "")
  |> String.concat " "

let pre_embed_speculative t ~sw ~current_input_prefix =
  let clean_prefix = canonicalize_query current_input_prefix in
  let my_ticket = Atomic.fetch_and_add t.pre_embed_id 1 + 1 in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Time.sleep t.env_clock 0.8;
    if Atomic.get t.pre_embed_id = my_ticket && String.length clean_prefix > 5 then
      let vec = Masc_domain_worker.compute_local_embedding t.worker ~text:clean_prefix in
      t.speculative_cache <- Some (clean_prefix, vec)
  )

let query_supabase_mock _client _vector _max =
  (* Mock DB query *)
  [ {
      id = "mem_1";
      kind = Feedback_rule;
      horizon = Long_term;
      source_trace_id = "trace_abc";
      text = "통합 테스트 시 DB 모킹 금지. 과거 프로덕션 마이그레이션 장애 이력 있음.";
      embedding = None;
      ts_unix = Unix.gettimeofday () -. 172800.0; (* 2 days ago *)
    } ]

let query_neo4j_mock _client _query _max =
  []

let recall t ~query ~max_results =
  try
    let clean_query = canonicalize_query query in
    let query_vector =
      match t.speculative_cache with
      | Some (prefix, vec) when String.starts_with ~prefix clean_query -> vec
      | _ -> Masc_domain_worker.compute_local_embedding t.worker ~text:clean_query
    in
    
    (* 2. Eio.Fiber.first와 sleep을 결합한 800ms 타임아웃 데코레이터 정의 *)
    let run_with_timeout timeout_ms f =
      Eio.Fiber.first f (fun () ->
        Eio.Time.sleep t.env_clock (float_of_int timeout_ms /. 1000.0);
        failwith "Database query timeout"
      )
    in
    
    (* 3. Eio.Fiber.pair를 통해 pgvector와 Neo4j를 병렬 쿼리하고 타임아웃 발생 시 빈 리스트로 복원(Degraded Fallback) *)
    let (vector_results, graph_results) =
      Eio.Fiber.pair
        (fun () ->
           match run_with_timeout 800 (fun () -> query_supabase_mock t.supabase_client query_vector max_results) with
           | x -> x
           | exception _ -> [])
        (fun () ->
           match run_with_timeout 800 (fun () -> query_neo4j_mock t.neo4j_client query max_results) with
           | x -> x
           | exception _ -> [])
    in
    
    (* 4. 결과 병합 및 노화 경고 (Staleness warning) 동적 주입 *)
    let merged = vector_results @ graph_results in
    let now = Unix.gettimeofday () in
    let processed_results =
      List.map (fun row ->
        let age_days = (now -. row.ts_unix) /. 86400.0 in
        if age_days >= 1.0 then
          { row with text =
              Printf.sprintf
                "[STALENESS WARNING: 이 메모리는 %.1f일 전에 작성된 과거 시점의 관측입니다. \
                 코드베이스에서 현재 구조를 반드시 재확인(Verify First)하십시오.]\n%s"
                age_days row.text
          }
        else
          row
      ) merged
    in
    Ok processed_results
  with exn ->
    Error (Printf.sprintf "Recall failed: %s" (Printexc.to_string exn))

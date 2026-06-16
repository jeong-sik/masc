# MASC / OAS 차세대 메모리 아키텍처 상세 스펙 (Specification)

본 문서는 Jaccard Similarity 폐기 후 제안된 **Graph-Vector Hybrid Memory & Async LLM Consolidation** 아키텍처를 구현하기 위한 OCaml 5.x Eio 기반의 상세 사양 및 모듈 인터페이스(`mli`) 명세서입니다. 

5대 취약점(CPU 병목, API 의존성, 분산 DB 일관성, LLM 자율 삭제 환각, 동기 Recall 지연)을 방어하기 위한 방어 전략들이 고스란히 코드로 이식되어 있습니다.

---

## 1. 전체 모듈 구조도

```
                    ┌─────────────────────────┐
                    │      OAS SDK Core       │ (MASC를 모름)
                    │ - Trigger Hooks / Events│
                    └────────────┬────────────┘
                                 │ (OAS.Event_bus / Hooks)
                                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          MASC Memory Kernel                            │
│                                                                        │
│   ┌─────────────────────────┐           ┌──────────────────────────┐   │
│   │   Masc_memory_types     │◄──────────┤    Masc_domain_worker    │   │
│   │ (Types, Horizon, Events)│           │ (Eio.Domain Multi-Core)  │   │
│   └────────────▲────────────┘           └────────────▲─────────────┘   │
│                │                                     │                 │
│   ┌────────────┴────────────┐           ┌────────────┴─────────────┐   │
│   │   Masc_memory_outbox    │           │    Masc_memory_recall    │   │
│   │ (Transactional Outbox)  │           │ (Speculative, pgvector)  │   │
│   └────────────▲────────────┘           └────────────▲─────────────┘   │
│                │                                     │                 │
│                └──────────────────┬──────────────────┘                 │
│                                   │                                    │
│                     ┌─────────────▼─────────────┐                      │
│                     │  Masc_memory_consolidator │                      │
│                     │   (Dream / Proposal)      │                      │
│                     └───────────────────────────┘                      │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 모듈 스펙 명세 (OCaml Interfaces)

### A. `Masc_memory_types.ml` (공용 타입 정의)

메모리의 종류, 저장 지평선(Horizon), 그리고 트랜잭션 아웃박스를 위한 이벤트 타입을 선언합니다.

```ocaml
(* masc/lib/memory/masc_memory_types.ml *)

type horizon =
  | Short_term  (** 1~3 turns: Working memory *)
  | Mid_term    (** 1~7 days: Session level *)
  | Long_term   (** Infinite: User preferences, feedback rules *)

type memory_kind =
  | User_profile    (** User's role, skills, preference *)
  | Feedback_rule   (** What to do / What to avoid + Why & How *)
  | Project_context (** Ongoing goals, absolute dates *)
  | External_ref    (** External URLs, Linear, Grafana, Slack *)

type memory_row = {
  id : string;
  kind : memory_kind;
  horizon : horizon;
  source_trace_id : string;
  text : string;
  embedding : float array option;
  ts_unix : float;
}

type outbox_status =
  | Pending
  | In_progress
  | Succeeded of { pgvector : bool; neo4j : bool }
  | Failed of string

type outbox_event = {
  event_id : string;
  retry_count : int;
  status : outbox_status;
  payload : memory_row;
}

type proposal_action =
  | Proposal_merge of { target_ids : string list; merged_text : string }
  | Proposal_delete of { target_id : string; reason : string }

type consolidation_proposal = {
  proposal_id : string;
  created_at : float;
  action : proposal_action;
  rationale : string;
  approved : bool;
}
```

---

### B. `Masc_memory_outbox.mli` (트랜잭션 아웃박스)

Supabase와 Neo4j에 비동기로 저장할 때 정합성이 깨지는 것을 방지하는 영속적 아웃박스 파일 큐 인터페이스입니다.

```ocaml
(* masc/lib/memory/masc_memory_outbox.mli *)

open Masc_memory_types

type t
(** Outbox manager instance. *)

val create : env_fs:Eio.Fs.dir Eio.Path.t -> db_path:string -> t
(** [create ~env_fs ~db_path]는 로컬 원자적 로그 디렉토리를 지칭하는 아웃박스 인스턴스를 생성합니다. *)

val enqueue : t -> memory_row -> (unit, string) result
(** [enqueue t row]는 메모리 행을 로컬 디렉토리(`~/.masc/outbox/pending/`)에 원자적으로 기록(fsync)합니다. 
    로컬 파일 저장이 성공하면 트랜잭션은 안전한 것으로 간주합니다. *)

val process_queue : 
  t -> 
  write_pgvector:(memory_row -> (unit, string) result) -> 
  write_neo4j:(memory_row -> (unit, string) result) -> 
  unit
(** [process_queue t ~write_pgvector ~write_neo4j]는 백그라운드 루프에서 대기 중인 
    이벤트를 읽어 Supabase pgvector와 Neo4j에 각각 쓰기를 시도합니다. 
    두 데이터베이스에 모두 쓰기가 완전히 성공할 때까지 멱등성(Idempotency)을 유지하며 재시도(Backoff)합니다. *)
```

---

### C. `Masc_domain_worker.mli` (멀티 도메인 병렬 연산 위임)

협조적 멀티태스킹 환경(Eio Fiber)에서 CPU-bound 연산이 I/O 루프를 멈추게 하지 않도록 별도의 시스템 OS Core(Domain)로 밀어내는 워커입니다.

```ocaml
(* masc/lib/memory/masc_domain_worker.mli *)

type t

val create : domain_mgr:Eio.Domain_manager.t -> t
(** [create ~domain_mgr]는 멀티도메인 연산 스케줄러를 기동합니다. *)

val run_cpu_intensive : t -> (unit -> 'a) -> 'a
(** [run_cpu_intensive t f]는 메인 Eio Fiber의 I/O 루프를 블로킹하지 않도록 
    지정된 함수 [f]를 OS 레벨의 서브 도메인 코어에서 병렬로 기동하고 결과를 반환받습니다. *)

val compute_local_embedding : t -> text:string -> float array
(** [compute_local_embedding t ~text]는 로컬에 내장된 ONNX 경량 임베딩 모델을 활용하여 
    서브 도메인에서 온오프라인 상태로 1ms 내에 벡터를 계산해 반환합니다. *)
```

---

### D. `Masc_memory_recall.mli` (Speculative Recall 및 병렬 회수)

사용자 입력의 1차 반응속도(Time to First Token) 지연을 막는 투기적 실행(Pre-fetching) 및 임베딩 하이브리드 검색 모듈입니다.

```ocaml
(* masc/lib/memory/masc_memory_recall.mli *)

open Masc_memory_types

type t

val create : 
  worker:Masc_domain_worker.t ->
  supabase_client:unit ->  (* Supabase Client type *)
  neo4j_client:unit ->     (* Neo4j Client type *)
  t

val pre_embed_speculative : t -> current_input_prefix:string -> unit
(** [pre_embed_speculative t ~current_input_prefix]는 사용자가 터미널에 입력을 작성 중이거나 
    IDE 버퍼를 갱신 중일 때, 예측된 질문 접두사를 기준으로 백그라운드 도메인에서 임베딩을 선제적으로 계산합니다. *)

val recall : 
  t -> 
  query:string -> 
  max_results:int -> 
  (memory_row list, string) result
(** [recall t ~query ~max_results]는 입력된 쿼리를 사용해 메모리를 회수합니다.
    1. Fast Path: 로컬 캐시 및 최근 Speculative 임베딩이 존재하는 경우 캐시 히트(0.1ms).
    2. Slow Path: 임베딩 획득 및 Supabase pgvector(Cosine) + Neo4j(Sub-graph)를 
       [Eio.Fiber.pair]를 통해 병렬 쿼리하여 결과 병합. 
    3. 1일 이상 지난 결과에 대해서는 [ts_unix]를 기반으로 'Staleness Warning'을 첨부합니다. *)
```

---

### E. `Masc_memory_consolidator.mli` (LLM Judge Deletion/Merge Proposal)

LLM의 자율적 쓰기/삭제 권한 부여에 따른 환각 오삭제를 막기 위해 **"제안-승인(Proposal-Approval)"** 워크플로를 적용한 비동기 지식 정화 모듈입니다.

```ocaml
(* masc/lib/memory/masc_memory_consolidator.mli *)

open Masc_memory_types

type t

val create : 
  outbox:Masc_memory_outbox.t -> 
  recall:Masc_memory_recall.t ->
  t

val generate_consolidation_proposals : 
  t -> 
  llm_client:unit -> 
  (consolidation_proposal list, string) result
(** [generate_consolidation_proposals t ~llm_client]는 야간(Nightly)에 백그라운드 태스크로 구동됩니다.
    1. pgvector 임베딩 유사도 $0.6 \sim 0.85$ 범위 및 Neo4j의 중복 관계를 스캔하여 모호한 메모리 노드 쌍 추출.
    2. LLM Judge를 호출하여 두 지식의 모순 여부 판정.
    3. 자율 삭제나 즉시 쓰기를 수행하지 않고, [consolidation_proposal] 목록을 생성하여 
       로컬 디렉토리 `~/.masc/proposals/pending/`에 원자적 보존 후 관리자 알림(Slack 등)을 발행합니다. *)

val apply_approved_proposal : 
  t -> 
  proposal_id:string -> 
  (unit, string) result
(** [apply_approved_proposal t ~proposal_id]는 인간 관리자가 승인한 제안을 읽어 
    실제 Supabase 및 Neo4j에 대한 삭제/병합 이벤트를 [Masc_memory_outbox] 큐에 넣어 순차 수행합니다. *)
```

---

## 3. 2차 적대적 비판 및 아키텍처적 결함 분석 (Deep Adversarial Critique)

위에서 기술한 1차 사양서는 논리적으로 정밀해 보이지만, 실제 고성능 병렬 시스템 관점에서는 **매우 뼈아픈 설계 결함**들을 여전히 안고 있습니다. 시스템 마비를 예방하기 위해 아래와 같이 적대적으로 비판하고, 기술적인 보완책을 도입합니다.

### 결함 1. `enqueue`의 Fsync 동기 블로킹으로 인한 턴 레이턴시 훼손
* **비판**: "enqueue 시 로컬에 파일로 fsync하므로 트랜잭션이 안전하다"고 자랑했지만, `fsync`는 디스크 물리적 쓰기를 대기하는 대표적인 동기 블로킹 시스템 콜입니다. 메인 턴 응답 전송 전에 `enqueue`를 동기 호출하면, 디스크 I/O 레이턴시(수 ms~수십 ms)가 메인 Eio 루프를 완전히 멈춰 세우며 턴 속도를 직격합니다.
* **보완 설계**: 
  - `Masc_memory_outbox` 내부에 **메모리 내 비블로킹 스트림(Eio.Stream.t 링버퍼)**을 둡니다. 
  - `enqueue`는 스트림에 이벤트를 Push하자마자 0.1ms 내에 즉시 반환(Non-blocking)하며, 백그라운드 전용 파이버가 해당 스트림을 컨슘하여 로컬 디스크 파일 쓰기(`fsync`) 및 외부 DB 전송을 비동기로 도맡습니다.

### 결함 2. ONNX C FFI 바인딩의 메모리 누수(Memory Leak) 및 세그폴트 리스크
* **비판**: OCaml 5.x C FFI를 통해 C 힙 영역의 ONNX Runtime을 직접 바인딩하여 호출하면, OCaml 가비지 컬렉터(GC)는 C 영역에서 매번 생성되는 거대한 Tensor 메모리를 추적하지 못해 **심각한 메모리 누수**가 일어나고 에이전트가 OOM으로 크래시됩니다. 또한, OCaml Major GC가 수행되는 와중에 C 스레드 콜백이 런타임을 침범하면 Segmentation Fault로 즉사합니다.
* **보완 설계**:
  - `Masc_domain_worker`는 C FFI 함수를 호출할 때 반드시 OCaml GC 커스텀 블록(`Gc.finalise`) 래퍼를 씌워 OCaml 객체가 소멸할 때 C 텐서 할당 해제(`OrtReleaseTensor`)가 확실히 맞물려 일어나게 관리해야 합니다.
  - C 라이브러리와의 직접적인 도메인 스레드 경합을 피하기 위해, ONNX 프로세스를 IPC(Local Unix Domain Socket/Named Pipe)를 통해 별도의 격리된 마이크로 프로세스로 띄워 분리하는 것이 최적의 안정성을 보장합니다.

### 결함 3. "Speculative Pre-embed"의 키스트로크 자원 고갈과 무용성
* **비판**: 사용자가 타자를 치는 족족 임베딩을 선제 계산(`pre_embed_speculative`)하면 CPU 점유율은 100%로 솟구치고 맥북 배터리는 순식간에 방전됩니다. 더욱이, 사용자가 접두사("DB 마이그...")를 치다 백스페이스를 누르거나 문장을 바꾸면 이전 계산은 전부 무용지물이 되며, 접두사의 임베딩은 최종 완성 문장과 코사인 유사도 거리가 멀어 캐시 히트가 불가능합니다.
* **보완 설계**:
  - **Debounce / Throttle 필터링**: 사용자의 입력 타자가 멈춘 지 최소 `800ms`가 지난 시점의 입력만을 대상으로 투기적 실행을 진행합니다.
  - 접두사 수준의 임베딩은 계산하지 않고, 질문의 마지막 조사나 마침표(`.`, `?`, `Enter`)가 입력되기 직전의 온전한 형태 문장 구조만을 타겟팅하여 Pre-embed를 유발합니다.

### 결함 4. "Proposal-Approval" 인간 승인 병목으로 인한 메모리 썩음 (Memory Rot)
* **비판**: 매 턴마다 발생하는 메모리 정제를 개발자가 Trinity Dashboard에 들어가 수동으로 수락하고 승인하는 것은 최악의 UX이며 **심각한 인간 병목(Human Bottleneck)**입니다. 개발자는 결국 승인을 귀찮아해 방치하게 되고 지식 뱅크는 정제되지 않은 쓰레기로 가득 차 RAG의 컨텍스트 품질이 썩어버리는(Memory Rot) 현상이 일어납니다.
* **보완 설계**:
  - **하이브리드 신뢰도 임계치 (Auto-Approve Threshold)**를 적용합니다.
  - LLM Judge의 판정 신뢰도(Confidence Score)가 극도로 높은 구간(예: $Score \ge 0.95$, 명백한 동의어로 단순 병합)은 **인간 승인 없이 자동으로 커밋(Auto-Approve)**합니다.
  - 신뢰도가 낮거나 모순성이 포착되는 민감한 구간(예: $0.6 \le Score < 0.95$)의 Deletion/Merge 제안만 대시보드에 적재하여 개발자의 승인 비용을 최소화합니다.

### 결함 5. `Eio.Fiber.pair` 동기화 취약점 (Cascade Failure)
* **비판**: Supabase와 Neo4j를 `Eio.Fiber.pair`로 묶어 병렬 쿼리할 때, 클라우드 DB의 일시적 커넥션 풀 경합으로 Neo4j가 5초간 블로킹되면, Supabase가 0.1초 만에 응답했어도 전체 Recall 응답이 5초로 지연되어 어시스턴트 동작이 마비됩니다.
* **보완 설계**:
  - 두 DB 조회에 각각 독립적인 **Degraded Fallback Timeout (예: 800ms)**을 적용합니다.
  - `Eio.Fiber.pair` 대신 타임아웃 처리가 가미된 파이버 결합기를 사용하고, 제한 시간 초과 시 작동 가능한 데이터베이스의 지식만이라도 반환(Degraded Operation)하고 누락된 DB에 대해서는 Warning 메트릭을 남기도록 예외 제어를 상세화합니다.

---

## 4. 핵심 시나리오 제어 흐름 구현 예시 (OCaml)

다음은 2차 적대적 비판을 적용하여, 비블로킹 스트림 큐를 통한 아웃박스 인큐 및 타임아웃/Degraded 연산이 적용된 병렬 회수 코드의 구현 예시입니다.

```ocaml
(* masc/lib/memory/masc_memory_recall.ml *)

open Masc_memory_types
open Eio.Std

let recall_with_degraded_fallback t ~query ~max_results =
  try
    (* 1. Debounced/Cached 임베딩이 있으면 재사용, 없으면 로컬 worker 도메인 계산 *)
    let query_vector = Masc_domain_worker.compute_local_embedding t.worker ~text:query in
    
    (* 2. Eio.Fiber.first와 sleep을 결합한 타임아웃 데코레이터 정의 *)
    let run_with_timeout timeout_ms f =
      Eio.Fiber.first f (fun () -> sleep_ms timeout_ms; failwith "Timeout")
    in
    
    (* 3. 800ms 타임아웃 내에 Supabase와 Neo4j의 쿼리를 병렬 수행 (장애 발생 시 빈 결과로 Degraded Fallback) *)
    let (vector_results, graph_results) =
      Eio.Fiber.pair
        (fun () -> match run_with_timeout 800 (query_supabase) with Ok x -> x | Error _ -> [])
        (fun () -> match run_with_timeout 800 (query_neo4j) with Ok x -> x | Error _ -> [])
    in
    
    (* 4. 병합 및 노화 필터 주입 *)
    Ok (inject_staleness_warning (merge_and_rank vector_results graph_results))
  with
  | exn -> Error (Printexc.to_string exn)
```

---

## 5. 인프라 실 배포 시 가이드라인

1. **로컬 ONNX 임베딩 바인딩 (`Masc_domain_worker`)**
   - JVM/Python을 호출하지 않고 OCaml 바이너리가 직접 로딩할 수 있는 `onnxruntime` C API FFI 바인딩을 적용하여 `bge-micro-v2`(약 100MB 미만) 모델을 내장합니다.
2. **트랜잭션 아웃박스 복구 스케줄러**
   - 로컬 `start/status/stop` 데몬은 1분 단위로 `~/.masc/outbox/pending/` 폴더를 주기적으로 스캔하여, 성공 로그가 찍히지 않은 페이로드를 순차적으로 Supabase와 Neo4j Bolt 드라이버로 송출합니다.
3. **LLM Judge 가드레일 (Human-in-the-loop)**
   - `Dream Pass` 완료 후 Slack 알림이 퍼블리시되면, 개발자는 `./scripts/dashboard-serve.sh` 포털(http://localhost:8020)의 Trinity Dashboard에서 Deletion/Merge 제안 내용을 확인하고 단 하나의 클릭으로 승인(`apply_approved_proposal`)을 수행합니다.

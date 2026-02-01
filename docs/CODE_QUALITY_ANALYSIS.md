# masc-mcp OCaml 구현 품질 분석

> 분석일: 2025-02-01  
> 분석자: MELCHIOR (Subagent)  
> 코드베이스: 125개 .ml 파일, ~48,500 LOC

---

## 📊 요약

| 항목 | 등급 | 평가 |
|------|------|------|
| Obj.magic 사용 | ✅ **A** | 0건 - 완벽 |
| 타입 안전성 | ⚠️ **B-** | Option.get 4건, Result→failwith 변환 4건 |
| 예외 사용 | ✅ **A-** | 33건 (대부분 정당한 케이스) |
| Eio 사용법 | ✅ **A** | 현대적 패턴, 적절한 취소 처리 |
| 전역 상태 | ❌ **C** | 23개 전역 ref, 불필요한 것 다수 |
| 테스트 커버리지 | ⚠️ **B** | 192개 테스트, 14개 모듈 누락 |
| 코드 중복 | ⚠️ **B-** | Mutex 패턴 비일관, JSON 파싱 중복 |

---

## 🚨 "OCaml 고수가 보면 창피한 코드" 목록

### 1. Option.get 사용 (타입 안전성 위반)

```ocaml
(* lib/tool_agent.ml:224 - 가장 심각 *)
List.fold_left (fun best candidate ->
  match best with
  | None -> Some candidate
  | Some (_, best_score, _) -> ...
) None scored |> Option.get  (* scored가 비면 크래시! *)
```

```ocaml
(* lib/room.ml:2146 *)
| VoteApproved -> Printf.sprintf "Winner: %s" (Option.get winner)
(* winner가 None이면? *)
```

```ocaml
(* lib/bounded.ml:389, lib/handover_eio.ml:204 *)
if Option.is_some warning then
  reason = Option.get warning  (* is_some 검사 후 get - 관용적이지 않음 *)
```

**개선**: `Option.value ~default:` 또는 패턴 매칭 사용

---

### 2. Result → Exception 변환 (타입 안전성 파괴)

```ocaml
(* lib/federation.ml:136 *)
task = (match json |> member "task" |> task_of_yojson with 
  | Ok t -> t 
  | Error e -> failwith e);  (* Result 모나드 의미 없음 *)
```

```ocaml
(* lib/room_utils.ml:243, 279 *)
| Error _ -> failwith "Failed to initialize any MASC backend"
```

```ocaml
(* lib/room_walph_eio.ml:93 *)
| Error msg -> failwith msg  (* "Raise outside mutex to avoid poisoning" 코멘트가 더 슬픔 *)
```

**개선**: `Result.bind`, `let*` 연산자로 에러 전파

---

### 3. 전역 Mutable 상태 (함수형 원칙 위반)

**가장 심각한 전역 상태들:**

```ocaml
(* lib/relay.ml:212 - 인메모리 데이터를 전역 ref로 *)
let checkpoints : checkpoint list ref = ref []

(* lib/mcp_server_eio.ml:25 - 의존성 주입 대신 전역 *)
let current_net : eio_net option ref = ref None

(* lib/mcp_server.ml:8-9 - 복잡한 상태를 전역으로 *)
let current_cell = ref (Mitosis.create_stem_cell ~generation:0)
let stem_pool = ref (Mitosis.init_pool ~config:Mitosis.default_config)

(* lib/validation.ml:17-18 - 레이트 리밋 상태 *)
let rejection_count = ref 0
let last_rejection_time = ref 0.0

(* lib/sse.ml:15, 18 - 카운터들 *)
let client_id_counter = ref 0
let event_counter = ref 0

(* lib/heartbeat.ml:16 *)
let heartbeat_counter = ref 0

(* lib/hebbian_eio.ml:71-73 - 메트릭 *)
let lock_acquisitions = ref 0
let lock_total_wait_ms = ref 0.0
let lock_max_wait_ms = ref 0.0
```

**총 23개 전역 ref** - 대부분 파라미터로 전달하거나 모듈 functor로 해결 가능

---

### 4. Mutex 패턴 비일관성

**좋은 패턴 (Fun.protect):**
```ocaml
(* lib/rate_limit.ml:57-58 *)
Mutex.lock limiter.mutex;
Fun.protect ~finally:(fun () -> Mutex.unlock limiter.mutex) f
```

**나쁜 패턴 (수동 try/with):**
```ocaml
(* lib/federation.ml:216-219 *)
Mutex.lock state_mutex;
| result -> Mutex.unlock state_mutex; result
| exception e -> Mutex.unlock state_mutex; raise e
```

```ocaml
(* lib/progress.ml:147-149 *)
Mutex.lock global.mutex;
let result = try f () with e -> Mutex.unlock global.mutex; raise e in
Mutex.unlock global.mutex;
```

**개선**: `Fun.protect` 또는 `Eio.Mutex.use_rw` 통일

---

### 5. ignore 남용 (41건)

```ocaml
(* lib/room.ml:2495 - 결과 무시 *)
ignore (leave config ~agent_name:effective_agent_name)

(* lib/mitosis.ml:740 *)
ignore (backend_set room_config ~key ~value:json_str)

(* lib/tool_task.ml:118, 152, 209, 223 *)
ignore (Metrics_store_eio.record ctx.config metric)
```

**개선**: `let _ =` 대신 명시적 `unit` 반환 함수 설계 또는 `|> ignore_result` 헬퍼

---

## ⚠️ 테스트 누락 모듈 (14개)

| 모듈 | 중요도 | 이유 |
|------|--------|------|
| `auto_recall` | 🔴 높음 | 핵심 기능 |
| `heartbeat` | 🟡 중간 | 상태 관리 |
| `institution_eio` | 🟡 중간 | Eio 통합 |
| `room_walph_eio` | 🔴 높음 | 복잡한 비동기 로직 |
| `room_worktree` | 🟡 중간 | Git 연동 |
| `sctp_eio` | 🟡 중간 | 네트워크 레이어 |
| `social` | 🟢 낮음 | 유틸리티 |
| `sse_client` | 🟡 중간 | 외부 통신 |
| `voice_bridge_eio` | 🔴 높음 | 실시간 통신 |
| `generational_metrics` | 🟢 낮음 | 메트릭 |
| `masc_mcp` | 🟢 낮음 | 진입점 |
| `tool_social` | 🟢 낮음 | 도구 |
| `version` | 🟢 낮음 | 상수 |
| `heartbeat_smart` | 🟢 낮음 | 유틸리티 |

---

## ✅ 잘한 점

### 1. Obj.magic 없음
타입 시스템을 우회하는 코드가 전혀 없음.

### 2. Result/Option 적극 활용
- Result 사용: ~1,957건
- Option 사용: ~2,788건
- 예외 발생: 33건 (0.07% 비율)

### 3. Eio 현대적 사용

```ocaml
(* lib/voice_bridge_eio.ml - 타임아웃 패턴 *)
Eio.Fiber.first read_once (fun () ->
  Eio.Time.sleep clock timeout;
  raise Timeout)
```

```ocaml
(* lib/session.ml - OCaml 5.4 Atomic Fields *)
type rate_tracker = {
  mutable burst_used: int [@atomic];
  mutable last_burst_reset: float [@atomic];
}
```

### 4. 취소 처리 존재

```ocaml
(* lib/http_server_eio.ml:429 *)
| Eio.Cancel.Cancelled _ -> true

(* lib/resilience.ml:86 *)
if is_cancelled exn then raise exn;
```

### 5. ppx_deriving 활용
`[@@deriving yojson, show, eq]` 등 보일러플레이트 최소화

---

## 🔧 개선 방향

### 즉시 수정 (P0)

1. **Option.get 제거**
```ocaml
(* Before *)
|> Option.get

(* After *)
|> Option.value ~default:fallback
(* 또는 *)
|> function Some x -> x | None -> handle_error ()
```

2. **Result→failwith 제거**
```ocaml
(* Before *)
| Error e -> failwith e

(* After - Result 모나드 유지 *)
let* task = task_of_yojson json in
Ok { ... }
```

### 단기 (P1)

3. **전역 상태 제거**
   - `current_net` → Eio env에서 파라미터로 전달
   - `checkpoints` → 모듈 인스턴스화 (functor)
   - 카운터들 → Atomic 또는 모듈 상태로

4. **Mutex 패턴 통일**
```ocaml
(* 모든 Mutex 사용처에서 *)
let with_mutex mutex f =
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex)
    (fun () -> Mutex.lock mutex; f ())
```

### 중기 (P2)

5. **테스트 추가**
   - `room_walph_eio` (복잡한 비동기)
   - `voice_bridge_eio` (실시간)
   - `auto_recall` (핵심 기능)

6. **JSON 파싱 중복 제거**
```ocaml
(* 339개 member/to_* 호출 → ppx_yojson_conv 또는 헬퍼 함수 *)
let get_string json key = json |> member key |> to_string
let get_int_opt json key = json |> member key |> to_int_option
```

---

## 📈 정량적 지표

| 메트릭 | 값 | 평가 |
|--------|-----|------|
| 총 LOC | 48,577 | - |
| 테스트 파일 | 192개 | 양호 |
| 테스트 커버리지 (추정) | ~89% | 양호 |
| 예외/LOC 비율 | 0.07% | 우수 |
| 전역 상태 | 23개 | 개선 필요 |
| Obj.magic | 0건 | 완벽 |
| Option.get | 4건 | 개선 필요 |

---

## 결론

**전체 등급: B+**

코드베이스는 OCaml 5.x + Eio를 현대적으로 활용하고 있으며, 타입 안전성을 대체로 잘 유지. 그러나 일부 전역 상태와 `Option.get` 사용은 OCaml 커뮤니티 표준에 미달.

"창피한 코드"는 4-5개 핫스팟에 집중되어 있어 수정 범위가 제한적. 1-2일 리팩토링으로 A등급 달성 가능.

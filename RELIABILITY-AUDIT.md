# masc-mcp 안정성/신뢰성 분석 보고서

**분석 일시**: 2025-02-01  
**분석 범위**: `lib/*.ml` (125개 파일, ~48,575 LOC)  
**분석 관점**: 시스템 엔지니어 (프로덕션 운영)

---

## 요약

| 카테고리 | 심각도 | 발견 건수 |
|----------|--------|-----------|
| 에러 핸들링 | 🔴 Critical | 14 |
| 리소스 관리 | 🟠 High | 8 |
| 동시성 문제 | 🟠 High | 6 |
| 장애 전파 | 🟡 Medium | 4 |
| 복구 불가능 상태 | 🔴 Critical | 3 |

**긍정적 측면**:
- Result 타입 사용 빈도 높음 (1,923회)
- try/with 및 Fun.protect 적절히 사용 (100회)
- Eio.Mutex.use_rw로 안전한 락 관리 패턴 다수

---

## 🔴 Critical: 프로덕션에서 터질 것 같다

### 1. failwith로 인한 예기치 않은 크래시

```ocaml
(* mcp_server_eio.ml:34 - 서버 초기화 순서 의존 *)
let get_net () : eio_net =
  match !current_net with
  | Some net -> net
  | None -> failwith "Eio net not initialized - call set_net first"
```

**영향**: 서버 초기화 순서가 잘못되면 전체 MCP 서버 크래시  
**빈도**: 매 LLM 체인 호출마다 호출됨

```ocaml
(* room_utils.ml:653 - 초기화 안 된 상태에서 호출 *)
let ensure_initialized config =
  if not (is_initialized config) then
    failwith "MASC not initialized. Use masc_init first."

(* room_utils.ml:793 - 분산 락 실패 *)
failwith "Failed to acquire distributed lock"
```

**영향**: 분산 환경에서 락 획득 실패 시 전체 요청 실패

**발견 위치**:
| 파일 | 라인 | 패턴 |
|------|------|------|
| mcp_server_eio.ml | 34 | `failwith "Eio net not initialized"` |
| room_utils.ml | 653 | `failwith "MASC not initialized"` |
| room_utils.ml | 793 | `failwith "Failed to acquire distributed lock"` |
| room_walph_eio.ml | 54 | `failwith "Walph: agent_name cannot be empty"` |
| room_walph_eio.ml | 93 | `failwith msg` (Mutex 외부) |
| http_server_eio.ml | 307-308 | `failwith msg`, `failwith "impossible state"` |
| mind_eio.ml | 377 | `failwith "Invalid mind JSON"` |
| types.ml | 638 | `failwith "priority_agents must be a list"` |

---

### 2. Option.get / List.hd 사용 (빈 데이터에서 크래시)

```ocaml
(* bounded.ml:389 - warning이 None일 때 크래시 *)
reason = Option.get warning;

(* room.ml:2146 - winner가 None일 때 크래시 *)
| VoteApproved -> Printf.sprintf "Winner: %s" (Option.get winner)

(* tool_agent.ml:224 *)
) None scored |> Option.get
```

```ocaml
(* hebbian_eio.ml:257 - sorted가 빈 리스트면 크래시 *)
Some (List.hd sorted).to_agent

(* room.ml:2118 - winners가 빈 리스트면 크래시 *)
(true, VoteApproved, Some (fst (List.hd winners)))

(* void.ml:198 *)
| [] -> fst (List.hd scored)  (* fallback - 하지만 scored도 비어있다면? *)
```

**영향**: 빈 리스트/None 값에서 `Invalid_argument` 예외 발생

---

### 3. 복구 불가능 상태

```ocaml
(* cancellation.ml - TokenStore 전역 Hashtbl *)
let tokens : (string, token) Hashtbl.t = Hashtbl.create 64

(* cleanup이 있지만 자동 호출되지 않음 - 메모리 무한 증가 *)
let cleanup ~(max_age : float) : int = ...
```

**문제**: 
- 취소 토큰이 계속 쌓이지만 정리 루프 없음
- 재시작 없이는 메모리 회복 불가능
- 장기 운영 시 OOM 가능성

```ocaml
(* mcp_server_eio.ml:24 - 전역 상태 *)
let current_net : eio_net option ref = ref None
```

**문제**: 전역 ref가 한번 설정되면 변경 불가, 핫 리로드 불가능

---

## 🟠 High: 리소스 누수 가능성

### 4. 파일 핸들 누수 패턴

```ocaml
(* cache_eio.ml:100-104 - output_string에서 예외 시 close_out 안됨 *)
let oc = open_out path in
output_string oc content;  (* <- 여기서 예외 발생하면? *)
close_out oc;

(* 올바른 패턴 *)
Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
  output_string oc content
)
```

**발견 위치** (Fun.protect 없이 open_out/open_in 사용):

| 파일 | 라인 | 상태 |
|------|------|------|
| a2a_tools.ml | 120 | ⚠️ try/with 있지만 close 전 예외 시 누수 |
| auto_responder.ml | 32, 39, 134, 139, 171, 196, 322 | ⚠️ 다수 위험 |
| cache_eio.ml | 100, 114 | ⚠️ |
| config.ml | 71 | ⚠️ |
| encryption.ml | 70, 179, 191 | ⚠️ |
| federation.ml | 259, 275, 288 | ⚠️ |
| hebbian_eio.ml | 164, 180 | ⚠️ |
| mcp_server.ml | 334 | ⚠️ |
| mcp_server_eio.ml | 405, 568, 582, 633, 910 | ⚠️ |

---

### 5. Eio 컨텍스트에서 블로킹 호출

```ocaml
(* backend_eio.ml:494 - Eio 파이버 블로킹 *)
Unix.sleepf 0.001;  (* 1ms backoff *)

(* room_utils.ml:785, 818 *)
Unix.sleepf 0.05;

(* session.ml:296 *)
Unix.sleepf check_interval;

(* bounded.ml:322, 331 *)
Unix.sleepf (float_of_int delay_ms /. 1000.0);
```

**문제**: 
- Eio의 협력적 스케줄링 파괴
- 다른 파이버들이 블로킹됨
- 전체 서버 응답성 저하

**해결책**: `Eio.Time.sleep clock` 사용

---

## 🟡 Medium: 동시성 문제

### 6. 레거시 Mutex 패턴 (backend.ml)

```ocaml
(* backend.ml:187-189 - 수동 lock/unlock *)
let with_lock t f =
  Mutex.lock t.mutex;
  let result = try f () with e -> Mutex.unlock t.mutex; raise e in
  Mutex.unlock t.mutex;
  result
```

**문제**: 
- 직접 작성한 with_lock이지만, 예외 시 re-raise 후 이중 예외 발생 가능
- Eio 환경에서 레거시 Mutex 사용은 비권장

**대비**: backend_eio.ml은 `Eio.Mutex.use_rw`로 올바르게 구현됨 ✓

---

### 7. 가변 상태 과다

```
mutable 필드 수: 145개
```

**주요 가변 상태**:
- session.ml: `mutable last_activity`, `mutable is_listening`, `mutable message_queue`
- rate_tracker: `mutable burst_used` ([@atomic] 사용 - OK)
- cancellation.ml: `mutable cancelled`, `mutable callbacks`

**잠재적 문제**: 멀티 도메인 환경에서 레이스 컨디션

---

## 🟡 장애 전파

### 8. 조용한 에러 무시

```ocaml
(* federation.ml:409-418 *)
(** Log a federation event - best effort, ignores errors *)
| Error _ -> ()  (* Silently ignore directory creation failures *)
...
| Error _ -> ()  (* Silently ignore path errors *)
ignore (safe_append_file path ...)
```

**문제**: 
- Federation 이벤트 로깅 실패가 숨겨짐
- 디버깅 시 추적 불가
- 장애 원인 파악 어려움

---

### 9. 외부 프로세스 실행 (쉘 인젝션 + 블로킹)

```ocaml
(* auto_responder.ml:145, 328 *)
let ret = Unix.system bg_cmd in

(* notify.ml:162, 175, 181 *)
let _ = Unix.system cmd in

(* room_git.ml, room_worktree.ml - 다수 *)
Sys.command cmd = 0
let _ = Sys.command fetch_cmd in
```

**문제**:
- 쉘 인젝션 취약점 (cmd 변수에 사용자 입력 포함 시)
- 블로킹 호출 (Eio 스케줄러 차단)
- 외부 명령 실패 시 복구 로직 부재

---

## ✅ 긍정적 패턴 (권장)

### 안전한 Mutex 사용 (backend_eio.ml)
```ocaml
Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> ...)
```

### Fun.protect 사용 (planning_eio.ml)
```ocaml
Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
  really_input_string ic (in_channel_length ic)
)
```

### Atomic 필드 올바른 사용 (session.ml)
```ocaml
let get_burst_used tracker =
  Atomic.Loc.get [%atomic.loc tracker.burst_used]
```

---

## 개선 권장사항

### 즉시 조치 (P0)

1. **failwith → Result 타입 전환**
   ```ocaml
   (* Before *)
   failwith "Failed to acquire lock"
   
   (* After *)
   Error (LockAcquisitionFailed "timeout after 20 attempts")
   ```

2. **Option.get/List.hd 제거**
   ```ocaml
   (* Before *)
   Option.get warning
   
   (* After *)
   Option.value ~default:"unknown" warning
   (* or *)
   match warning with Some w -> w | None -> "unknown"
   ```

3. **Unix.sleepf → Eio.Time.sleep**
   ```ocaml
   (* Before *)
   Unix.sleepf 0.05;
   
   (* After *)
   Eio.Time.sleep clock 0.05;
   ```

### 단기 조치 (P1)

4. **파일 핸들을 Fun.protect로 감싸기**
5. **TokenStore 정리 루프 추가** (cron 또는 Eio fiber)
6. **외부 명령 실행에 Eio_process 사용**

### 중기 조치 (P2)

7. **mutable 상태 최소화** (불변 데이터 구조 + 함수형 업데이트)
8. **전역 ref 제거** (명시적 의존성 주입)
9. **에러 로깅 통합** (federation.ml의 조용한 무시 제거)

---

## 테스트 권장

```bash
# 스트레스 테스트 - 장시간 운영 시 메모리 증가 확인
# TokenStore, Session registry 메모리 사용량 모니터링

# 동시성 테스트 - 멀티 도메인 환경
# OCaml 5.x Domain.spawn으로 레이스 컨디션 검증

# 장애 주입 테스트
# - 분산 락 타임아웃
# - 네트워크 불안정
# - 디스크 풀
```

---

*Generated by reliability-audit subagent*

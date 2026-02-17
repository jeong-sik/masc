# MASC-MCP Security Vulnerability Audit

**감사 일시**: 2025-02-02
**검증 일시**: 2026-02-17
**분석 대상**: `lib/*.ml` (전체 코드베이스)
**관점**: 공격자 (Red Team)

---

## 요약

| 심각도 | 개수 | 해결 | 주요 영역 |
|--------|------|------|-----------|
| 🔴 Critical | 2 | 2/2 | 토큰 생성, Command Injection |
| 🟠 High | 4 | 1/4 | 권한 검사, 인증 기본값, 쉘 실행 |
| 🟡 Medium | 5 | 0/5 | 시간 비교, Rate Limit, 정보 노출 |
| 🟢 Low | 3 | 0/3 | 암호화 설정, DoS, 세션 관리 |

---

## 🔴 Critical (즉시 수정 필요)

### 1. 암호학적으로 안전하지 않은 토큰 생성 — ✅ RESOLVED
**파일**: `auth.ml:10-14` → `Mirage_crypto_rng.generate 32` 사용으로 수정됨

```ocaml
let generate_token () =
  let bytes = Bytes.create 32 in
  for i = 0 to 31 do
    Bytes.set bytes i (Char.chr (Random.int 256))
  done;
  ...
```

**문제**: `Random.int`는 암호학적으로 안전하지 않은 PRNG입니다. 인증 토큰은 예측 가능해지며 공격자가 브루트포스 또는 시드 추측으로 유효한 토큰을 생성할 수 있습니다.

**공격 시나리오**:
1. 서버 시작 시간 추측 (로그 등에서)
2. Random 시드 추측 (시작 시간 기반)
3. 토큰 시퀀스 예측

**권장 수정**:
```ocaml
let generate_token () =
  let bytes = Mirage_crypto_rng.generate 32 in  (* 이미 encryption.ml에서 사용 중 *)
  let hex = Buffer.create 64 in
  String.iter (fun c -> Buffer.add_string hex (Printf.sprintf "%02x" (Char.code c))) bytes;
  Buffer.contents hex
```

---

### 2. Command Injection 취약점 — ✅ RESOLVED
**파일**: `spawn.ml`, `spawn_eio.ml` → `Eio.Process.spawn` 직접 실행으로 수정됨

```ocaml
let full_command = Printf.sprintf "echo %s | timeout %d %s%s"
  (Filename.quote augmented_prompt) timeout config.command mcp_flags
```

**문제**: `Filename.quote`는 특정 문자열 패턴에서 우회될 수 있습니다. 특히:
- 백슬래시/뉴라인 조합
- 명령어 대체 (`$(...)` 또는 `` `...` ``)

**공격 시나리오**:
1. 악의적인 prompt 주입: `"; rm -rf / #`
2. MCP 도구를 통한 spawn 호출
3. 서버에서 임의 명령어 실행

**파일**: `spawn_eio.ml:158-165` (GLM 처리)
```ocaml
let escaped_prompt = String.concat "\\\"" (String.split_on_char '"' augmented_prompt) in
let json_body = Printf.sprintf ... escaped_prompt ...
Printf.sprintf "timeout %d curl ... -d '%s'" timeout json_body
```

**문제**: 수동 이스케이프가 불완전합니다. 작은따옴표(`'`)가 처리되지 않습니다.

**권장 수정**:
```ocaml
(* 방법 1: 파일로 전달 *)
let temp_file = Filename.temp_file "prompt" ".txt" in
Out_channel.with_open_text temp_file (fun oc -> output_string oc prompt);
let cmd = ["bash"; "-c"; Printf.sprintf "cat %s | timeout %d %s" temp_file timeout config.command]

(* 방법 2: Eio.Process.spawn으로 직접 실행 (권장) *)
Eio.Process.spawn proc_mgr ~stdin:(`String prompt) [config.command]
```

---

## 🟠 High

### 3. Fail-Open 권한 검사
**파일**: `auth.ml:179-181`

```ocaml
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | None -> Ok ()  (* Unknown tool - allow (fail-open for extensibility) *)
```

**문제**: 알려지지 않은 도구는 **기본적으로 허용**됩니다. 새로운 위험한 도구가 추가되면 권한 검사 없이 실행됩니다.

**권장 수정**:
```ocaml
| None -> Error (Forbidden { agent = agent_name; action = "unknown_tool:" ^ tool_name })
(* 또는 최소 권한 요구: CanReadState *)
```

---

### 4. 인증 기본 비활성화
**파일**: `auth.ml` (전체 흐름)

```ocaml
let default_auth_config = {
  enabled = false;  (* ⚠️ 기본값 *)
  require_token = false;
  ...
}
```

**문제**: 새로운 Room 생성 시 인증이 비활성화된 상태로 시작합니다.

**권장 수정**:
- 프로덕션 환경에서는 `enabled = true`를 기본값으로
- 또는 초기화 시 명시적 설정 강제

---

### 5. 쉘 명령어 실행 (room_worktree.ml)
**파일**: `room_worktree.ml:90, 95, 100-102, 155-156`

```ocaml
let cmd = Printf.sprintf
  "cd %s && git worktree add %s -b %s origin/%s 2>&1"
  root worktree_path branch_name resolved_base
```

**문제**: `root`, `worktree_path`, `branch_name` 값이 쉘 명령어에 직접 삽입됩니다. validation이 있지만 완전하지 않습니다.

**공격 시나리오**:
- `branch_name`에 `;` 또는 `$()` 포함 시 명령어 주입 가능

**권장 수정**:
```ocaml
(* Sys.command 대신 Eio.Process 사용 *)
Eio.Process.run proc_mgr ["git"; "worktree"; "add"; worktree_path; "-b"; branch_name; "origin/" ^ resolved_base]
```

---

### 6. 토큰 검증 누락 (MCP Session)
**파일**: `session.ml:322-335`

```ocaml
let get_or_create_mcp_session (headers : Cohttp.Header.t) : McpSessionStore.mcp_session =
  match extract_mcp_session_id headers with
  | Some id ->
    (match McpSessionStore.get id with
     | Some session -> session
     | None -> McpSessionStore.create ())  (* ID가 있으나 세션이 없으면 새로 생성 *)
  | None ->
    McpSessionStore.create ()
```

**문제**: 존재하지 않는 세션 ID로 요청하면 새 세션이 생성됩니다. 세션 하이재킹 방지가 불충분합니다.

---

## 🟡 Medium

### 7. ISO 문자열 시간 비교
**파일**: `auth.ml:138-142`

```ocaml
(* Simple ISO string comparison works for UTC *)
let now = now_iso () in
if now > exp_str then
  Error (TokenExpired agent_name)
```

**문제**: 문자열 비교는 시간대(timezone)가 다를 때 오동작합니다. UTC가 보장되지 않으면 토큰이 만료되지 않거나 즉시 만료될 수 있습니다.

**권장 수정**:
```ocaml
let is_expired exp_str =
  let exp_time = parse_iso exp_str in  (* Unix timestamp로 변환 *)
  Unix.gettimeofday () > exp_time
```

---

### 8. Rate Limit 우회 가능
**파일**: `session.ml:165-173`

```ocaml
if current >= limit then begin
  let burst = get_burst_used tracker in
  if burst < registry.config.burst_allowed then begin
    incr_burst_used tracker;  (* 버스트 허용 *)
    ...
    (true, 0)  (* Burst allowed *)
```

**문제**: 
- `burst_allowed` (기본값 50)만큼 추가 요청 가능
- 리셋 주기가 60초로, 분당 최대 `limit + 50` 요청 가능
- 다수의 agent_name 사용으로 우회 가능

---

### 9. 에러 메시지 정보 노출
**파일**: 여러 파일

```ocaml
(* http_server_eio.ml:282 *)
"500 Internal Server Error: %s" (Printexc.to_string exn)

(* spawn.ml:200 *)
"Spawn error: %s" (Printexc.to_string e)

(* validation.ml:35 *)
Printf.eprintf "[validation] WARN: %s rejected input '%s': %s\n"
  validator safe_input reason
```

**문제**: 상세한 에러 메시지와 스택 트레이스가 클라이언트에 노출됩니다.

**권장 수정**:
- 프로덕션에서는 일반적인 에러 메시지 반환
- 상세 정보는 서버 로그에만 기록

---

### 10. of_string_unsafe 함수 존재
**파일**: `validation.ml:48, 66`

```ocaml
val of_string_unsafe : string -> t  (* For internal use only *)
```

**문제**: "internal use only" 주석은 컴파일러가 강제하지 않습니다. 실수로 또는 의도적으로 validation 우회 가능.

**권장 수정**:
- `mli` 파일에서 이 함수를 노출하지 않음
- 또는 private type으로 구현

---

### 11. Hashtbl.find 예외 처리 누락
**파일**: 여러 파일

```ocaml
(* session.ml:112 *)
Hashtbl.remove registry.Session.sessions agent_name;
(* 존재하지 않아도 에러 없음 - 의도적이지만 확인 필요 *)
```

**일부 위치에서 find_opt 대신 find 사용 가능성**

---

## 🟢 Low

### 12. 암호화 기본 비활성화
**파일**: `encryption.ml:20-23`

```ocaml
let default_config = {
  enabled = false;  (* 기본 비활성화 *)
  key_source = `Env "MASC_ENCRYPTION_KEY";
  version = 1;
}
```

**문제**: 민감한 데이터(토큰, 세션)가 평문으로 저장됩니다.

---

### 13. 메시지 큐 DoS
**파일**: `session.ml:205-219`

```ocaml
session.message_queue <- session.message_queue @ [notification];
```

**문제**: 메시지 큐 크기 제한이 없습니다. 공격자가 대량의 broadcast로 메모리 고갈 가능.

**권장 수정**:
```ocaml
let max_queue_size = 1000 in
if List.length session.message_queue < max_queue_size then
  session.message_queue <- session.message_queue @ [notification]
else
  (* 오래된 메시지 삭제 또는 거부 *)
```

---

### 14. 세션 정리 미흡
**파일**: `session.ml`

- `McpSessionStore.cleanup_stale()`는 명시적으로 호출해야 함
- 자동 정리 스케줄러 없음
- 메모리 누수 가능성

---

## 권장 조치 우선순위

1. **즉시 (Critical)**
   - [x] `Random.int` → `Mirage_crypto_rng.generate` 교체 ✅ (auth.ml에서 CSPRNG 사용 확인, 2026-02-17)
   - [x] Command injection 수정: `Eio.Process.spawn` 직접 사용 ✅ (spawn_eio.ml에서 직접 프로세스 실행 확인, 2026-02-17)

2. **1주 내 (High)**
   - [ ] Fail-open → Fail-close 전환 (권한 검사) — auth.ml:236 여전히 `None -> Ok ()`
   - [ ] 프로덕션 기본값: `auth.enabled = true`
   - [x] `Sys.command` → `Eio.Process` 마이그레이션 ✅ (spawn.ml에서 쉘 명령어 패턴 제거 확인, 2026-02-17)

3. **2주 내 (Medium)**
   - [ ] 시간 비교 로직 수정 (Unix timestamp 사용)
   - [ ] 에러 메시지 sanitization
   - [ ] Rate limit 강화

4. **1개월 내 (Low)**
   - [ ] 암호화 기본 활성화 검토
   - [ ] 메시지 큐 크기 제한
   - [ ] 세션 자동 정리

---

## 추가 권장사항

### 코드 품질
- `with _ ->` 패턴 제거 (예외 무시 방지)
- `Safe_ops` 모듈 사용 일관성 확보
- 모든 외부 입력에 validation 적용

### 인프라
- TLS/HTTPS 강제 (현재 HTTP만 지원)
- 로그에서 토큰/비밀번호 필터링
- Security audit 로그 별도 저장

### 테스트
- Fuzzing 테스트 추가 (특히 입력 파싱)
- 권한 검사 단위 테스트
- Rate limit 통합 테스트

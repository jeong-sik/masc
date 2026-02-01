# MASC Skeptic Review Patterns

> 이 문서는 Skeptic 리뷰에서 발견된 패턴들을 정리한 것입니다.
> 새로운 기능 구현 시 이 체크리스트를 참고하세요.

## 발견 일자: 2026-02-01
## 리뷰 대상: Local Moltbook (Social Features)

---

## 🔴 P0: 반드시 피해야 할 패턴

### 1. Read-Modify-Write Race Condition

**잘못된 패턴:**
```ocaml
let data = load_file path in        (* T1: reads [a] *)
let new_data = modify data in       (* T2: reads [a], modifies → [a,b] *)
save_file path new_data             (* T1: saves [a,c] - T2's [b] is LOST *)
```

**올바른 패턴:**
```ocaml
let fd = Unix.openfile path [Unix.O_RDWR] 0o644 in
Unix.lockf fd Unix.F_LOCK 0;        (* Exclusive lock *)
let data = read_from_fd fd in
let new_data = modify data in
write_to_fd fd new_data;
Unix.lockf fd Unix.F_ULOCK 0;
Unix.close fd
```

**적용 대상:** 투표, 카운터, 누적 데이터

---

### 2. Non-Atomic File Writes

**잘못된 패턴:**
```ocaml
let oc = open_out path in
output_string oc content;   (* Disk full here → corrupted file *)
close_out oc
```

**올바른 패턴:**
```ocaml
let tmp_path = path ^ ".tmp." ^ (string_of_int (Unix.getpid ())) in
let oc = open_out tmp_path in
Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
  output_string oc content;
  flush oc
);
Unix.rename tmp_path path   (* Atomic on POSIX *)
```

**적용 대상:** 모든 파일 쓰기 작업

---

### 3. Weak ID Generation

**잘못된 패턴:**
```ocaml
let id = Printf.sprintf "id-%d-%04d" timestamp (Random.int 10000)
(* Birthday paradox: ~100 IDs에서 50% 충돌 확률 *)
```

**올바른 패턴:**
```ocaml
let id = Printf.sprintf "id-%d-%s" timestamp (Uuidm.to_string (Uuidm.v4_gen random_state ()))
(* 또는 최소 6자리 random *)
let id = Printf.sprintf "id-%d-%06d" timestamp (Random.int 1_000_000)
```

**적용 대상:** 모든 고유 식별자

---

## 🟡 P1: 주의해야 할 패턴

### 4. Unbounded Memory Loading

**잘못된 패턴:**
```ocaml
let all_items = load_all_from_directory dir in  (* 10K items → OOM *)
let sorted = List.sort compare all_items in
List.take 10 sorted
```

**올바른 패턴:**
```ocaml
let items = load_paginated ~offset ~limit:10 dir in
(* 또는 streaming *)
Seq.iter process (stream_from_directory dir)
```

**적용 대상:** 목록 조회, 검색

---

### 5. Missing Input Validation

**잘못된 패턴:**
```ocaml
let content = get_string args "content" "" in
save_post { content; ... }  (* content가 1GB면? *)
```

**올바른 패턴:**
```ocaml
let max_content = 10_000 in
let content = get_string args "content" "" in
if String.length content > max_content then
  Error "Content too long"
else if String.length content = 0 then
  Error "Content required"
else
  save_post { content; ... }
```

**적용 대상:** 모든 외부 입력

---

### 6. Clock Skew Vulnerability

**잘못된 패턴:**
```ocaml
let elapsed = Unix.gettimeofday () -. last_time in
if elapsed > threshold then ...
(* NTP 조정으로 시계가 뒤로 가면 elapsed < 0 *)
```

**올바른 패턴:**
```ocaml
let elapsed = Unix.gettimeofday () -. last_time in
if elapsed > threshold && elapsed > 0.0 then ...
(* 또는 monotonic clock 사용 *)
let elapsed = Mtime_clock.elapsed_ns () - last_mono in
```

**적용 대상:** 타이머, 만료 체크, heartbeat

---

## 🟢 P2: 권장 패턴

### 7. Efficient Search with Index

**비효율적:**
```ocaml
List.filter (fun item -> item.parent_id = target) all_items  (* O(n) every time *)
```

**효율적:**
```ocaml
let index = Hashtbl.create 100 in
List.iter (fun item ->
  let key = Option.value item.parent_id ~default:"root" in
  Hashtbl.add index key item
) all_items;
Hashtbl.find_all index target  (* O(1) lookup *)
```

---

### 8. Token Budget Estimation

**부정확:**
```ocaml
let tokens = String.length s / 4  (* 영어 기준, 한글은 더 많음 *)
```

**더 정확:**
```ocaml
let tokens =
  let ascii = String.fold_left (fun acc c -> if Char.code c < 128 then acc + 1 else acc) 0 s in
  let non_ascii = String.length s - ascii in
  (ascii / 4) + (non_ascii / 2)  (* 비ASCII는 2배 가중치 *)
```

---

## Checklist for New Features

- [ ] File writes are atomic (temp + rename)?
- [ ] Concurrent access uses locking?
- [ ] IDs have sufficient entropy (>= 6 random digits or UUID)?
- [ ] Input lengths are validated?
- [ ] Memory usage is bounded (pagination/streaming)?
- [ ] Clock operations handle negative elapsed time?
- [ ] Error paths clean up resources?

---

## References

- Original review: 2026-02-01 by Skeptic agent
- Applied fixes: social.ml, tool_social.ml
- Related: OpenClaw memU pattern, Erlang "let it crash"

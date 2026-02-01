# Spawn Persistence & Recovery Design

OpenClaw의 `subagent-registry.ts` 패턴을 MASC spawn에 적용하는 설계.

## 핵심 목표

1. **Spawn 결과 영속화**: 크래시 후에도 실행 기록 보존
2. **재시작 복구**: 미완료 spawn 자동 재개 또는 알림
3. **Sweeper 정리**: 오래된 기록 자동 정리
4. **에이전트 쿨다운**: 실패한 에이전트 일시 제외

## 데이터 구조

```ocaml
(** spawn_registry.ml *)

type spawn_record = {
  run_id: string;
  agent_name: string;
  prompt: string;
  started_at: float;
  ended_at: float option;
  exit_code: int option;
  output: string option;
  (* Cooldown tracking *)
  failure_count: int;
  last_failure_at: float option;
  cooldown_until: float option;
  (* Cleanup *)
  archive_at: float option;
}

(* In-memory registry *)
let registry : (string, spawn_record) Hashtbl.t = Hashtbl.create 64

(* Persistence path *)
let registry_path room_path =
  Filename.concat room_path "spawn_registry.json"
```

## 워크플로우

### 1. Spawn 시작 시

```ocaml
let spawn_with_persistence ~room_path ~agent_name ~prompt () =
  let run_id = Uuidm.(v `V4 |> to_string) in
  let record = {
    run_id;
    agent_name;
    prompt;
    started_at = Unix.gettimeofday ();
    ended_at = None;
    exit_code = None;
    output = None;
    failure_count = 0;
    last_failure_at = None;
    cooldown_until = None;
    archive_at = None;
  } in
  Hashtbl.replace registry run_id record;
  persist_registry room_path;  (* 디스크 저장 *)

  (* 실제 spawn 실행 *)
  let result = Spawn.spawn ~agent_name ~prompt () in

  (* 결과 업데이트 *)
  let updated = {
    record with
    ended_at = Some (Unix.gettimeofday ());
    exit_code = Some result.exit_code;
    output = Some result.output;
    archive_at = Some (Unix.gettimeofday () +. 3600.0);  (* 1시간 후 정리 *)
  } in
  Hashtbl.replace registry run_id updated;
  persist_registry room_path;

  result
```

### 2. 재시작 복구 (restoreOnce)

```ocaml
let restored = ref false

let restore_registry_once room_path =
  if !restored then ()
  else begin
    restored := true;
    let path = registry_path room_path in
    if Sys.file_exists path then begin
      let records = load_from_disk path in
      List.iter (fun record ->
        (* 미완료 작업 발견 *)
        if Option.is_none record.ended_at then
          Log.warn "Unfinished spawn: %s (agent=%s)"
            record.run_id record.agent_name;
        Hashtbl.replace registry record.run_id record
      ) records;
      start_sweeper room_path
    end
  end
```

### 3. Sweeper (60초 간격)

```ocaml
let sweeper_running = ref false

let start_sweeper room_path =
  if !sweeper_running then ()
  else begin
    sweeper_running := true;
    let rec loop () =
      Unix.sleep 60;
      sweep_registry room_path;
      loop ()
    in
    ignore (Thread.create loop ())
  end

let sweep_registry room_path =
  let now = Unix.gettimeofday () in
  let to_remove = ref [] in
  Hashtbl.iter (fun run_id record ->
    match record.archive_at with
    | Some at when at <= now ->
      to_remove := run_id :: !to_remove
    | _ -> ()
  ) registry;
  List.iter (Hashtbl.remove registry) !to_remove;
  if !to_remove <> [] then
    persist_registry room_path
```

### 4. 에이전트 쿨다운

```ocaml
let default_cooldown_seconds = 300  (* 5분 *)
let max_failures_before_cooldown = 3

let check_agent_cooldown agent_name =
  let now = Unix.gettimeofday () in
  Hashtbl.fold (fun _ record acc ->
    if record.agent_name = agent_name then
      match record.cooldown_until with
      | Some until when until > now ->
        Error (`In_cooldown (until -. now))
      | _ -> acc
    else acc
  ) registry (Ok ())

let record_agent_failure ~room_path agent_name =
  let now = Unix.gettimeofday () in
  (* 최근 실패 카운트 *)
  let recent_failures =
    Hashtbl.fold (fun _ record count ->
      if record.agent_name = agent_name
         && record.exit_code <> Some 0
         && Option.value ~default:0.0 record.ended_at > now -. 3600.0
      then count + 1
      else count
    ) registry 0
  in
  if recent_failures >= max_failures_before_cooldown then begin
    (* 쿨다운 설정 *)
    Log.warn "Agent %s entering cooldown (failures=%d)"
      agent_name recent_failures;
    Hashtbl.iter (fun run_id record ->
      if record.agent_name = agent_name then
        Hashtbl.replace registry run_id
          { record with cooldown_until = Some (now +. float default_cooldown_seconds) }
    ) registry;
    persist_registry room_path
  end
```

## 파일 위치

```
.masc/
├── spawn_registry.json    # 영속화된 레지스트리
├── spawn_logs/            # 개별 spawn 출력 로그
│   ├── {run_id}.log
│   └── ...
└── ...
```

## 설정 옵션

```json
{
  "spawn": {
    "archive_after_minutes": 60,
    "cooldown_seconds": 300,
    "max_failures_before_cooldown": 3,
    "sweeper_interval_seconds": 60
  }
}
```

## OpenClaw에서 배운 핵심 원칙

1. **persistSubagentRuns()**: 변경 시마다 즉시 저장 (크래시 안전)
2. **restoreSubagentRunsOnce()**: 재시작 시 단 1회만 실행 (중복 방지)
3. **startSweeper()**: lazy 시작 (필요할 때만)
4. **sweeper.unref?.()**: 프로세스 종료 블로킹 방지
5. **resumeSubagentRun()**: 미완료 작업 자동 재개 또는 알림

## 구현 우선순위

1. **Phase 1**: spawn_registry.json 영속화 (spawn.ml 수정)
2. **Phase 2**: restore_registry_once 구현 (서버 시작 시)
3. **Phase 3**: sweeper 구현 (Eio 기반)
4. **Phase 4**: 에이전트 쿨다운 로직

## 예상 효과

- **안정성 ↑**: 크래시 후에도 실행 기록 보존
- **가시성 ↑**: 미완료 작업 자동 감지 및 알림
- **자원 관리 ↑**: 오래된 기록 자동 정리
- **장애 내성 ↑**: 문제 에이전트 자동 쿨다운

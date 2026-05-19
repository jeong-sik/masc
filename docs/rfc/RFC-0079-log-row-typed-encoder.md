---
rfc: "0079"
title: "Log row typed encoder + silent-drop removal"
status: Draft
created: 2026-05-14
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0044", "0058", "0078"]
implementation_prs: [15211]
---

# RFC-0079: Log row typed encoder + silent-drop removal

## §1 Problem (caller-context)

`lib/masc_log/log.ml` 의 `Log.Ring.entry_to_json` (구 line 248-270) 은 `Yojson.Safe.Assoc [...]` 직접 어셈블 — typed encoder 없음. `entry.level` / `entry.source` 모두 `string` 으로 저장 (line 182-195 의 record 정의). `entry_of_json` (line 307-336) 가 strict pattern match 실패 시 `Some _ | None` 으로 silent `None` 반환 — 그 row 가 read-side dashboard 까지 흘러가서 *결국 dashboard 가 drop*.

Dashboard 측 (`dashboard/src/api/schemas/logs.ts:34-103`) 은 그 무효 row 를 silently 제외하고 `dropped_entries` counter 로 *RFC-0042 #1 "telemetry-as-fix"* 안티패턴 그대로 보여준다. PR #15170 (`fix(dashboard): surface dropped log rows`) 이 그 counter 를 toolbar 에 노출시키려고 한 것을 거부했고 (memory `feedback_hardcoding_and_legacy_zero_tolerance` 적용), RFC-0079 는 그 자리에 들어가는 root-fix.

추가 잔재:

- `Ring.entry` 의 `raw_level: string` / `normalized_level: string` / `legacy_classified: bool` (line 182-195) — *pre-typed string→level migration* 의 분류기 상태. 작성 시점에 level 을 받아 *동일 string* 으로 raw_level/normalized_level 둘 다 채우거나, `infer_legacy_level` (line 72-87) 이 message body 의 `[FATAL]/[ERROR]/...` prefix 보고 추정. caller 전수 (`bin/main_eio.ml:528-540`, `lib/server/server_startup_takeover.ml` 9 자리, `lib/backend/backend.ml` 5 자리, `lib/mcp_server_eio_resource.ml:62`, `lib/coord/coord_query.ml:245-285`) 이 *이미* `~level:Log.Error/Warn/Debug` 명시. `?level` 옵션 + classifier 는 dead path.
- `dashboard/src/components/logs.ts:115` `normalizedLevel(entry)` 가 `entry.normalized_level || entry.level || 'INFO'` 으로 read-side 폴백 — pre-typed 잔재.
- 같은 파일 :473 `rawLevelChanged` , :517-521 `legacy_classified` 배지 + `raw_level` MetaTag — *backend 분류기 동작 자체* 를 UI 로 노출. 분류기가 없어지면 같이 사라져야 한다.

## §2 Approach

세 부위 동시 정리:

**Backend** (`lib/masc_log/log.ml{,i}`)

- `Ring.entry` 를 typed: `level : level`, `source : source`. `raw_level`/`normalized_level`/`legacy_classified` 필드 *삭제*.
- `entry_to_json` 은 exhaustive match — 새 `level` / `source` variant 추가 시 컴파일러가 wire format 누락 catch.
- `entry_of_json` 은 `exception Entry_decode_error of string` raise. silent `None` 경로 0.
- `source_of_string` 추가 (writer 와 colocated). unknown 라벨은 raise.
- `Ring.push` 시그니처: `~level : level`, `?source : source`, 그리고 `?raw_level` / `~normalized_level` / `?legacy_classified` *삭제*.
- `legacy_stderr` / `legacy_traceln` 시그니처: `?level : level` → `~level : level` (필수). 사용자 caller 가 모두 명시이므로 caller 변경 0.
- `infer_legacy_level` 함수 *삭제*.

**File-fold boundary** (`Ring.load_from_file`)

`Fs_compat.fold_jsonl_lines` 의 callback 안에서 `Entry_decode_error` 잡고 stderr WARN + skip. 이건 *legacy JSONL 파일* (구 schema) 호환을 위한 1자리 tolerance — `cleanup_old_files` 가 7일 후 자동 삭제하므로 windowed legacy. **read-side repair / counter / metric 추가 없음**.

**Dashboard** (`dashboard/src/api/schemas/logs.ts`, `components/logs.ts`, test fixtures)

- `LogEntrySchema` 단순화: `seq/ts/level/source/module/message/keeper_name/turn_id/details`. fallback/transform/optional 체인 *삭제* (`raw_level`/`normalized_level`/`legacy_classified` 모두 wire 에서 사라짐).
- `LogsResponseSchema` 의 `total` 도 strict (fallback 없음).
- `parseLogsResponse` 가 row 무효 시 `LogsSchemaDriftError` *throw* (silent skip 안 함). `dropped_entries` 필드 + 계산 *삭제*.
- `components/logs.ts`: `normalizedLevel` 폴백 체인 → `entry.level.toUpperCase()`. `rawLevelChanged`, `legacy_classified` 배지, `raw_level` MetaTag, `dropped_entries` count UI / summary chip / counter 모두 *삭제*.
- test fixture: `raw_level`/`normalized_level`/`legacy_classified` 제거, `keeper_name`/`turn_id` 추가. `surfaces parser-dropped log rows` 테스트는 *기능 삭제와 함께* 제거.

## §3 Wire format

after RFC-0079, 한 row 의 JSON shape:

```
{
  "seq": 42,
  "ts": "2026-05-14T05:00:00Z",
  "level": "INFO",
  "source": "structured",
  "module": "Keeper",
  "keeper_name": null,
  "turn_id": null,
  "message": "booted",
  "details": null
}
```

`level` ∈ `{"DEBUG","INFO","WARN","ERROR"}` (closed). `source` ∈ `{"structured","legacy_stderr","legacy_traceln","client_tool_host"}` (closed, lowercase). encoder/decoder 가 같은 closed sum 을 공유.

## §4 Non-goals

- `source` variant 의 `Legacy_stderr` / `Legacy_traceln` 이름 자체는 *그대로 유지*. 그것이 "stderr/traceln mirror" 라는 채널 의미이고 deprecated 채널은 아니다. 채널 자체의 retirement 는 별도 RFC.
- 본 PR 머지 직후 7일간 windowed legacy JSONL tolerance — `cleanup_old_files` 가 끝내므로 별도 migration script 불필요.
- Log routine event class (`event_class : Routine`) wire 표현 — 현재 `details.event_class` 안 별도. RFC scope 밖.

## §5 Verification

1. backend build: `MASC_SKIP_PIN_CHECK=1 scripts/dune-local.sh build bin/main_eio.exe` 통과
2. dashboard typecheck: `pnpm --dir dashboard exec tsc --noEmit --pretty false` 통과
3. dashboard vitest: `pnpm --dir dashboard exec vitest run src/api/schemas/logs.test.ts src/components/logs.test.ts`
4. 새 백엔드 테스트 `test/test_log_ring_encoder.ml` — typed entry round-trip + dashboard wire shape golden + Entry_decode_error 사례 (missing field, unknown level, unknown source) 가 raise
5. 로컬 서버 가동 후 dashboard 의 logs panel — 모든 row visible, "dropped rows" / "classified" / raw_level meta 배지 부재

## §6 Citations

- `lib/masc_log/log.ml:182-195` — pre-RFC-0079 `Ring.entry` (raw_level/normalized_level/legacy_classified 포함)
- `lib/masc_log/log.ml:248-270` — pre-RFC-0079 `entry_to_json`
- `lib/masc_log/log.ml:307-336` — pre-RFC-0079 `entry_of_json` silent None 경로
- `lib/masc_log/log.ml:72-87` — `infer_legacy_level` string-prefix classifier (사용자 원칙 #1 위반)
- `lib/masc_log/log.ml:547-565` — `emit_legacy_raw` / `legacy_stderr` / `legacy_traceln` `?level` 옵션 (dead path, caller 전수 명시)
- `dashboard/src/api/schemas/logs.ts:34-103` — read-side schema + dropped_entries counter (RFC-0042 #1 telemetry-as-fix)
- `dashboard/src/components/logs.ts:115` — `normalizedLevel` 폴백 체인
- `dashboard/src/components/logs.ts:473,517-521` — `rawLevelChanged` + `legacy_classified` 배지 + raw_level MetaTag
- memory `feedback_hardcoding_and_legacy_zero_tolerance` — 사용자 절대 원칙
- plan `~/.claude/plans/cheeky-questing-glade.md` §F1

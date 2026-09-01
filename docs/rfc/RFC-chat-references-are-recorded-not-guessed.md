---
rfc: "chat-references-are-recorded-not-guessed"
title: "대화의 명시 참조와 해석된 언급을 구분해 기록한다"
status: Draft
created: 2026-08-31
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: 대화의 명시 참조와 해석된 언급을 구분해 기록한다

## 0. 결정 요약

대화에서 task·goal·board 대상으로 이동하려면 읽는 시점의 문자열 검색이 아니라
write boundary에 남은 typed data가 필요하다. 그러나 산문에서 ID 모양 토큰을
찾아 실제 store row에 resolve했다는 사실은 **글쓴이가 그 대상을 참조했다는
증거가 아니다**. 타입에 넣어 저장해도 추론의 출처는 바뀌지 않는다.

따라서 두 개념을 별도 필드와 별도 provenance로 기록한다.

- `explicit_references`: producer가 구조화 인자로 넘겼거나 글쓴이가 명시적 링크
  문법을 사용한 권위 있는 참조. TUI의 기본 따라가기 대상이다.
- `resolved_mentions`: 산문 토큰을 중앙 파서가 찾고 당시 store에서 존재를
  확인한 해석 결과. “언급 후보가 그때 존재했다”만 증명하며, 참조나 의도를
  주장하지 않는다.

기본 구현선은 producer-owned `explicit_references`다. 산문 해석은 정확도와
비용을 실측한 뒤 별도의 보조 인덱스로만 판단한다.

## 1. 사용자 기능

### AS-IS

- 대화 본문에 `task-123` 같은 텍스트가 있어도 선택 가능한 typed target이 없다.
- TUI가 렌더마다 정규식으로 링크를 합성하면 독자가 글쓴이 대신 관계를 만든다.
- 소비자마다 다른 정규식과 조회 시점으로 같은 메시지가 다른 곳을 가리킬 수 있다.

### TO-BE

- producer가 알고 있는 target을 메시지 append와 함께 구조화해 저장한다.
- TUI는 `explicit_references`만 기본 참조 커서와 `Enter` 이동에 사용한다.
- `resolved_mentions`를 노출한다면 “해석된 언급”으로 별도 표시하고 명시 참조와
  같은 시각·행동 의미를 주지 않는다.
- 읽는 쪽은 산문을 재파싱하지 않고 저장된 typed 값과 provenance만 읽는다.

## 2. 초안 측정의 정정

초안은 2026-08-31 workspace 대화에서 ID 모양 토큰 8,597건과 본문 `masc://`
0건을 보고했다. 이 값은 참조 수가 아니라 **문자열 형태의 출현 수**다. 부정문,
인용, 코드, 도구 출력, 존재하지 않는 ID가 섞일 수 있다.

또 초안의 공개 재현 코드는 다음 이유로 그대로는 재현되지 않는다.

```python
glob.glob('~/me/.masc/keeper_chat/*.jsonl')
```

Python `glob`은 `~`를 home directory로 확장하지 않는다. 따라서 게시된 명령과
보고값 사이의 identity chain이 끊겼다. 8,597는 설계 동기가 된 과거 보고값으로
남기되, acceptance evidence로 사용하지 않는다.

재측정은 실제 base path를 인자로 받고, 대상 파일 목록과 digest를 먼저 남긴 뒤
`content`만 세어야 한다. 최소 형태는 다음과 같다.

```python
from pathlib import Path
import collections, hashlib, json, re, sys

root = Path(sys.argv[1]).resolve()
paths = sorted((root / ".masc" / "keeper_chat").glob("*.jsonl"))
patterns = {
    "task": re.compile(r"\btask-\d+\b"),
    "goal": re.compile(r"\bgoal-[a-z0-9][a-z0-9-]{4,}\b"),
    "board": re.compile(r"\bp-[0-9a-f]{16,}\b"),
    "link": re.compile(r"masc://[a-z/]*"),
}
counts = collections.Counter()
for path in paths:
    print(path, hashlib.sha256(path.read_bytes()).hexdigest())
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        content = json.loads(line).get("content")
        if isinstance(content, str):
            for kind, pattern in patterns.items():
                counts[kind] += len(pattern.findall(content))
print(counts)
```

이 재측정도 토큰 수만 준다. 실제 target resolution 수와 문맥별 오분류 표본은
별도 결과다.

## 3. 데이터 계약

대상 자체는 닫힌 합타입이다.

```ocaml
type target =
  | Task of Task_id.t
  | Goal of Goal_id.t
  | Board_post of Post_id.t
```

명시 참조와 해석 언급은 같은 리스트에 넣지 않는다.

```ocaml
type explicit_reference_source =
  | Producer_argument
  | Marked_link

type explicit_reference = {
  target : target;
  source : explicit_reference_source;
}

type mention_resolution_source =
  | Append_parser of { parser_version : int }
  | Offline_backfill of { parser_version : int; run_id : string }

type resolved_mention = {
  target : target;
  token : string;
  resolved_at : float;
  source : mention_resolution_source;
}
```

`chat_message`에는 `explicit_references`와 `resolved_mentions`가 별도 필드로
존재한다. 소비자가 합치려면 두 변종을 exhaustive하게 처리해야 하므로 보조
언급이 조용히 권위 있는 링크로 승격되지 않는다.

## 4. 생성 경로

### 4.1 정확 경로 — 기본안

`masc_broadcast`와 `masc_keeper_msg`가 optional `references` 인자를 받는다.
producer는 이미 보유한 typed ID를 넘기며 append 경계는 target 존재와 권한을
검증한 뒤 `Producer_argument`로 저장한다.

명시적 `masc://...` 또는 별도로 정의한 marker 문법은 글쓴이가 만든 관계이므로
`Marked_link`가 될 수 있다. 단순 `task-123` 산문은 이 경로에 들어오지 않는다.

### 4.2 해석 경로 — 보조안

중앙 parser가 ID 모양 토큰을 찾고 store 존재를 확인할 수 있다. 결과는
`resolved_mentions`일 뿐 `explicit_references`가 아니다.

- 존재 확인은 target이 그 시점에 있었다는 사실만 더한다.
- “task-123은 하지 않는다”, 코드 예제, 인용문도 resolved mention이 될 수 있다.
- 조회 비용은 store 종류 3개로 고정되지 않는다. 후보 수, 중복 제거, batch lookup
  지원 여부에 따라 달라진다.
- parser와 resolver는 write/backfill 경계 한 곳에만 있고 TUI/dashboard는 이를
  재구현하지 않는다.

## 5. 과거 데이터

append 경계 변경은 이미 저장된 메시지를 바꾸지 않는다. 따라서 “기존 8,597건이
그대로 살아난다”는 초안의 주장은, 동시에 backfill을 범위에서 제외한 문장과
모순이었다.

과거 행을 다루려면 별도 offline backfill이 필요하다. backfill은:

- 입력 파일 목록과 digest, parser version, run id를 기록한다.
- 원본 메시지를 변경하지 않고 `Offline_backfill` provenance를 남긴다.
- 존재 확인 비율뿐 아니라 부정문·인용·코드·tool output 표본의 오분류를 센다.
- 결과가 낮거나 문맥 오분류가 크면 저장하지 않고 실험 artifact로만 남긴다.

backfill은 이 RFC의 첫 구현 PR 범위가 아니다.

## 6. 구현 순서

1. `target`과 `explicit_reference` wire/store round-trip.
2. producer 도구의 optional `references` 인자와 append validation.
3. TUI explicit-reference 커서, 따라가기, `Esc` 복귀.
4. 정확 base path와 input digest를 가진 corpus 재측정.
5. `resolved_mentions`의 resolution yield·문맥 오분류·비용을 보고 채택 여부 결정.
6. 채택하는 경우에만 append parser와 별도 backfill RFC/도구를 구현.

## 7. 검증

- producer가 넘긴 존재 target은 동일 typed value와 `Producer_argument` provenance로
  round-trip한다.
- 존재하지 않거나 권한 밖 target은 fail-closed하고 문자열로 강등하지 않는다.
- plain `task-123` 산문은 `explicit_references`에 들어가지 않는다.
- explicit reference가 없는 대화에서 참조 커서는 “없음”을 표시한다.
- `resolved_mentions`가 도입돼도 TUI가 이를 explicit reference와 같은 배지나
  기본 이동 대상으로 렌더하지 않는 회귀 테스트를 둔다.
- corpus 측정은 input path/digest, parser version, 후보 수, resolve 수, 문맥 표본을
  한 artifact에서 함께 남긴다.

## 8. 열린 결정

- producer 도구가 target ID를 이미 알고 있는 호출의 실제 비율.
- 명시 marker를 `masc://` 하나로 제한할지 별도 문법을 둘지.
- resolved mention을 UI에 보일 가치가 있는지, 검색 인덱스로만 둘지.
- backfill의 보존 위치와 rollback 단위.

이 네 항목은 explicit-reference 본선 구현을 막지 않는다. 반면 산문 parser를
권위 있는 reference 생성기로 만드는 결정은 이 RFC가 명시적으로 거부한다.

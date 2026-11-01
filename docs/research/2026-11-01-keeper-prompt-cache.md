# Keeper System Prompt 크기와 prefix cache

2026-11-01 조사. 대상은 Context 상세의 `code-reviewer-father`, GLM-5.3이다.
기준 소스는 `e49cce0508d5e3f5b740abdd01f217b3efc8f6ba`다.
[측정 기록](../evidence/keeper-prompt-cache-20261101/README.md)은 원문을 공개하지 않고
보존된 요청의 길이·해시·공통 prefix와 provider가 보고한 사용량을 구분한다.

## 확인한 현상

Context 화면의 항목별 `≈ tok`는 tokenizer 결과가 아니다.
`bin/masc_tui_token_scale.ml`은 해당 요청 전체의
`input_tokens / request_body_bytes`로 각 항목의 바이트를 환산한다.
따라서 동일한 System Prompt도 다른 메시지가 들어오면 토큰 추정치가 달라진다.
System의 실제 변경은 바이트 길이와 SHA-256으로 판별해야 한다.

| 턴 | System bytes | 직전 턴과 같은 앞부분 | 마지막 보고 입력 토큰 | cache read | read / input |
| --- | ---: | ---: | ---: | ---: | ---: |
| 297 | 126,600 | 비교 없음 | 580,070 | 578,496 | 99.7% |
| 298 | 126,600 | 126,500 bytes | 82,829 | 78,080 | 94.3% |
| 299 | 126,600 | 126,500 bytes | 76,393 | 75,648 | 99.0% |
| 300 | 125,780 | 125,617 bytes | 79,115 | 65,280 | 82.5% |
| 301 | 125,780 | 125,705 bytes | 89,879 | 85,696 | 95.3% |

300→301의 첫 차이는 System 맨 뒤에 붙은 예약 입력 관측의 `turn_ref`다.
43개 도구 스키마는 네 번의 연속 비교에서 모두 동일했다.
최신 조립 기록에서 고정 지침은 53,361 bytes이고, 그 뒤에 열린 Goal의 관측과
예약 입력 관측이 붙는다. 이 최신 조립 기록은 위 요청 스냅샷과 별도 관측이다.

마지막 요청만 보면 턴 사이 캐시를 과대평가할 수 있다. 수집한 raw per-request
사용량 43건에서는 턴별 첫 **관측** 요청 6건의 미재사용 비율 중앙값이 24.9%,
그 뒤 요청 37건은 1.1%였다. 첫 요청에서 미재사용된 입력이 전체 미재사용 입력의
큰 부분을 차지한다. 관측 시작 전에 있었던 요청은 알 수 없고, 그 차이의 원인을
System suffix 하나로 확정할 수는 없다. 대기 간격, 모델·도구 변경, 전송하는 이력의
앞부분도 함께 봐야 한다.

## 공식 구현 계약과 비교

- [Z.AI Context Caching](https://docs.z.ai/guides/capabilities/cache)은 자동 캐싱과
  `usage.prompt_tokens_details.cached_tokens`를 제공한다. 문서는 동일한 System과
  대화 이력을 유지하도록 안내한다. 캐시 세부 배치·TTL은 이 문서만으로 확정하지 않는다.
- [OpenAI Prompt Caching](https://developers.openai.com/api/docs/guides/prompt-caching)은
  고정 내용을 앞에, 변동 내용을 뒤에 놓고 이전 대화의 앞부분을 보존하도록 안내한다.
  캐시 경계·보존 정책은 모델별 계약을 확인해야 하며, 다른 provider에 설정을 복사하지 않는다.
- [Anthropic Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)은
  tools→system→messages 순서의 prefix와 명시적 경계를 사용한다. 변하는 System suffix
  앞에 고정 부분의 경계가 없으면 그 부분을 독립적으로 재사용하기 어렵다.
  wire의 `input_tokens`는 cache read/create를 제외하므로 합산한 전체 입력을 분모로 써야 한다.
  Agent Core의 Anthropic decoder는 이미 이 합산을 수행한다.

## 적용 범위

1. 요청 상세에 provider가 보고한 input/cache read와 비율을 표시한다. per-request이고
   입력이 양수이며 cache read가 입력 이하일 때만 비율을 계산한다. 누락은 0과 구분한다.
   사용량은 **이 턴의 마지막 보고 요청**으로 표시한다. pre-dispatch 스냅샷과 사용량 사이에는
   response-to-capture ID가 없으므로 같은 스냅샷의 cache hit라고 부르지 않는다.
2. 종류별 요약에 실제 bytes를 추가하고, 환산 비율이 바뀌면 추정 토큰도 바뀐다고 알린다.
   System 항목의 `F fixed`는 `P system prompt`로 바꾼다. System에는 턴 관측도 들어간다.
3. 기존 `scripts/analysis/prefix-cache-first-round.py`에 Keeper 선택과 검증된 System
   blob 비교를 추가한다. 실제 길이·SHA가 맞을 때만 공통 prefix를 계산한다. 누락된 해시끼리는
   같은 내용으로 세지 않고, 누적 사용량은 per-request 통계에 섞지 않는다.

다음 구현 범위는 Anthropic의 고정 System prefix에 issuer가 지정한 경계를 전달하는 것이다.
고정 지침과 변동 관측을 System 블록으로 유지하고 serializer와 signed-thinking prefix의
블록 구조를 함께 맞춰야 한다. 이는 위 GLM 표본의 성능 개선 증거가 아니다.
변동 관측을 이력 뒤로 옮기는 변경은 provider별 메시지 권한·순서 계약을 별도로 검증해야 한다.

이번 단계는 소스 변경과 보존 기록의 재측정이다. 설치된 TUI의 화면 변경, 새 runtime의
실제 cache hit, TTFR/latency 개선은 아직 검증하지 않았다. 로컬 Dune 빌드와 CI 대기는
실행하지 않았다.

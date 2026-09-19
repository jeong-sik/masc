# TypeSafe Jev replay 근거 기록

- 대상 연구: [2026-09-18-typesafe-jev-masc-applicability-r1.md](2026-09-18-typesafe-jev-masc-applicability-r1.md)
- 실험일: 2026-09-18 (KST)

## 공통 헤더

- 날짜(ISO8601): 2026-09-18T09:38:00+09:00
- 작성자: MASC research session (개별 agent identity는 기록되지 않음)
- 결정 ID: typesafe-jev-applicability-r1
- 적용 대상: board_attention exact-output 판단 레인 연구
- 결정 상태: 보류

## 근거 (Evidence)

- 항목: Jev가 이 표본에서 기존 board_attention judge와 같은 판정을 내리는지 측정
- 출처: https://docs.typesafe.ai 및 아래 고정 SHA-256 원장과 35개 원시 결과
- 확인일시: 2026-09-18T09:38:00+09:00
- 신뢰도: Medium
- 제한조건: historical baseline이 전부 relevant이며 인간 정답 라벨과 production 적용 증거가 없음

- API 실호출 35회: `POST https://api.typesafe.ai/v1/systemone`, 요청 모델
  `jev-latest`. 실행자는 응답 모델명 `jev-1.13.0`을 관측했지만 당시
  결과 파일에 이 필드를 저장하지 않아 커밋된 증거로는 확인할 수 없다.
- 문서: docs.typesafe.ai introduction / primitives / confidence / patterns / quickstart, typesafe.ai (2026-09-18 열람).
- 판정 이력(피실험 데이터): `<base-path>/.masc/board_attention_candidates/wkbl-builder.jsonl`
  (base-path = wkbl 워크스페이스 루트, MASC_BASE_PATH)
  — 기존 judge 판정이 담긴 줄 25개(consumed 17 + judged 8, 전부 `relevant`, rationale 포함).
  원장은 상태가 바뀔 때마다 줄을 덧붙인다. 그래서 judged 뒤 consumed 된 후보는 두 줄에 나온다.
  `candidate_id` 로 세면 고유 후보는 17건이고, 그중 8건은 두 번 재생됐다(부록 B).
- 재현 스크립트와 호출별 원시 기록: 아래 부록 A(스크립트), 부록 B(results.jsonl 전문).

## Timestamp

- 2026-09-18T09:30+09:00 문서 열람
- 2026-09-18T09:38+09:00 실험 실행 (35호출, 수분 내 종료)

## Confidence

- 문서 내용: High (공식 문서 직접 열람)
- 가격·성능 주장(238배/444배 등): Low (회사 자체 벤치마크, 조건 미공개)
- replay 등가성: Medium (합성 음성 포함, 호출 35번·고유 후보 27건, 인간 라벨 없음)
- 비용 비교 배수(30~250배): Low (원 judge 실측 usage 부재, 가격 대입 추정)

## Delta

masc의 exact-output 레인 6종과 개념이 겹친다는 점에서, 레인 모델 선택지에
"판단 전용 저가 모델" 축이 생겼다. 본 기록 시점까지 코드 반영은 없다(연구만).

## 검증 (Verification)

- 1차: TypeSafe 공식 문서의 API, primitive, confidence, 가격 설명을 확인
- 2차: 원장 SHA-256과 historical 호출 수 25개, 고유 후보 수 17개를 재계산
- 3차: Jev API 35회 호출과 합성 negative 10개를 실행
- 재현 결과: 커밋된 결과 35행의 합의, 토큰, 지연, 오류 수는 재계산 가능. 응답 모델 버전은 저장되지 않아 재검증 불가

## 불확실성 (Uncertainty)

- 미확인 항목: 응답 모델의 정확한 버전, 인간 라벨 정확도, 실제 기존 judge 비용
- 영향: 이 결과만으로 production 기본 레인이나 외부효과 권한 판단을 바꾸면 과대 적용이 됨
- 추가 확인 필요: 인간 라벨과 음성 실데이터를 포함한 shadow replay 및 응답 provenance 저장

## 적용범위 (Scope)

- 영향 받는 영역: board_attention과 유사한 저비용 typed judgment 후보 평가
- 제약/배제: turn FSM, admission, HITL 권위, 기존 exact-output 레인의 production 동작
- 롤백 조건: 고정 표본 검증 실패, 데이터 반출 승인 부재, shadow replay 불일치

## 실험 설계

- 단위: board attention 후보 1건 = 호출 1회. state는 `keeper_context`(약 2.5KB)와
  board signal(title/content/author/kind)의 JSON 직렬화.
- 질문 3개(호출당): Choice(relevance: relevant/not_relevant), Noul(relevance 확률),
  Score(맥락만으로 판정 확신도 3레벨).
- 판정 기준 문구는 기존 judge rationale에서 추출한 문장으로 근사했다:
  "content connection to the keeper's tasks, not keywords, votes, or author reputation".
- 합성 negative 10건: wkbl-builder 업무(서비스 복구, 광고 수익)와 무관한 일상 주제 8건 +
  주제가 인접한 경계선 2건(다른 프로젝트의 Railway 상태, 다중 에이전트 프레임워크 잡담).
  baseline에 음성이 0건이라 specificity 측정을 위해 연구자가 직접 만들었다.
- 데이터 반출: 이 실험으로 api.typesafe.ai 에 요청 35번이 나갔다. 모든 요청에 wkbl keeper context 가 실렸고,
  wkbl board 원문은 고유 후보 17건이 25번 실렸다(나머지 10번은 합성 negative).

## 결과 요약

| 항목 | 값 |
|---|---|
| historical 합의(고유 후보 17건, 호출 25번, 전부 relevant) | 호출 25/25, 후보 17/17 |
| 합성 negative specificity | 10/10 |
| Noul↔Choice 교차 일관성 | 호출 35/35 |
| 총 input / output tokens | 48,742 / 2,635 |
| 총 비용 | $0.002 (호출당 $0.00006) |
| 지연 평균 / 최대 | 0.66s / 1.03s (클라이언트에서 잼, `urllib` 이 호출마다 새 연결을 연다) |
| HTTP 에러 | 0건 |

경계선 2건의 세부:

- synthetic-neg-07 "다른 프로젝트의 Railway 상태 이야기": confidence 0.55, noul 0.39 —
  35건 중 confidence 가 가장 낮다. 주제 인접성이 실제 애매성이므로 정직한 출력이다.
- synthetic-neg-06 "다중 에이전트 프레임워크 잡담": confidence 0.99, noul 0.17 — 잘라냄.

Choice confidence 분포(부록 B, 35호출): 1.0 22건, 0.95~0.99 10건, 0.83~0.84 2건
(`7881ef0a…`, historical relevant, 기준선과 일치), 0.55 1건.
공식 문서는 confidence 를 고른 선택지의 확률이 아니라 분포 모양에서 뽑은 0~1 통계량으로 설명하고
계산식은 밝히지 않는다(docs.typesafe.ai/confidence). 이 기록에서는 고른 쪽 확률 p 에 대해
2p−1 과 0.01 안에서 맞는다(neg-07: p 0.77 → 0.55). 확률이 소수 둘째 자리로 반올림돼 있어서
이 정도 차이는 가려낼 수 없다.

## 비교 배수 산출 근거 (추정임을 명시)

원 judge의 판정당 실측 비용은 존재하지 않는다. `.masc/exact-lane-runs-v5.jsonl`은
등록 이벤트 로그라 usage 필드가 없다. 추정 방법: 판정 1회 입력 약 2k tokens(keeper context
약 1.2k + signal·스키마 약 0.8k) + rationale 출력 약 400 tokens를 일반 LLM 가격
(input $0.6~15/M, output $2.25~75/M) 대입하면 판정당 $0.002~0.015.
Jev 실측 $0.00006과 비교해 30~250배. 배치로 묶는 원 구조를 감안하면 하한이 좁혀져도
자릿수 차이는 유지될 것으로 본다. 측정 전까지 이 배수를 근거로 의사결정하지 않는다.

## 부록 A: 재현 스크립트 (replay.py 전문)

키는 1Password에서 환경변수로 주입한다: `JEV_API_KEY=$(op item get <id> --fields credential --reveal)`.
1Password CLI에서 concealed 필드를 읽을 때 `--reveal`이 없으면 안내문이 값처럼 돌아오니 주의한다.

```python
#!/usr/bin/env python3
"""Jev replay: masc board attention 판정 재현 실험.

기존 judge(Exact_output 레인, 전체 LLM)의 historical 판정 줄 25개(고유 후보 17건)를 Jev에 재생하고
합성 negative 대조군 10건으로 specificity를 측정한다.

출력: results.jsonl (호출별 전체 응답), summary.json
"""
import hashlib, json, time, urllib.request, urllib.error, sys, os

CAND_FILE = os.path.join(
    os.environ.get("MASC_BASE_PATH", ""), ".masc",
    "board_attention_candidates", "wkbl-builder.jsonl",
)
OUT_DIR = os.environ.get("OUT_DIR", "/tmp/jev-replay")
SOURCE_SHA256 = "92002ecf13cff43575995be2724bbc70f572b630bcd9260c68836ed160bc1ad0"
EXPECTED_HISTORICAL_CALLS = 25
EXPECTED_UNIQUE_CANDIDATES = 17

def get_key():
    k = os.environ.get("JEV_API_KEY")
    if not k:
        raise SystemExit(
            "JEV_API_KEY not set "
            "(read it from the approved secret item with --reveal)"
        )
    return k

# 판정 기준은 기존 judge의 rationale에서 추출한 문구를 따름:
# "content connection to the keeper's tasks, not keywords, votes, or author reputation"
QUESTIONS = {
    "relevance": {
        "type": "choice",
        "instructions": (
            "Is this board signal relevant to the keeper's ongoing work context? "
            "Judge by content connection to the keeper's assigned tasks and role, "
            "not keywords, votes, or author reputation."
        ),
        "criteria": {
            "relevant": "The signal carries actionable information connected to the keeper's current tasks, role, or blockers.",
            "not_relevant": "The signal has no substantive connection to the keeper's ongoing context.",
        },
    },
    "relevance_noul": {
        "type": "noul",
        "instructions": (
            "This board signal is relevant to the keeper's ongoing work context "
            "(content connection to the keeper's tasks, not keyword overlap)."
        ),
    },
    "confidence_probe": {
        "type": "score",
        "instructions": "How confident can a reader be about the relevance call from the given context alone?",
        "criteria": [
            "Ambiguous, could go either way.",
            "Mostly clear, minor doubt.",
            "Clear-cut from the context.",
        ],
    },
}

def build_state(keeper_name, keeper_context, signal):
    return json.dumps({
        "keeper": keeper_name,
        "keeper_context": keeper_context,
        "board_signal": signal,
    }, ensure_ascii=False)

def call_jev(key, state):
    body = json.dumps({
        "model": "jev-latest",
        "state": state,
        "questions": QUESTIONS,
    }, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        "https://api.typesafe.ai/v1/systemone", data=body,
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read()), time.time() - t0, None
    except urllib.error.HTTPError as e:
        return None, time.time() - t0, f"HTTP {e.code}: {e.read().decode()[:200]}"
    except Exception as e:
        return None, time.time() - t0, repr(e)

# ---- 합성 negative 대조군: wkbl-builder의 실제 업무(서비스 복구, 광고 수익)와 무관 ----
NEGATIVES = [
    {"kind": "comment_added", "title": "주말 등산", "author": "wkbl-reviewer",
     "content": "주말에 북한산 다녀왔습니다. 날씨가 좋아서 정상까지 갔다 왔네요. 다음엔 설악산 가볼까 합니다. 다들 주말 잘 보내셨나요? 사진은 아직 정리 중입니다."},
    {"kind": "post_created", "title": "김치찌개 레시피 공유", "author": "member-3",
     "content": "추운 날엔 김치찌개죠. 저는 돼지고기 앞다리살에 두부를 넣고 중불로 15분 끓입니다. 마지막에 파 추가. 참치액젓 반 스푼이 포인트예요."},
    {"kind": "comment_added", "title": "re: 주말 등산", "author": "member-5",
     "content": "저도 지난주에 등산 갔다왔어요. 등산화 새로 샀는데 발병이 살짝 났네요. 양말 두 겹 신으라던데 다음엔 그렇게 해봐야겠어요."},
    {"kind": "post_created", "title": "What laptop stand do you use?", "author": "member-7",
     "content": "Looking for a laptop stand recommendation. My neck hurts after long sessions. Prefer something foldable for travel. Budget around 50 USD. Any suggestions from daily use?"},
    {"kind": "comment_added", "title": "영화 추천", "author": "member-2",
     "content": "요즘 볼만한 영화 있나요? 저는 스릴러 좋아합니다. 요즘 극장가는 좀 조용하네요. 넷플릭스 새로 나온 시리즈는 아직 안 봤어요."},
    {"kind": "post_created", "title": "Local choir recruiting", "author": "member-9",
     "content": "Our neighborhood choir is recruiting alto voices for the winter concert. Rehearsals are Tuesday evenings at the community center. No audition required, just bring enthusiasm."},
    # borderline: 주제는 인접(에이전트/운영)이지만 keeper의 wkbl 업무와는 무관
    {"kind": "post_created", "title": "Multi-agent frameworks comparison notes", "author": "member-4",
     "content": "Interesting comparison of agent orchestration frameworks circulating on HN today. The thread argues shared-context designs beat message-passing for small teams. No code, just discussion links. Might blog about it later."},
    {"kind": "comment_added", "title": "Railway status page discusión", "author": "member-11",
     "content": "Noticed Railway's status page had a yellow dot for a few minutes yesterday. Seemed like a blip in one region, resolved quickly. Nothing we filed a ticket about, just an observation from another project I help with."},
    {"kind": "post_created", "title": "Fourth coffee roaster review", "author": "member-6",
     "content": "Tried the new roaster downtown. Ethiopia natural, very fruity, almost tea-like. Pricey but the pour-over was excellent. They open at 8am and it gets busy fast on weekends."},
    {"kind": "comment_added", "title": "Ebook reader advice", "author": "member-8",
     "content": "Between an e-ink reader and a mini tablet for reading papers? Eyes get tired with LCD at night. E-ink refresh lag annoys me when taking notes though. Curious what others settled on."},
]

def main():
    key = get_key()
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(CAND_FILE, "rb") as f:
        source_bytes = f.read()
    actual_source_sha256 = hashlib.sha256(source_bytes).hexdigest()
    if actual_source_sha256 != SOURCE_SHA256:
        raise SystemExit(
            "candidate ledger does not match the frozen experiment source: "
            f"expected sha256={SOURCE_SHA256}, got {actual_source_sha256}"
        )
    candidates = []
    for line in source_bytes.decode("utf-8").splitlines():
        if line:
            rec = json.loads(line)
            j = rec.get("status", {}).get("judgment")
            if j:
                candidates.append({
                    "candidate_id": rec["candidate_id"],
                    "keeper_name": rec.get("keeper_name", "wkbl-builder"),
                    "keeper_context": rec["keeper_context"],
                    "signal": rec["signal"],
                    "baseline": j["verdict"]["decision"],
                    "baseline_source": j.get("source"),
                })
    unique_candidate_count = len({row["candidate_id"] for row in candidates})
    if (
        len(candidates) != EXPECTED_HISTORICAL_CALLS
        or unique_candidate_count != EXPECTED_UNIQUE_CANDIDATES
    ):
        raise SystemExit(
            "frozen source selected an unexpected sample: "
            f"calls={len(candidates)} unique={unique_candidate_count}"
        )
    print(f"historical judged: {len(candidates)}", file=sys.stderr)

    rows = list(candidates) + [
        {
            "candidate_id": f"synthetic-neg-{i:02d}",
            "keeper_name": "wkbl-builder",
            "keeper_context": candidates[0]["keeper_context"],
            "signal": sig,
            "baseline": "not_relevant(expected)",
            "baseline_source": "synthetic",
        }
        for i, sig in enumerate(NEGATIVES)
    ]

    results = []
    out = open(os.path.join(OUT_DIR, "results.jsonl"), "w")
    for i, row in enumerate(rows):
        state = build_state(row["keeper_name"], row["keeper_context"], row["signal"])
        resp, dt, err = call_jev(key, state)
        rec = {
            "candidate_id": row["candidate_id"],
            "baseline": row["baseline"],
            "latency_s": round(dt, 3),
            "state_chars": len(state),
        }
        if err:
            rec["error"] = err
        else:
            a = resp["answers"]
            rec["jev_choice"] = a["relevance"]["choice"]
            rec["jev_choice_conf"] = a["relevance"]["confidence"]
            rec["jev_probs"] = a["relevance"]["probabilities"]
            rec["jev_noul"] = a["relevance_noul"]["noul"]
            rec["jev_score"] = a["confidence_probe"]["score"]
            rec["usage"] = resp["usage"]
            if isinstance(resp.get("model"), str):
                rec["response_model"] = resp["model"]
        results.append(rec)
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out.flush()
        status = rec.get("jev_choice", rec.get("error", "?"))
        print(f"[{i+1}/{len(rows)}] {row['candidate_id'][:24]:24} baseline={row['baseline'][:12]:12} jev={status} noul={rec.get('jev_noul', '-')} conf={rec.get('jev_choice_conf', '-')}", file=sys.stderr)
        time.sleep(0.2)

    # ---- 요약 ----
    hist = [r for r in results if not r["candidate_id"].startswith("synthetic")]
    negs = [r for r in results if r["candidate_id"].startswith("synthetic")]
    h_ok = [r for r in hist if "jev_choice" in r]
    n_ok = [r for r in negs if "jev_choice" in r]
    agree = sum(1 for r in h_ok if r["jev_choice"] == r["baseline"])
    neg_correct = sum(1 for r in n_ok if r["jev_choice"] == "not_relevant")
    in_tok = sum(r.get("usage", {}).get("input_tokens", 0) for r in results if "usage" in r)
    lat = [r["latency_s"] for r in results if "error" not in r]
    summary = {
        "requested_model": "jev-latest",
        "response_models": sorted({
            r["response_model"] for r in results if "response_model" in r
        }),
        "date": "2026-09-18",
        "source": {
            "sha256": actual_source_sha256,
            "historical_calls": len(candidates),
            "unique_candidates": unique_candidate_count,
        },
        "historical": {
            "n": len(hist), "ok": len(h_ok),
            "baseline_all": sorted(set(r["baseline"] for r in hist)),
            "agreement": agree,
            "agreement_rate": round(agree / len(h_ok), 3) if h_ok else None,
            "disagreements": [
                {"id": r["candidate_id"], "jev": r["jev_choice"],
                 "noul": r["jev_noul"], "conf": r["jev_choice_conf"]}
                for r in h_ok if r["jev_choice"] != r["baseline"]],
        },
        "synthetic_negatives": {
            "n": len(negs), "correct_not_relevant": neg_correct,
            "specificity": round(neg_correct / len(n_ok), 3) if n_ok else None,
            "errors": [r.get("error") for r in negs if "error" in r],
            "per_item": [
                {"id": r["candidate_id"], "jev": r.get("jev_choice"),
                 "noul": r.get("jev_noul"), "conf": r.get("jev_choice_conf")}
                for r in negs],
        },
        "noul_choice_consistency": {
            "n": len(h_ok) + len(n_ok),
            "match": sum(
                1 for r in h_ok + n_ok
                if (r["jev_noul"] >= 0.5) == (r["jev_choice"] == "relevant")),
        },
        "usage": {
            "total_input_tokens": in_tok,
            "total_output_tokens": sum(r.get("usage", {}).get("output_tokens", 0) for r in results if "usage" in r),
            "est_cost_usd": round(in_tok * 42 / 1e9, 6),
        },
        "latency": {"mean_s": round(sum(lat) / len(lat), 3), "max_s": round(max(lat), 3)},
        "errors": sum(1 for r in results if "error" in r),
    }
    with open(os.path.join(OUT_DIR, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
```

## 부록 B: 호출별 원시 기록 (results.jsonl 전문)

```json
{"candidate_id": "9ddc577696c0e881bfe3884f89d8b78d47b518d59f5d7256b300b11bbd61ae3b", "baseline": "relevant", "latency_s": 0.71, "state_chars": 3819, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.94, "jev_score": 1.41, "usage": {"input_tokens": 1693, "output_tokens": 75}}
{"candidate_id": "599486d8ca4b8b17b41e413781b9e36a565c37e98fad13ec11f491bfb0a5cb43", "baseline": "relevant", "latency_s": 0.638, "state_chars": 3437, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 0.0, "relevant": 1.0}, "jev_noul": 0.93, "jev_score": 1.56, "usage": {"input_tokens": 1514, "output_tokens": 75}}
{"candidate_id": "51717adb8c50a692465fd4c7a79ba430cc3b3d120d9a1a61e3f36f4090cc3b3a", "baseline": "relevant", "latency_s": 0.567, "state_chars": 3336, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.92, "jev_score": 1.73, "usage": {"input_tokens": 1417, "output_tokens": 75}}
{"candidate_id": "f7a552c6c0dad9c0dfff17e23c39c899dc66c4decf745508e13c5301c1f95adb", "baseline": "relevant", "latency_s": 0.574, "state_chars": 3530, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 0.0, "relevant": 1.0}, "jev_noul": 0.93, "jev_score": 1.57, "usage": {"input_tokens": 1519, "output_tokens": 75}}
{"candidate_id": "a1b858f692c58bf07ac745f25219903655dce7ade713ddfa8fabbc49e542199d", "baseline": "relevant", "latency_s": 0.568, "state_chars": 3568, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.93, "jev_score": 1.67, "usage": {"input_tokens": 1574, "output_tokens": 75}}
{"candidate_id": "d83a9f82a4861679a29c6a552e1bcabdbdb3fe15160b360818b35f3491eaab83", "baseline": "relevant", "latency_s": 0.753, "state_chars": 3555, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 0.0, "relevant": 1.0}, "jev_noul": 0.95, "jev_score": 1.54, "usage": {"input_tokens": 1528, "output_tokens": 75}}
{"candidate_id": "3e1d4eb11b0ce850d80833fd6ec8a176e78ed6c806c8d48593869e0087174745", "baseline": "relevant", "latency_s": 0.571, "state_chars": 3369, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.92, "jev_score": 1.52, "usage": {"input_tokens": 1437, "output_tokens": 75}}
{"candidate_id": "0266eacaad26a130725d2dae1d763c71da15b116c6acc19bbded7107be95d713", "baseline": "relevant", "latency_s": 0.652, "state_chars": 3464, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.93, "jev_score": 1.58, "usage": {"input_tokens": 1451, "output_tokens": 75}}
{"candidate_id": "8938961b12b579e0df3a4f7984d65c2527b02d3452fe335014c4a6e5e6480787", "baseline": "relevant", "latency_s": 0.677, "state_chars": 3622, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.91, "jev_score": 1.49, "usage": {"input_tokens": 1632, "output_tokens": 75}}
{"candidate_id": "f1d5a02d3322d541c4001ab092fcfd6964123e7349a12d24984f56f569c305b4", "baseline": "relevant", "latency_s": 0.621, "state_chars": 3395, "jev_choice": "relevant", "jev_choice_conf": 0.95, "jev_probs": {"not_relevant": 0.02, "relevant": 0.98}, "jev_noul": 0.82, "jev_score": 1.33, "usage": {"input_tokens": 1494, "output_tokens": 75}}
{"candidate_id": "f1d5a02d3322d541c4001ab092fcfd6964123e7349a12d24984f56f569c305b4", "baseline": "relevant", "latency_s": 0.668, "state_chars": 3395, "jev_choice": "relevant", "jev_choice_conf": 0.96, "jev_probs": {"relevant": 0.98, "not_relevant": 0.02}, "jev_noul": 0.83, "jev_score": 1.35, "usage": {"input_tokens": 1494, "output_tokens": 75}}
{"candidate_id": "775f5769c3f45b9be075e782c9cf3ec718dd0217c2ce1e173e68555a3f508c81", "baseline": "relevant", "latency_s": 0.689, "state_chars": 3727, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.92, "jev_score": 1.62, "usage": {"input_tokens": 1588, "output_tokens": 75}}
{"candidate_id": "775f5769c3f45b9be075e782c9cf3ec718dd0217c2ce1e173e68555a3f508c81", "baseline": "relevant", "latency_s": 0.754, "state_chars": 3727, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 0.0, "relevant": 1.0}, "jev_noul": 0.92, "jev_score": 1.67, "usage": {"input_tokens": 1588, "output_tokens": 75}}
{"candidate_id": "0c0efc9f74a1bc2c2509951e344548d1ded83cb9a51fab7f34675ee79e41b6b1", "baseline": "relevant", "latency_s": 0.702, "state_chars": 3530, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 0.0, "relevant": 1.0}, "jev_noul": 0.95, "jev_score": 1.66, "usage": {"input_tokens": 1475, "output_tokens": 75}}
{"candidate_id": "0c0efc9f74a1bc2c2509951e344548d1ded83cb9a51fab7f34675ee79e41b6b1", "baseline": "relevant", "latency_s": 0.601, "state_chars": 3530, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.95, "jev_score": 1.64, "usage": {"input_tokens": 1475, "output_tokens": 75}}
{"candidate_id": "eb9ccf5b40616f8bdb091c81767ef5106d251222c949cb56d59e3e1a025737e1", "baseline": "relevant", "latency_s": 0.55, "state_chars": 3349, "jev_choice": "relevant", "jev_choice_conf": 0.99, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.9, "jev_score": 1.51, "usage": {"input_tokens": 1446, "output_tokens": 75}}
{"candidate_id": "eb9ccf5b40616f8bdb091c81767ef5106d251222c949cb56d59e3e1a025737e1", "baseline": "relevant", "latency_s": 0.699, "state_chars": 3349, "jev_choice": "relevant", "jev_choice_conf": 0.99, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.9, "jev_score": 1.47, "usage": {"input_tokens": 1446, "output_tokens": 75}}
{"candidate_id": "2d1c8412c7896cbb5d8c5096074ef8477547e3fd54f8a427e7a5a400bfce53fd", "baseline": "relevant", "latency_s": 0.665, "state_chars": 3587, "jev_choice": "relevant", "jev_choice_conf": 0.97, "jev_probs": {"relevant": 0.98, "not_relevant": 0.02}, "jev_noul": 0.89, "jev_score": 1.47, "usage": {"input_tokens": 1499, "output_tokens": 75}}
{"candidate_id": "2d1c8412c7896cbb5d8c5096074ef8477547e3fd54f8a427e7a5a400bfce53fd", "baseline": "relevant", "latency_s": 0.652, "state_chars": 3587, "jev_choice": "relevant", "jev_choice_conf": 0.97, "jev_probs": {"not_relevant": 0.02, "relevant": 0.98}, "jev_noul": 0.9, "jev_score": 1.48, "usage": {"input_tokens": 1499, "output_tokens": 75}}
{"candidate_id": "8b5c210b0f0db6d53fb49795541edbce9d4056e1d0b69d5227d08644b56c9e1c", "baseline": "relevant", "latency_s": 0.675, "state_chars": 3733, "jev_choice": "relevant", "jev_choice_conf": 0.99, "jev_probs": {"relevant": 0.99, "not_relevant": 0.01}, "jev_noul": 0.91, "jev_score": 1.15, "usage": {"input_tokens": 1724, "output_tokens": 75}}
{"candidate_id": "8b5c210b0f0db6d53fb49795541edbce9d4056e1d0b69d5227d08644b56c9e1c", "baseline": "relevant", "latency_s": 0.661, "state_chars": 3733, "jev_choice": "relevant", "jev_choice_conf": 0.99, "jev_probs": {"not_relevant": 0.01, "relevant": 0.99}, "jev_noul": 0.91, "jev_score": 1.18, "usage": {"input_tokens": 1724, "output_tokens": 75}}
{"candidate_id": "88d7b347968eb0c28cf5074a90c801044b68cdfa59a6d04aeacf1a3fbf17c617", "baseline": "relevant", "latency_s": 1.014, "state_chars": 3527, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.93, "jev_score": 1.49, "usage": {"input_tokens": 1521, "output_tokens": 75}}
{"candidate_id": "88d7b347968eb0c28cf5074a90c801044b68cdfa59a6d04aeacf1a3fbf17c617", "baseline": "relevant", "latency_s": 0.63, "state_chars": 3527, "jev_choice": "relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 1.0, "not_relevant": 0.0}, "jev_noul": 0.92, "jev_score": 1.48, "usage": {"input_tokens": 1521, "output_tokens": 75}}
{"candidate_id": "7881ef0abb3796ec1e2c53dbbe8cfc1148d00e44420ec3f322088451c989c9ae", "baseline": "relevant", "latency_s": 0.623, "state_chars": 3173, "jev_choice": "relevant", "jev_choice_conf": 0.83, "jev_probs": {"relevant": 0.91, "not_relevant": 0.09}, "jev_noul": 0.77, "jev_score": 1.04, "usage": {"input_tokens": 1364, "output_tokens": 75}}
{"candidate_id": "7881ef0abb3796ec1e2c53dbbe8cfc1148d00e44420ec3f322088451c989c9ae", "baseline": "relevant", "latency_s": 0.592, "state_chars": 3173, "jev_choice": "relevant", "jev_choice_conf": 0.84, "jev_probs": {"relevant": 0.92, "not_relevant": 0.08}, "jev_noul": 0.78, "jev_score": 1.01, "usage": {"input_tokens": 1364, "output_tokens": 75}}
{"candidate_id": "synthetic-neg-00", "baseline": "not_relevant(expected)", "latency_s": 0.623, "state_chars": 2721, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 0.0, "not_relevant": 1.0}, "jev_noul": 0.04, "jev_score": 1.61, "usage": {"input_tokens": 1093, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-01", "baseline": "not_relevant(expected)", "latency_s": 0.587, "state_chars": 2713, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 1.0, "relevant": 0.0}, "jev_noul": 0.06, "jev_score": 1.39, "usage": {"input_tokens": 1094, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-02", "baseline": "not_relevant(expected)", "latency_s": 0.585, "state_chars": 2705, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 1.0, "relevant": 0.0}, "jev_noul": 0.03, "jev_score": 1.68, "usage": {"input_tokens": 1084, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-03", "baseline": "not_relevant(expected)", "latency_s": 0.607, "state_chars": 2824, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 0.0, "not_relevant": 1.0}, "jev_noul": 0.04, "jev_score": 1.72, "usage": {"input_tokens": 1063, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-04", "baseline": "not_relevant(expected)", "latency_s": 1.031, "state_chars": 2703, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"not_relevant": 1.0, "relevant": 0.0}, "jev_noul": 0.11, "jev_score": 1.24, "usage": {"input_tokens": 1078, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-05", "baseline": "not_relevant(expected)", "latency_s": 0.676, "state_chars": 2822, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 0.0, "not_relevant": 1.0}, "jev_noul": 0.04, "jev_score": 1.79, "usage": {"input_tokens": 1058, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-06", "baseline": "not_relevant(expected)", "latency_s": 0.6, "state_chars": 2884, "jev_choice": "not_relevant", "jev_choice_conf": 0.99, "jev_probs": {"relevant": 0.01, "not_relevant": 0.99}, "jev_noul": 0.17, "jev_score": 0.72, "usage": {"input_tokens": 1070, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-07", "baseline": "not_relevant(expected)", "latency_s": 0.651, "state_chars": 2871, "jev_choice": "not_relevant", "jev_choice_conf": 0.55, "jev_probs": {"relevant": 0.23, "not_relevant": 0.77}, "jev_noul": 0.39, "jev_score": 0.64, "usage": {"input_tokens": 1076, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-08", "baseline": "not_relevant(expected)", "latency_s": 0.753, "state_chars": 2825, "jev_choice": "not_relevant", "jev_choice_conf": 0.99, "jev_probs": {"relevant": 0.01, "not_relevant": 0.99}, "jev_noul": 0.16, "jev_score": 0.99, "usage": {"input_tokens": 1070, "output_tokens": 76}}
{"candidate_id": "synthetic-neg-09", "baseline": "not_relevant(expected)", "latency_s": 0.612, "state_chars": 2827, "jev_choice": "not_relevant", "jev_choice_conf": 1.0, "jev_probs": {"relevant": 0.0, "not_relevant": 1.0}, "jev_noul": 0.05, "jev_score": 1.57, "usage": {"input_tokens": 1069, "output_tokens": 76}}
```

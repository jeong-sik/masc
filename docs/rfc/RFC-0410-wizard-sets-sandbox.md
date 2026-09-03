---
rfc: "0410"
title: 설치 마법사가 샌드박스를 정하게 하기 — 전역 surface 없이
status: Draft
created: 2026-09-04
author: Claude Opus 4.8
supersedes: []
superseded_by: null
related: ["0408", "0400", "0405"]
---

## 0. 한 줄 요약

RFC-0408 마법사는 실행 샌드박스를 **감지·표시만** 한다 — 쓸 자리가 없기 때문이다(§1). 이 문서는 "마법사가 샌드박스를 정하게" 하는 세 가지 길을 저울질하고, **전역 기본 surface 를 신설하지 않는** 쪽(옵션 B)을 권고한다. 결론이 "신설하자"가 아닐 수 있는 RFC다 — 목적은 설계 선택을 기록해 재논의를 막는 것.

## 1. 문제 — 실측 (RFC-0408 §3.2 근거)

- 샌드박스는 **per-keeper**: `.masc/config/keepers/<name>.toml` 의 `[keeper] sandbox_profile`. 부재는 에러(accessor raise).
- **전역 기본 surface 가 없다**: runtime.toml 에 `[sandbox]` 없음, 프로필 선택 env 없음.
- 타입은 `Docker | Micro_vm | Remote_ssh` 셋뿐(`keeper_types_profile_sandbox.ml`). **`Local` 변형 없음** — `"local"` 은 in-process 레인의 flag-gated 우회.
- keeper 는 `--team <preset>` 가 각자 `sandbox_profile` 을 지니고 온다.

그래서 install 마법사가 "이 머신은 docker 로 돌려" 같은 선택을 **쓸 대상이 없다**. 현재는 감지·안내만 하고, 실제 선택은 사용자가 per-keeper TOML 또는 preset 으로 한다.

## 2. 설계 후보

### 옵션 A — 전역 `[sandbox] default_profile` surface 신설
runtime.toml 에 `[sandbox] default_profile = "docker"` 를 추가하고, per-keeper `sandbox_profile` 부재 시 이 값으로 fallback 하는 loader·소비자를 만든다.
- 장점: 한 곳에서 머신 전체 기본을 정함. 마법사가 한 줄만 쓰면 됨.
- 단점: **새 config Gate + 새 상태**. keeper 설정 로딩 경로(현재 "부재는 에러")를 "부재는 전역 fallback"으로 바꿔야 함 — 파생 상태와 우선순위 규칙이 늘어남. manifest: *"새 상태·필드·Gate 는 없을 때 durable truth 가 손상되는 경우에만 추가한다."* 전역 기본은 durable truth 를 보호하지 않는다 — 편의다.

### 옵션 B — 마법사가 **기존** per-keeper 필드를 씀 (surface 신설 없음) ★권고
마법사가 샌드박스를 고르면, 그 값을 자신이 seed 하는 keeper TOML(`--team <preset>`)의 **기존** `sandbox_profile` 필드에 써 넣는다(감지된 백엔드로 preset 기본을 덮어씀). 새 타입·loader·Gate 없음 — 이미 있는 필드에 쓰는 것뿐.
- 장점: 새 surface 0. 기존 per-keeper 모델을 그대로 존중. "부재는 에러" 계약 유지.
- 단점: 마법사가 seed 하는 keeper 에만 적용(이후 추가하는 keeper 는 지금처럼 사용자가 설정). preset 을 안 쓰는 설치엔 seed 대상이 없음 — 그 경우는 옵션 C.
- 경계: `"local"` 은 쓰지 않는다(로드 불가 — RFC-0408 §3.2). 감지된 실변형(docker/microvm/remote_ssh)만.

### 옵션 C — 현행 유지 (감지·안내만)
마법사는 가용 백엔드를 표시하고, 선택은 preset·per-keeper TOML 에 맡긴다.
- 장점: 코드 변화 0. preset(예: classic)이 이미 자기 샌드박스를 지님.
- 단점: preset 을 안 쓰고 keeper 를 손으로 추가하는 사용자는 여전히 TOML 을 직접 만짐.

## 3. 권고

**옵션 B**(+ 미적용 시 C 로 자연 축소). 근거:
1. manifest 의 Gate/surface 신설 기준을 만족하지 않는다(durable truth 보호 아님) → 옵션 A 배제.
2. 옵션 B 는 사용자가 원하는 것("마법사가 샌드박스를 정함")을 **기존 필드로** 달성 — 새 상태·우선순위 규칙 없음.
3. preset 이 없으면 seed 대상이 없으니 C 로 떨어짐(마법사는 그때도 감지·안내는 함).

즉, "전역 기본 샌드박스"라는 새 개념은 만들지 않는 것이 이 코드베이스의 결에 맞다.

## 4. 구현 범위 (옵션 B 채택 시)

- install.sh: 샌드박스 감지 리포트 뒤, `--team` 이 seed 한 keeper TOML 들의 `sandbox_profile` 을 (a) 감지된 것이 하나면 그것으로, (b) 여럿이면 TTY 에서 물어, (c) 비-TTY 면 preset 기본 유지, 로 설정. `"local"` 은 후보에서 제외.
- 테스트: seed 후 keeper TOML 의 `sandbox_profile` 이 감지 결과와 일치(도달 가능한 docker → docker; 아무것도 없으면 preset 기본 유지). install-script 하네스로 결정론적 검증 가능.

### 안 건드리는 것
- keeper 설정 로딩의 "부재는 에러" 계약. 전역 fallback 없음.
- 샌드박스 백엔드 구현(RFC-0400/0405).

## 5. 미해결 / 확인 필요

- 옵션 B 가 preset 없는 설치에 주는 가치가 낮다면(대부분 `--team` 을 쓴다면), C(현행)로 충분할 수 있다 — 실사용 데이터로 판단.
- docker 가용인데 서버 자체가 컨테이너 안이면 Docker-in-Docker 문제(presets/README WORKAROUND) — 마법사가 docker 를 쓰기 전에 "서버가 컨테이너 안인가"를 봐야 하는지.

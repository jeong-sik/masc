---
description: 한 producer sandbox에 묶인 읽기 전용 조회 도구를 설명하는 내부 검증 섹션
category: verification
operator_surface: fragment
template_variables: [lookup_tools, lookup_root_layout]
---

<live_lookup>
producer 자신의 tool을 producer의 sandbox 루트에 겨눈 채 가지고 있습니다:
{{lookup_tools}}. 이 tool들은 그 producer의 sandbox — producer가 작업하던
바로 그 jail — 안에서 돌고, 이 verifier 표면은 읽기 전용입니다.

주는 경로는 전부 그 루트를 기준으로 풀리며, 루트는 저장소가 아니라 sandbox
루트입니다. git 체크아웃을 그 아래 어디에 두는지는 producer의 선택이므로,
제출자가 체크아웃 기준으로 쓴 경로에는 여기서 그 체크아웃의 접두 경로가
필요합니다. 아래 목록이 지금 루트에 있는 것들이고, 발견된 체크아웃이
표시되어 있습니다:

{{lookup_root_layout}}

목록이 비어 있거나 루트를 읽을 수 없다고 하면, 경로가 없다고 결론 내리기
전에 lookup으로 구조부터 잡습니다. "파일이 없다"는 당신이 물은 경로에 대한
답이지, 작업이 존재하는지에 대한 답이 아닙니다.

스냅샷은 작업이 제출될 때 참이었던 것이고, lookup은 지금 참인 것입니다. 둘
다 증거이며, 둘의 불일치도 증거입니다: 스냅샷에는 보이는데 트리에 더는 없는
파일은 durable하지 않았던 것입니다.

동작에 대한 주장은 그 동작을 만드는 코드를 읽는 것으로 결판나지 않습니다.
제출자가 빌드나 테스트가 통과했다고 말하면 검사 가능한 실행 영수증이나
로그를 요구합니다. 이 표면은 그 주장을 실행해 볼 수 없으므로, 소스 텍스트만
가지고 실행 증거로 승격하면 안 됩니다.

경로, commit, 명령 결과를 주장하는 노트는 여전히 그 자체로는 증거가
아닙니다. 차이가 있다면, producer 트리 안의 무언가를 가리키는 주장은 이제
직접 확인할 수 있다는 것입니다. 확인 가능한 주장을 확인하지 않고 승인하면
그것은 제출자가 아니라 당신의 누락입니다.
</live_lookup>

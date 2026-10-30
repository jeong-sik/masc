verdict: PASS scope: final frozen source delta by: feature_navigation_review

Base `70f438d054df3c0fe4eaf51853d4775cc42bab81` 위 최종 14파일 변경을 독립적으로 직접 읽었습니다. P0–P2 및 잔여 P3는 발견하지 못했습니다. GitHub 승인이나 실행 판정이 아닙니다.

최종 full-index patch SHA256은 `69b5505e7ab08bae2b54daf87b6287bc592c4fac69367d46d338080d364de54a`입니다. 실제 14파일의 hash·bytes와 전체 diff가 freeze에 일치했습니다. 이전 reviewer의 원본14 판정도 읽었지만 이를 승인으로 이월하지 않고 현재 전체 source와 직접 소비자를 확인했습니다. 원본 patch `19f64da17ac0285970019960fd614c9376f82decaa91499bc8b862b7774ccec0` 대비 13파일은 동일하고, `bin/masc_tui_lane_inventory.mli`의 중복 문서 주석만 합쳐졌습니다. 최종 MLI 문구는 실제 구현과 일치하며 이전 P3는 해소됐습니다.

- 서버의 닫힌 selection → category 매핑이 built-in 역할의 유일한 정본입니다. `row_to_json`의 표시 metadata 추가 외에 서버 row, state, selection, lifecycle 또는 권한은 바뀌지 않습니다.
- 공용 TUI decoder는 전체 입력의 recursive duplicate-key 검사를 먼저 수행합니다. 카테고리 누락만 `None`이며 명시적 null·unknown·wrong type은 shared enum parser가 거절합니다. Dashboard도 기존 exact optional enum을 재사용합니다. 단 Dashboard는 이미 파싱한 JS object를 받으므로 raw JSON duplicate-key 거절까지 보장한다고 말할 수 없습니다.
- TUI와 Dashboard의 built-in 역할 복사본이 제거됐습니다. 클라이언트는 공급된 metadata를 읽고, 값이 없으면 ID나 이름으로 추측하지 않습니다. 현재 유효 package 선언과 원래 manual worker의 역할 판정은 그대로입니다. 상위 built-in metadata가 package 역할을 덮지 않습니다.
- 표시 역할은 원래 navigation/action identity와 state에 쓰이지 않습니다. reclassification regression은 실제 decoded row의 선택·state·typed target이 유지되는지 봅니다.
- 새 server integration은 실제 `snapshot`과 `to_json`을 strict decode한 뒤 TUI category consumer까지 전달합니다. 서버 encoder를 시험 안에서 베껴서 맞추는 검사가 아닙니다. 직접 shared-TUI row 생성자를 찾아 새 optional 필드가 갱신됐음을 확인했습니다. 기존 server row는 다른 타입이므로 의도적으로 필드를 늘리지 않았습니다.
- `test_server_lane_inventory`의 새 direct dependency `masc`와 `masc_tui_lane_inventory`는 실제 새 참조와 맞습니다. UI helper는 core/runtime에 의존하므로 이 변경이 production server/UI 순환 의존을 만들지 않습니다.

리뷰어의 `git diff --check`는 성공했습니다. Dashboard 5 suites / 64 PASS, tsc 및 parser 기록은 저자 실행 증거로만 보존합니다. 리뷰어는 Dune·타입·OCaml 테스트·CI·실제 서버·보이는 TUI를 실행하지 않았습니다. 이 판정은 Inspect 원본4 실패나 후속 stack 조합의 실행 성공을 대신하지 않습니다.

Publisher 통합 추가 확인: `/tmp/masc-addon-publication-20261023`의 Nav11 commit `bfb15c563b79adcfcd7bc7510e43915e0bbb72a1` 위 category14와 API guide 5줄을 직접 읽었습니다. author13파일 hash는 그대로이고 `test_tui_keys.ml`은 이전에 검토한 typed `help_surfaces` 수정과 새4개 optional 필드만 정확히 합쳐졌습니다. API guide의 builtin optional metadata, 무추정, 누락/null·unknown 구분 및 package metadata 독립 계약은 구현과 맞습니다. 이15파일 source scope의 full-index diff SHA256은 `da2942f21d48e77a1729b557285f91d72a070730ae566d72f610dbe6fd616447`이며 실제파일 hash는 JSON의 `publisher_integration`에 있습니다. 통합 source에서도 P0–P2를 발견하지 못했습니다.

Evidence README와 author freeze 사본도 읽었습니다. README의 duplicate metadata 설명은 shared OCaml decoder 범위로 한정하는 편이 정확합니다. parsed JS object를 받는 Dashboard에서 raw duplicate key를 검출한다는 보장으로 넓혀 읽으면 안 됩니다. 이 문구 정밀화 제안은 production source 차단 항목이 아닙니다.

verdict: PASS scope: frozen source delta by: feature_navigation_review

Base `70f438d054df3c0fe4eaf51853d4775cc42bab81` 위 최종 11파일 전체 변경 범위를 독립 소스 리뷰했습니다. P0–P2 및 잔여 P3를 발견하지 못했습니다. GitHub 승인이나 실행 판정은 아닙니다.

최종 patch SHA256은 `9e11b2d9b9ba10ce2793afb6b9a5cb43d0e98b2d674df464348ff62a421fd5ee`입니다. 실제 11파일 SHA256과 전체 diff digest가 최종 freeze에 일치합니다. 원래 10파일 diff와 직접 consumer를 읽은 뒤, 최종 추가 delta인 Runtime count 변경과 TUI-KEYS 3줄을 다시 직접 읽었습니다. 이전 파일 9개의 bytes는 그대로입니다. 리뷰어의 `git diff --check`도 성공했습니다.

- Features / Plugins는 기존 typed destination인 `Palette_goto Lanes` / `Palette_lane_addons`에 연결됩니다. 실제 처리부와 o/O/A 단축키는 같은 Inspect owner를 사용합니다. API, 선택 identity, 권한과 실행 제어는 바뀌지 않습니다.
- `help_surfaces`의 인터페이스는 `(string * surface) list`이며 수정한 테스트는 그 실제 타입을 소비합니다. `help_sections`의 표시 행을 surface로 취급하지 않습니다.
- 부재 안내는 inventory와 원래 selection이 있으나 `find_identity` 결과가 없는 때만 출력합니다. 기존 `replace_lane_inventory`는 사라진 원래 identity를 보존하고, 명시적 이동만 새 대상을 선택합니다. 이번 변경은 그 상태에 관측만 더합니다.
- 렌더러와 `sc_chrome`는 동일한 줄바꿈 함수 `lane_inventory_notice_lines`를 사용하여 새 notice의 높이 계산을 공유합니다.
- 지적했던 Runtime Features 탭 count P3는 해소됐습니다. 최종 `feature_reading`은 `Masc.Tui_decode_lane_inventory.snapshot.rows` 실제 개수를 읽고, inventory가 없으면 `None`을 유지합니다. exact-only count나 0으로 채우지 않습니다.
- 가이드의 Features 제목과 Plugins/Features 참조는 실제 표시와 맞고 키·실행 동작은 유지됩니다. 갱신한 palette 회귀는 입력 query가 실제 typed destination으로 가는지 검사합니다. 새 화면 문구·배치·행 순서·PTY snapshot 검사는 없습니다.

로컬 Dune·타입·빌드·OCaml 테스트, 실제 터미널·키 루프·설치된 런타임은 실행하지 않았습니다. 저자 parser 기록은 타입/동작 증거로 올리지 않았습니다. 이전 PR 승인이나 다른 agent의 Inspect/category-authority 변경은 이 판정에 포함하지 않습니다.

중간 보고서는 freeze 교체와 저장이 겹쳐 이전10 범위의 prose에 최신11 manifest가 섞였으므로 `independent-review-intermediate` 파일에 SUPERSEDED로 보존했습니다. 이 최종11 범위의 보고서만 인용해야 합니다.

# F6 Owner-only 집중 CI — 106 PASS

[Test 40348100243](https://github.com/jeong-sik/masc/actions/runs/40348100243), 실행 head **`ccb0007e95ead82676a58d0dcc17d740dfe94f30`**, ref `fix/schedule-work-continuation-20261026`, 실제 `completed/success`입니다. 요청 범위는 `test_keeper_owner` 한 suite이며 runner가 `@@test/runtest-test_keeper_owner` Dune alias를 실행했습니다.

원본 ZIP 안 로그의 case verdict를 직접 세어 **106 PASS, FAIL 0, SKIP 0**을 확인했고 `Test Successful ... 106 tests run.` 및 runner 성공 exit와 대조했습니다. 기존에 실패한 `scheduled source handoff` case **1·2·7**도 `[OK]`입니다. 선택 로그에는 원래 checkpoint 보존·소비와 operation identity/scope assertions를 함께 남겼습니다.

- [완료 run 원문 metadata](run-completed.json)
- [원본 artifact index](artifacts.json), [선택한 artifact metadata](artifact-metadata.json)
- [선택 로그](selected.log)
- [원본 hash·case 검산·선택 줄·변환 설명](verification.json)

원본 archive SHA256은 GitHub artifact digest와 일치합니다:
`77ec86946c408950073b08ec1a6a2c405d4e1e0e69c12cbef2acd26011d804dc`.
ZIP 항목과 원본 추출 로그도 byte-identical입니다. 선택 로그만 ANSI SGR 색상·스타일 코드를 제거한 뒤 명시된 줄을 순서대로 이어 붙였습니다. 다른 내용이나 공백은 변경하지 않았습니다. 큰 ZIP과 전체 원본 로그는
`/Users/dancer/me/workspace/yousleepwhen/masc-schedule-runtime-audit/artifacts/scheduled-job-runtime-audit-20261026/ci40348100243/`에 보존했습니다.

이 결과는 과거 Test **40341860767**, head `b5c9762b27845918eba2acb804434a0da435cc78`의 Owner **103 PASS / 3 FAIL**을 지우거나 성공으로 바꾸지 않습니다. 새 fixture 수리 후의 다른 head에서 얻은 Owner-only 결과입니다.

또한 main 위로 rebase된 **`6dedd652df1273c9476a04643b445601e30181ad`의 결과가 아닙니다.** 전체 회귀, 다른 F6 suite, 실제 모델 효과, checkpoint 파일 복원, 정식 승인, 병합, 설치·배포 증거로 확대하지 않습니다. 이 패키징은 완료된 지정 run의 metadata/index/ZIP만 한 번 획득해 검산했으며, CI 재실행·watch, 로컬 build/test, 모델 실행, 제품 변경, commit/push를 하지 않았습니다.

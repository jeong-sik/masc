# 예약 Job 수리: 집중 CI 및 native build 증거

이 문서는 수리 검증 중 **CI 실행과 native artifact**만 묶습니다. 실제 모델 재실측은 이 디렉터리에 별도로 추가되는 run 증거를 보아야 합니다.

| 묶음 | 정확한 실행/source | 직접 확인한 범위 |
| --- | --- | --- |
| [F4 CI](f4-ci/README.md) | Test [40332170687](https://github.com/jeong-sik/masc/actions/runs/40332170687), head `e0be8af8df8d223bbdf052f3372e282d06f58cb2`, ref `fix/schedule-omitted-recurrence-20261026`, completed/success | tool wiring 57 + store 58 = **115 case PASS**, 두 suite exit 성공 |
| [F1 CI](f1-ci/README.md) | Test [40343103111](https://github.com/jeong-sik/masc/actions/runs/40343103111), head `08da4d99f1b2a58cae5f87f3a71ce4556c83cfe8`, ref `fix/schedule-cancel-all-owners-20261026`, completed/success | tool wiring 64 + paused transfer 12 = **76 명시 case PASS**; event queue 실행 파일도 성공, case 수는 출력되지 않음. 총 3 suite exit 성공 |
| [Native build](native-build/README.md) | Test [40339887803](https://github.com/jeong-sik/masc/actions/runs/40339887803), definition `117dc31e1ca8f71f47bbbe91fa2adab5befb5761` / `ci/schedule-native-runtime-proof-20261026`; 제품 source `94b2df25abcdfe20c658322f4156ad63f5546c34` | macOS ARM 5개 실행 파일 + wrapper + runtime archive, producer 완료 manifest, 전체 7개 dist 크기·해시와 ZIP 비교. Actions terminal success는 부모 관측이며 여기서는 native CI를 추가 조회하지 않음 |

F4/F1의 `[OK]` 행 수를 원본 ZIP에서 읽은 로그의 suite summary와 대조했습니다. Queue 실행 파일은 case count가 없는 별도 프로그램이므로 임의 숫자를 합산하지 않았습니다. 선택 로그는 명시된 원본 줄을 순서대로 이어 붙였고, credential·control token·모델 추론·큰 raw 로그·바이너리를 복사하지 않았습니다.

[manifest-core.json](manifest-core.json)은 이 문서와 `f4-ci/`, `f1-ci/`, `native-build/`의 retained bytes 해시만 기록합니다. 각 묶음의 `verification.json`은 원본 위치·원본 hash·선택/변환 방법을 별도로 보존합니다. 원본 bundle은 수정하지 않았습니다. F1 원본은 이 작업에서 지정 완료 run의 artifact를 다운로드해 새 capture 폴더에 보존했습니다.

소스 검토, 집중 CI, native 빌드, 실제 모델 효과, 정식 GitHub 승인, 병합, 설치는 서로 다른 사실입니다. F6 후속 head `b5c976...`의 제품 `lib/`·`bin/`이 native source와 동일하더라도 그 전체 head의 빌드/테스트 성공으로 이월하지 않습니다. F6 Test **40341860767**은 이 작업에서 조회하지 않았으며 완료 판정을 하지 않습니다.

이 패키징 작업은 제품 변경, commit/push, CI dispatch/watch, 빌드, 모델 실행, 설치를 하지 않았습니다. F4 완료 metadata 1회와 새로 지정된 F1 완료 run의 metadata/artifact 획득만 수행했습니다. Native Actions terminal 상태는 다시 조회하지 않았습니다.

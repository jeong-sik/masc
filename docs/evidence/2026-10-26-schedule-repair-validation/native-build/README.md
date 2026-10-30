# Native macOS ARM build artifact

[Test 40339887803](https://github.com/jeong-sik/masc/actions/runs/40339887803)의 definition head는 `117dc31e1ca8f71f47bbbe91fa2adab5befb5761`, ref는 `ci/schedule-native-runtime-proof-20261026`입니다. 실제 제품 checkout과 embedded source는 별도 SHA인 **`94b2df25abcdfe20c658322f4156ad63f5546c34`**입니다.

원본 `artifact-manifest.json`은 macOS ARM의 5개 operator 실행 파일, 기존 shell wrapper, portable runtime archive가 생성된 뒤 `build_completed=true`를 기록했습니다. 초기 `source-selection.json`의 `build_completed=false`는 빌드 전 선택 단계의 원문이며, 완료 영수증으로 바꿔 쓰지 않았습니다.

이 패키징 작업에서 다시 확인한 사실:

- 원본 artifact ZIP SHA256: `ff173bf56e440f31fd8812c4b69bd88870fc16a1a7ac7046fd931490104b17f1`. 부모 세션이 관측한 GitHub digest 및 보존된 `local-verification.json`과 일치합니다. 이 작업에서 native run/API를 추가 조회하지 않았습니다.
- `dist/`의 **7개 파일 모두** 원본 manifest의 크기·SHA256과 일치하고 ZIP 항목과 unpacked 파일 해시도 같습니다.
- 서버 바이너리 SHA256: `a0bd5c3903ef6425024e47b9dc92a7615f4efbb941357ea36e74ac5a18284668`. root가 준비한 로컬 `runtime/masc`도 이 해시와 같습니다.
- ZIP 원문의 embedded-source 영수증·manifest·runtime provenance가 같은 제품 source를 가리킵니다. 여기서는 바이너리를 다시 실행하지 않았으며, root의 실제 embedded-commit 확인은 원본 `local-verification.json`으로 구분합니다.

[검산 기록](verification.json), [완료 artifact manifest 원문](artifact-manifest.json), [초기 source 선택 원문](source-selection.json), [packager provenance 원문](runtime-provenance.json), [root의 로컬 검증 원문](local-verification.json), [최소 packager 로그](package-selected.log)를 보존합니다. 원본 큰 ZIP·바이너리·전체 빌드 로그는 `artifacts/scheduled-job-runtime-audit-20261026/native40339887803/`에 그대로 있습니다.

부모 세션은 이 Actions run의 terminal success를 관측했습니다. 이 묶음이 직접 보존하는 완료 근거는 producer artifact manifest와 원본 source/package 영수증이며, Actions completed-run 원문 메타데이터는 이 묶음에 없습니다.

후속 테스트 수정 head `b5c9762b27845918eba2acb804434a0da435cc78`의 `lib/`·`bin/` Git tree가 제품 source `94b2df...`와 같음을 다시 확인했습니다. 이는 제품 입력 동일성이지 **b5c976 전체 head의 빌드·테스트 성공**이 아닙니다.

이 결과는 단일 macOS ARM core 빌드/패키징 증거입니다. 실제 모델의 효과, 전체 CI, Release/Tag 검증, 정식 승인, 병합, production 설치·배포는 별도 증거입니다. 이 작업은 빌드·모델 실행·설치를 수행하지 않았습니다.

# f4-ci: 완료된 집중 CI

[Test 40332170687](https://github.com/jeong-sik/masc/actions/runs/40332170687) — head `e0be8af8df8d223bbdf052f3372e282d06f58cb2`, ref `fix/schedule-omitted-recurrence-20261026`, 실제 `completed/success`.

Alcotest 출력의 `[OK]`를 직접 세고 각 `Test Successful` 요약과 대조했습니다: 57 + 58 = **115**건 PASS, 표시된 FAIL/SKIP 0. 2개 요청 suite의 runner 성공 exit를 확인했습니다.
원본 ZIP의 SHA256은 GitHub artifact digest와 일치하고, ZIP 안 로그는 로컬 원본 추출 로그와 byte-identical입니다. [검산·원본 hash·선택 줄 목록](verification.json), [선택 로그](selected.log), [완료 run 원문 메타데이터](run-completed.json)를 보존합니다. 원본 큰 로그와 ZIP은 `artifacts/scheduled-job-runtime-audit-20261026/ci40332170687/`에 남아 있습니다.

이는 해당 head의 명시된 집중 검사 결과입니다. 전체 회귀, 다른 head, 실제 모델의 요청 효과, 정식 승인, 병합, 설치 또는 배포 성공으로 확장하지 않습니다.

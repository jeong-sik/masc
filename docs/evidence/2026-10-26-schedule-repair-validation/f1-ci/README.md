# f1-ci: 완료된 집중 CI

[Test 40343103111](https://github.com/jeong-sik/masc/actions/runs/40343103111) — head `08da4d99f1b2a58cae5f87f3a71ce4556c83cfe8`, ref `fix/schedule-cancel-all-owners-20261026`, 실제 `completed/success`.

Alcotest 출력의 `[OK]`를 직접 세고 각 `Test Successful` 요약과 대조했습니다: 64 + 12 = **76**건 PASS, 표시된 FAIL/SKIP 0. 3개 요청 suite의 runner 성공 exit를 확인했습니다.
`test_keeper_event_queue`도 runner의 exit 성공 영수증이 있습니다. 이 실행 파일은 case 수를 출력하지 않으므로 76건에 임의 case 수를 더하지 않습니다. 선택 로그는 일부 실제 recovery assertions와 성공 exit를 함께 보존합니다.

원본 ZIP의 SHA256은 GitHub artifact digest와 일치하고, ZIP 안 로그는 로컬 원본 추출 로그와 byte-identical입니다. [검산·원본 hash·선택 줄 목록](verification.json), [선택 로그](selected.log), [완료 run 원문 메타데이터](run-completed.json)를 보존합니다. 원본 큰 로그와 ZIP은 `artifacts/scheduled-job-runtime-audit-20261026/ci40343103111/`에 남아 있습니다.

이는 해당 head의 명시된 집중 검사 결과입니다. 전체 회귀, 다른 head, 실제 모델의 요청 효과, 정식 승인, 병합, 설치 또는 배포 성공으로 확장하지 않습니다.

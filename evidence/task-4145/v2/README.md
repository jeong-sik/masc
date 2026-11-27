# task-4145 최종 증거 (v2: 결정적 청크명 빌드 비교)

## 빌드 (CI ubuntu-24.04, 결정적 청크 파일명으로 vite build 대시보드+accounts)
- BEFORE: run 46070001327, tmp/ev2-before = e1a9d3d288(삭제 직전 main) + 증거 커밋 2390b667, success, artifact 15231744745
- PRHEAD: run 46070005449, tmp/ev2-prhead = PR #55203 head 488e7baa52 + 증거 커밋 52c8a703, success, artifact 15232113297
- 두 브랜치의 증거 파일(워크플로+결정적 이름 래퍼 설정)은 동일 커밋 내용. 임시 브랜치/ 설정은 증거 수집 후 삭제 예정.

## 결과 (원본: 이 디렉터리 v2/b2, v2/p2)
- 산출물 파일 목록: 263개로 두 빌드 완전 동일 (all-files.txt diff 없음) — FILE_LIST_IDENTICAL
- 파일 해시: 261개 중 260개 byte-identical. 유일하게 다른 파일 = assets/dashboard/assets/index6.css
- index6.css 분석(규칙 단위 multiset 비교): before 2018 rules / prhead 937 rules. only-in-before 1097 rules에서 추출한 489개 클래스 토큰을 소스로 역추적하면,それら는 e1a9d3d288 트리에서 1653개 파일에만 존재하고 그 1653개는 모두 삭제 목록(1132개)에 포함, PR head 트리에는 0개 생존 (mbl=0, md=1653=mb). 즉 CSS 차이는 삭제된(unreachable) 소스에서만 유래한 dead utility class 제거뿐.
- JS 번들: sourcemap sourcesContent 기준 348개 소스 두 빌드 byte-identical (v1 비교 결과와 동일).
- 빌드 메타 2파일(.build-stamp=타임스탬프, .build-identity.json=커밋 sha)은 애초에 내용이 다름 — 해시 비교에서 제외하고 build-meta-hashes.txt로 별도 기록.

## 결론
삭제 스택(#55162/#55180/#55203)은 산출물 파일 목록을 바꾸지 않았고(263=263), 261개 중 260개 파일이 byte-identical이며, 나머지 1개 CSS의 차이도 삭제된 unreachable 파일에서만 유래한 dead class 제거에 한정된다. 앱 동작 코드는 완전히 동일.

## 계약 2항 (설정 변경) 증거
- contract2-evidence.txt: .github/workflows/pr-type-check.yml에 check:unreached 단계 추가(d81ecc4232), package.json에 check:unreached 스크립트 추가(afd89812d7), 가드 스크립트 추가. eslint.config.mjs는 삭제 파일 참조가 없어 변경 없음.

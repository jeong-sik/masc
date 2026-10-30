# Artifact reader focus

## 공통 헤더

- 날짜(ISO8601): 2026-10-19T05:15:58.759Z
- 작성자: Codex
- 결정 ID: artifact-reader-focus-20261019
- 적용 대상: PR #43929
- 결정 상태: 확정 (아래 실제 브라우저 범위)

## 근거 (Evidence)

- 항목: 아티팩트를 선택하면 대시보드를 가리는 화면 전체 읽기로 전환한다.
- 출처: [브라우저 실행 영수증](browser-receipt.json), [HTML 데스크톱](desktop-html.png), [HTML 모바일](mobile-html.png), [Markdown](desktop-markdown.png). 실제 API와 Playwright를 사용했고 HTTP 응답 mock은 사용하지 않았다.
- 확인일시: 2026-10-19T05:15:58.759Z
- 신뢰도: High
- 제한조건: 변경한 Vite frontend와 별도 격리 서버의 기존 아티팩트를 사용했다. 서버와 frontend가 같은 commit인 릴리즈 검증 또는 운영 배포 증명이 아니다. 제품 frontend 파일의 SHA256은 영수증에 기록했다.

## 검증 (Verification)

- 1차: 1440×1000에서 native dialog가 x0/y0에서 viewport 전체를 차지하고 HTML frame이 남은876.25px를 채웠다. native modal 상태와 가로 넘침 없음도 확인했다.
- 2차: HTML 버튼 조작, reader 조작부에서 Escape로 닫기, 검색어 보존, 목록으로 버튼으로 닫기, Markdown·원본·버전 선택, 버전 링크 새로고침을 확인했다.
- 3차: 390×844 모바일에서도 전체 viewport와 가로 넘침 없음, HTML 버튼 조작 및 목록 복귀를 확인했다. 예상하지 않은 pageerror는0개였다. 세 스크린샷을 직접 열어 확인했다.
- 재현 결과: 관련 surface/card/copyable-code 검사32개와 변경 파일 ESLint가 통과했다. 전체 typecheck에는 기존 dashboard-turn-records.ts:7의 unused import2건만 남았고 #43871에서 추적한다.

초기 시도에서는 iframe에 포커스를 둔 Escape가 브라우저에 따라 부모 dialog를 닫지 못했다. iframe key event를 상위 대시보드로 전달하는 bridge를 추가하지 않았다. 최종 Escape 검증은 reader 조작부에 포커스를 두고 실행했으며, 상단의 목록으로 버튼은 iframe 조작 뒤에도 사용할 수 있음을 실제로 확인했다.

독립 소스 리뷰가 전역 toast가 modal 뒤에 가리는 P2를 찾아 reader 내부 role=status로 옮겼다. 이 과정에서 실제 clipboard fallback의 body textarea가 inert 배경에 놓여, 성공을 표시해도 이전 링크가 clipboard에 남는 조건을 재현했다. reader에서만 helper의 optional container로 dialog를 전달해 기본 호출 동작을 유지하면서 고쳤다. [복사 영수증](copy-receipt.json)은 실제 native clipboard 최신 링크, writeText 거절 후 실제 execCommand fallback의 revision=1 링크, 두 platform 동작을 거절한 조건의 실패 문구를 확인한다. 마지막 실패 조건은 결정적인 platform stub이며 실제 HTTP mock은 없다. 성공뿐 아니라 fallback의 실제 clipboard 바이트를 대조했다.

## 불확실성 (Uncertainty)

- 미확인 항목: iframe 내부 포커스에서의 Escape 닫기는 보장하지 않는다. 실제 운영 설치와 전체 회귀는 미실행이다.
- 영향: 화면 전체 읽기와 확인한 사용자 조작만 입증한다. HTML의 opaque origin 및 CSP 정책은 그대로다.
- 추가 확인 필요: 운영 반영 시 설치된 frontend·server identity를 별도로 확인한다.

## 적용범위 (Scope)

- 영향 받는 영역: Artifacts catalog, reader, 기존 브라우저 검증 하네스, 영문·한글 매뉴얼과 설계 설명.
- 제약/배제: backend·아티팩트 원문·버전·인증·sandbox 정책을 변경하지 않는다. 이 실행의 Markdown 원문은 이전에 게시한 불변 버전이다.
- 롤백 조건: viewport, 목록 복귀 또는 원본·버전 선택이 재현되지 않으면 이 기록을 완료 근거로 사용하지 않는다.

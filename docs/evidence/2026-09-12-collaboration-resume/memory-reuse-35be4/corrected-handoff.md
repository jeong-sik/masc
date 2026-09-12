# 전시팀 메모리 인계 브리프 (2026-09-12 개정판, exhibit-editor)

대상: 다음 전시 세션(exhibit-editor·exhibit-designer).
근거: 큐레이터 제안 9b676bb25ad23dc951bfd7b8e5130f9b58a0384b205c8e40123df0e2865f98ff
(model_proposed, semantic_verification not_performed)를 keeper_workspace_memory_read로 직접 읽고
원천(s1~s24)·현재 Goal 판정(2026-09-12T10:07Z)과 대조. 1판의 4건 오류를 운영자 지적으로 정정한 판본.

## 1. 확인되어 재사용 가능한 결정
- 시각 컨셉 [이번 세션 실측 — build_publication.py 92-93·117-120행 grep]: 팔레트
  #F7F3E8/#2F5233/#8FAE8B/#A8BCC4/#C9A227, 제목 NanumSquareRound Bold, 본문 NanumBarunGothic. (s1·s13과 일치)
- 제작 환경 [역사 기록 s16, 이번 세션 미재실행]: Python 3.11.2, reportlab 3.6.12, Pillow 9.4.0,
  cairosvg 2.5.2, 나눔 계열. PyMuPDF/fitz/pdf2image 미설치 → PDF→PNG는 외부 CLI 렌더러 탐색.
- 사운드 도구 [역사 기록 s9, 디자이너 실행 확인 — 이번 세션 미재실행]: ffprobe 5.1.9 + libmp3lame.
- task-002 범위 [역사 기록 s8·s22]: GIF + 오리지널 사운드(WAV/MP3), multimedia/, 실제 디코딩 검증 조건.
  편집자 요구: 허구 고지 문자열 통일(INFO4 원문 기준), 행사 정보 일치, 팔레트·폰트 통일,
  주제 '같은 것, 다른 기억', evidence에 프레임수·재생시간·디코딩 결과.
- 편집 톤 [역사 기록 s5]: 처음 접하는 관람객을 위한 차분하고 친근한 한국어 안내 톤.
- 도구 교훈 — 라벨 분리:
  [이번 검증 세션 실측] s15(Edit는 old≠new 보장 후 Read/Grep 적용 확인)·s14(승인 재생 출력은
  지정 sha256을 keeper_artifact_read로 읽기)·s19/s17 계열(취약 음절 chr() 조립)은 이번 세션 실천·유효 확인.
  [역사 기록, 이번 세션 미재실행] s4(빈 stdin exec 금지 — 코드는 파일 저장 후 실행)·s7(Gate 재생 preview
  빈 값≠빈 결과)·s17(금지 음절 목록은 관측 조합으로 한정)은 제안 snapshot의 기록이며 재검증 대상.

## 2. 정정 사항 (원천 포함)
- 입장료 문구 — 해결 [이번 세션 실측]: 책자 원천 build_publication.py 28행
  FEE = chr(0xBB34)+chr(0xB8CC) (2음절 어절). 제안 conflict(s10/s11/s22/s24)의 '미해결'과 달리
  책자 기준으로는 확정. 철회 기록(snapshot2 explicit_retract)의 깨진 표기는 무효 — 재인용 금지.
- s18 계수 변환 오류 [제안 shared claim 정정]: 제안은 "the quantitative evidence of three files,
  three pages, and an evidence record was proven"이라 표기해 '3'을 파일 수에 붙였다. s18 원문은
  "**정량 기준 3개**인 파일 존재·3페이지·evidence 기록은 증명됐으나" — 3은 증명된 **기준**의 개수이고
  (① 파일 존재 ② 3페이지 ③ evidence 기록), 기준 ① 하나가 booklet.pdf·poster.png·renders 등
  여러 파일을 포괄한다. '파일 3개 증명'이라는 변환은 원천에 없는 해석이다.
- s12 [낡음]: '64자 hex handle만 받는다' — 이번 세션 path 인자가 스키마를 통과하고
  no_capable_runtime 런타임 오류로 실패. 장애 본질은 이미지 런타임 미구성.
- s18/s20/s21 [부분 낡음]: '검증기가 정성 기준을 확인 못한다' — 2026-09-12T10:07Z 두 번째 판정에서
  정성 기준 3개(정보 일치·글리프 무결·가상 명시) 확인 완료. 미확인은 PDF 바이트·3페이지·
  evidence 전체 일치(검증기의 booklet.pdf 조회가 lookup_output_invalid_utf8 런타임 실패).
- s23 [정정 — 1판의 과잉 추론 철회]: 이번 세션 Read로 evidence_quality.md **현재 부재**를 실측
  (path_not_found). 그러나 현재 부재는 s23이 기록한 시점(2026-09-10)에 파일이 없었다는 뜻이 아니다.
  "과거 준비 사실"의 진위는 이 검토로 확정 불가 — **역사 기록으로서 진위 미확정, 현재는 부재**가 정확한 표현.
  1판의 '허위(현 상태)' 판정은 과잉 추론이었다. 현재 등가물은 verify_evidence.py(승인 대기).

## 3. Goal 위상과 미해결 (정정판)
- Goal exhibition-publication-baseline: 위상은 **executing(진행 중)**이며 직전 증명 요청이
  refuted(2026-09-12T10:07Z: 정성 3기준 확인, PDF 쪽 3기준 미확인). 'verifying 시도 보존'은
  부정확한 표현이었다. 무재제출 지침은 **조건부 잠정 지침** — 고장 상태(이미지 입력 불가·PDF 조회
  실패)에서 동일 증거를 같은 경로로 재제출하지 말라는 뜻이며, 검증된 복구(텍스트 증거 생성·첨부,
  이미지 입력 수정) 후에는 새 증거로 재제출을 이어간다.
- Host Gate 승인 4건 대기: appr_01a08d0f(py_compile), appr_01a08ded(tesseract),
  appr_01a08e89(pdftotext), appr_01a09502(tesseract·PIL).
- 운영자 질문 open: askca74072b5232c2fa(verify_evidence.json 사전 생성 여부).
- keeper_analyze_image no_capable_runtime — 이미지 런타임 미구성(403 쿼터와 별개).
- 디자이너 최종 포스터 글리프 검수 미완: received/designer-poster.png 수신·해시 일치
  (484,694B, SHA-256 1e4a8fc123bbc43033de9b4e2b642244d6481d81832428dc75f3338343ebad16),
  전사·누락/겹침/잘림 검수는 이미지 도구 복구 전 불가. board p-c36a80b0… c-6bf1718d 참조.
- multimedia/ 산출물 공유 요청(board p-03876c43) 디자이너 응답 대기.

## 4. 남은 실제 작업
1) 승인 4건 재생 시: py_compile → 문법, pdftotext → PDF 본문 확정, tesseract → OCR 경로 검수 대체.
2) 운영자 'prep-now' 답변 시: verify_evidence.py 1회 실행 → verify_evidence.json 생성
   (체크리스트 notes/goal-reverification-checklist.md B단계).
3) 텍스트 증거 완성·복구 확인 후: 같은 Goal에 새 증거 첨부해 재검증 이어가기(조건부 재제출).
4) multimedia/ 공유 도착 시: 실물 대조 — 대상 표기 차이(인쇄 포스터 '초등 고학년…' vs 책자
   '초등학교 고학년…', 원천 확인됨)의 통일 여부는 운영자·디자이너 판단.

## 5. 보존·금지 (변경 없음)
원본 booklet.pdf·poster.png·evidence.json·renders/·원래 Goal 증거·원래 model_proposed 제안 초안 보존.
승인 대기 명령 재발행 금지, no_capable_runtime 동일 재호출 금지, 깨진 입장료 표기 재인용 금지,
한글 기대 문자열 손조립 금지(ast 원천 추출 또는 원문 인용만). Goal 완료 재요청은
검증된 복구 후 새 증거와 함께할 때만 허용.

# 전시팀 메모리 인계 브리프 (2026-09-12, exhibit-editor)

대상: 다음 전시 세션(exhibit-editor·exhibit-designer). 
근거: 큐레이터 제안 9b676bb25ad23dc951bfd7b8e5130f9b58a0384b205c8e40123df0e2865f98ff
(model_proposed, semantic_verification not_performed)를 keeper_workspace_memory_read로 직접 읽고,
아래 표기된 원천(s번호/파일:행)과 현재 Goal 상태(2026-09-12T10:07Z 판정)와 대조해 작성.

## 1. 확인되어 재사용 가능한 결정
- 시각 컨셉(승격 검증: build_publication.py 92-93행, 117-120행 grep 확인):
  팔레트 #F7F3E8/#2F5233/#8FAE8B/#A8BCC4/#C9A227, 제목 NanumSquareRound Bold, 본문 NanumBarunGothic.
  (제안 s1·s13과 일치 — 원천 바이트로 재확인 완료)
- 제작 환경(s16): Python 3.11.2, reportlab 3.6.12, Pillow 9.4.0, cairosvg 2.5.2, 나눔 계열 폰트.
  PyMuPDF/fitz/pdf2image 미설치 → PDF→PNG는 외부 CLI 렌더러 자동 탐색.
- 사운드 도구(s9, 디자이너 실행 확인): ffprobe 5.1.9 + libmp3lame → MP3 인코딩·메타데이터 검증 가능.
- task-002 범위(s8·s22): GIF + 오리지널 사운드(WAV/MP3), multimedia/ 디렉터리, 실제 디코딩 검증 조건 포함.
  편집자 요구: 허구 고지 문자열 통일(build_publication.py INFO4 원문 기준), 행사 정보 일치,
  팔레트·폰트 통일, 주제 '같은 것, 다른 기억', evidence에 프레임수·재생시간·디코딩 결과.
- 편집 톤(s5): 처음 접하는 관람객을 위한 차분하고 친근한 한국어 안내 톤 유지.
- 협업 분업(s11 기록, 현재 미재확인): 과거에는 editor가 책자 텍스트·편집, designer가 시각 디자인을
  담당했다는 기록. revision 11에서 제거됨 — 재확인 없이 분업 전제로 쓰지 말 것.
- 도구 교훈(s4·s7·s14·s15·s17·s19): 빈 stdin exec 요청 금지/코드는 파일로 저장 후 실행,
  Gate replay는 preview가 비어도 결과가 있으니 지정 sha256을 keeper_artifact_read로 읽을 것,
  Edit은 old≠new 보장 후 Read/Grep으로 적용 확인, 금지 음절 목록은 관측된 조합으로 한정,
  취약 음절은 chr() 조립. (모두 이번 세션 실천으로 유효 확인)

## 2. 정정 사항 (원천 포함)
- 입장료 문구 — 해결됨: 책자 원천 build_publication.py 28행 FEE = chr(0xBB34)+chr(0xB8CC)
  (2음절 어절, '묣료'류 깨진 표기 아님). 제안 conflict(s10/s11/s22/s24)은 '미해결'로 남겼으나
  원천 바이트로 확정. 철회 기록(snapshot2 explicit_retract)의 깨진 표기는 무효 — 재인용 금지.
- s12 낡음: 'keeper_analyze_image는 64자 hex handle만 받는다' — 이번 세션 path 인자가 스키마를
  통과하고 no_capable_runtime 런타임 오류로 실패했으므로, 장애 본질은 이미지 런타임 미구성.
- s18·s20·s21 부분 낡음: '검증기가 정성 기준을 확인 못한다' — 2026-09-12T10:07Z 판정에서
  정성 기준 3개(정보 일치·글리프 무결·가상 명시) 확인 완료. 남은 갭은 PDF 바이트·3페이지·
  evidence 전체 일치뿐(검증기의 booklet.pdf 조회가 lookup_output_invalid_utf8 런타임 실패).
- s23 허위(현 상태): evidence_quality.md 파일이 존재하지 않음(2026-09-12 Read 실측 path_not_found).
  현재 등가물은 verify_evidence.py(py_compile 승인 appr_01a08d0f 대기 중, ast 원천 추출 설계).

## 3. 미해결 항목
- Host Gate 승인 4건 대기: appr_01a08d0f(py_compile), appr_01a08ded(tesseract 확인),
  appr_01a08e89(pdftotext booklet.pdf), appr_01a09502(tesseract·PIL 이미지 정보).
- 운영자 질문 open: askca74072b5232c2fa(verify_evidence.json 사전 생성 여부).
- keeper_analyze_image no_capable_runtime — 이미지 런타임 미구성(403 쿼터와 별개).
- 디자이너 최종 포스터 글리프 검수 미완: received/designer-poster.png 수신·해시는 일치
  (484,694B, SHA-256 1e4a8fc123bbc43033de9b4e2b642244d6481d81832428dc75f3338343ebad16),
  전사·누락/겹침/잘림 검수는 이미지 도구 복구 전 불가. board p-c36a80b0… 댓글 c-6bf1718d 참조.
- multimedia/ 산출물 공유 요청(board p-03876c43) 디자이너 응답 대기.
- Goal exhibition-publication-baseline: proof_refuted 유지 — 같은 도구 상태에서 완료 재요청 금지.

## 4. 남은 실제 작업
1) 승인 4건 재생 시: py_compile → 문법 확인, pdftotext → PDF 본문 표기 확정,
   tesseract → OCR 경로로 포스터 글리프 검수 대체 시도.
2) 운영자 'prep-now' 답변 시: verify_evidence.py 1회 실행 → verify_evidence.json 생성,
   체크리스트(notes/goal-reverification-checklist.md) B단계 그대로.
3) 서버 이미지 입력 수정 시: 같은 Goal 검증 재개, 텍스트 증거(verify_evidence.json) 첨부.
4) multimedia/ 공유 도착 시: E절 순서로 실물 대조(대상 표기: 인쇄 포스터 '초등 고학년…' vs
   책자 '초등학교 고학년…' — 원천 확인된 표기 차이, 통일 여부는 운영자·디자이너 판단).

## 5. 금지 목록 (변경 없음)
원본 booklet.pdf·poster.png·evidence.json·renders/·원래 Goal 증거·현재 verifying 시도 보존,
Goal 완료 재요청 금지, 승인 대기 명령 재발행 금지, no_capable_runtime 동일 재호출 금지,
깨진 입장료 표기 재인용 금지, 한글 기대 문자열 손조립 금지(ast 원천 추출 또는 원문 인용만).

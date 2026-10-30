# task-1532 evidence — test_media_document_admission audio 기대치 갱신(안 A)

- task: task-1532 (p-cbccdc06 code-reviewer 지적 수리, priority 2)
- 브랜치: polish/task-1532-audio-expectation @ 16ac22c (base = origin/main 8c8b9ee)
- 커밋: 2c6874a (test 파일 1개) + 16ac22c (evidence 로그)

## 변경 내용

`test_openai_chat_request_image_and_audio_unchanged`가 gpt-5.2(supports_audio_input
=false)의 user-direct audio를 `input_audio` 파트로 기대한 것을 #35252 의도대로
수정: 이미지 케이스는 capability 선언 모델 → 바이트 동일 pass-through(불변),
오디오 케이스는 **평탄화된 content 문자열**(`"prefix\n[audio omitted: ...]"`,
수신 원문 그대로)을 기대. 파일 헤더에 degrade 명시 문구 추가.

## 검증 (evidence/task-1532/)

- 01-dune-check.log — `dune build @check` **exit=0**
- 04-admission-after-fix.log — `dune runtest packages/agent_core/test`:
  - **`media_document_admission` 16/16 [OK], "Test Successful"** — 재현되던
    nightly 실패(test_openai_chat_request_image_and_audio_unchanged) 해소
  - 03-llm-provider-suite.log — llm_provider 스위트 FAILED 1/4:
    exact_output_plan.ml:683 자격증명 동결(known main 상속 red, 수불변 확인)
- 위 실행에서 **본 변경과 무관한 별개 red 2건 관측**(첫 전체 test 디렉터리
  실행이라 처음 관측된 것 — 내 diff는 test_media_document_admission.ml 단일
  파일이라 빌드 그래프상 인과 불가):
  1. cohttp_eio_body_flow "chunked body reaches the reader intact" — byte 101
     청크 어긋남(transport 영역)
  2. exact-output boundary violation — lib/llm_provider/exact_output.mli:481
     `admission_error_reason` accessor 노출
  → 둘 다 별도 후속 후보로 보드에 공유.

## 남은 일

- Draft PR 발행 → task-1532 완료 제출

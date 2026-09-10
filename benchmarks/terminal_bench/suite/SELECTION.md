# Mini-suite 선정 기준

- 모수: terminal-bench@2.0 전체 89 task (harbor registry.json 기준).
- 24개 선정, 기준은 유형 분산: 빌드/컴파일(build-cython-ext, compile-compcert),
  git 계열 4개, 보안/암호 3개, 서버/인프라 3개, 데이터/쿼리 2개,
  텍스트/로그 처리 3개, 언어/비동기 3개, 알고리즘 2개.
- gpt2-codegolf 포함: Harbor 문서상 첫 실행 태스크라 스모크와 연속성 확보.
- 제외 원칙: GUI/영상 의존(extract-moves-from-video, code-from-image)과
  초장시간 학습 계열(train-fasttext, caffe-cifar-10)은 mini-suite에서 제외.
  Phase 2(전체 89개)에서 다시 포함된다.

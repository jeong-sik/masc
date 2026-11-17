# 표와 차트 문서 왕복 확인

Dashboard의 실제 파일 가져오기·원고 편집·다운로드 컴포넌트를 연다.
게시 API와 작업 공간 응답은 이 탭의 메모리로 대체한다. MASC에 게시하지 않는다.

```sh
cd dashboard
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 pnpm exec vite --host 127.0.0.1 --port 5187 --strictPort
# /dashboard/fixtures/office-roundtrip/ 열기
node --import tsx fixtures/office-roundtrip/browser.mjs
```

수동 확인은 별도 브라우저 프로필과 전용 포트에서 한다.
자동 검사는 새 브라우저 컨텍스트를 쓴다. 기존 Dashboard 탭에서 열지 않는다.

브라우저 검사는 병합 표와 native 차트 4개를 DOCX/HWPX로 내려받는다.
각 파일을 다시 가져와 첫 차트 값 `12.5`를 `42`로 고쳐 게시한다.
재출력한 실제 다운로드를 읽어 차트 값과 병합 정보를 확인한다.
실행 결과·파일·화면·trace는 `artifacts/dashboard/office-roundtrip/run-*/`에 남는다.

이 검사는 실제 MASC 서버의 저장이나 한컴·Microsoft Word 실행을 대신하지 않는다.
2026-11-16 macOS 직접 실행은 시작 단계에서 실패했다.
공식 Playwright 1.61.1 Linux arm64 컨테이너에서는 실제 컴포넌트·worker·WASM으로
HWP와 두 Office 형식을 검사했다. 12개 흐름과 다운로드 14개의 데이터를 대조했다.
범위와 외부 Office 출력은 [검증 기록](../../../docs/evidence/artifact-office-browser-2026-11-16.md)을 따른다.

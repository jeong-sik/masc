# keeper-v2 design prototype (vendored SSOT)

대시보드 v2 디자인의 원본 소스. 그동안 이 프로토타입은 레포 밖
(`~/Downloads/.../keeper-v2/`)에만 존재했고, 라이브 CSS의 provenance 주석
`/* v2.css:NNN */` 은 **레포에서 열 수 없는 파일**을 가리켰다 (`find . -name v2.css` → 0건).
그래서 PR 리뷰어가 인용된 값을 검증하거나 드리프트를 재동기화할 방법이 없었다.

이 디렉토리는 그 원본을 레포 안으로 들여와 provenance를 **검증 가능**하게 만든다.

## 이건 참조이지 빌드 입력이 아니다

- `styles/` 와 `notes/` 는 Vite 빌드에 포함되지 않는다 (`src/` 밖, `import` 없음).
- 라이브에 적용되는 CSS는 여전히 `src/styles/` 다.
- 여기 파일들은 라이브 CSS가 **무엇을 재현하려 했는지**의 기준점이다.

## provenance 해소

라이브 CSS의 `/* v2.css:NNN */` 주석은 이제 다음으로 해소된다:

```
design-system/prototype-v2/styles/v2.css : NNN 행
```

surface별 셀렉터 → 파일 매핑은 `notes/css-map.md` 의 역인덱스를 따른다
(`.ov-*`/`.set-*`/`.ap-*` → `surfaces.css`, 셸·채팅·로스터 → `v2.css` 등).

## 핵심 경고 (notes/css-map.md §"레이아웃은 CSS만으로 안 됨")

keepers 화면의 4-컬럼 폭(nav·로스터·채팅·컨텍스트)은 **CSS가 아니라
`app.jsx` 의 인라인 `gridTemplateColumns` 로 계산**된다. CSS만 포팅하면
색·간격은 가까워져도 레이아웃 구조는 재현되지 않는다. 라이브 셸 레이아웃을
프로토타입에 맞추려면 그 JS 계산 로직을 함께 이식해야 한다.

## 폰트

폰트 바이너리(`Cinzel`, `Noto Sans KR`)는 의도적으로 제외했다 — 이미
`public/assets/fonts/` 에 존재한다. 벤더 CSS의 `@font-face`/`@import` 는
참조용이며 빌드에 쓰이지 않는다.

## 드리프트 점검

라이브 토큰을 바꿀 때 이 SSOT와 어긋나는지 확인하려면, 같은 토큰 키를
`styles/v2.css` (또는 surface별 파일)와 `src/styles/` 에서 대조한다.

## 출처

`~/Downloads/v2 2/project/keeper-v2/` (standalone 23MB HTML + jsx 컴포넌트 +
14개 CSS). 컴포넌트 소스(`*.jsx`)는 레이아웃/컴포넌트 포팅 단계에서 필요할 때
추가 벤더링한다. 23MB standalone HTML 은 빌드 산출물이라 제외했다.

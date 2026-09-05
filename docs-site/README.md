# MASC docs-site

이 디렉터리는 MASC 사용자 문서 사이트(Astro + Starlight)입니다. 한국어와
영어 두 판을 같은 트리에서 관리합니다.

## 구조

```
src/content/docs/          영어 문서 (기본 언어)
src/content/docs/ko/       한국어 문서 (영어와 같은 구조로 대응)
src/components/            랜딩 페이지(HomeLanding.astro) 등 공용 컴포넌트
astro.config.mjs           사이드바·언어 설정
```

- 페이지 추가·수정 시 영어와 한국어(`ko/`)를 같이 고친다. 한쪽만 고치면
  미러가 어긋난다.
- 사이드바 항목은 `astro.config.mjs`의 `sidebar`에 직접 등록한다.
- 문서의 사실(키 바인딩, 명령, 파일 경로, 버전)은 repo의 소스코드가
  근원이다. 문서를 먼저 믿지 않는다.

## 명령

패키지 매니저는 pnpm이다. npm을 쓰면 잠금 파일이 어긋난다.

| 명령 | 동작 |
| :--- | :--- |
| `pnpm install` | 의존성 설치 |
| `pnpm dev` | 로컬 개발 서버 `localhost:4321` |
| `pnpm build` | `./dist/`에 프로덕션 빌드 |
| `pnpm preview` | 빌드 결과 미리보기 |

## 문서 수정 원칙

- 담백한 기술 문서체로 쓴다. 동작을 설명하고 가치를 주장하지 않는다.
- 화면의 키·명령은 `bin/masc_tui_keys.ml`, `bin/masc_tui_types.ml` 등
  소스에서 확인한 뒤 쓴다.
- 근거가 repo에 없는 주장(유래 설화, 검증 안 된 수치)은 넣지 않는다.

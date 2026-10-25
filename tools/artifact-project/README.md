# npm·React 아티팩트 실행기

프로젝트 파일과 npm 의존성을 설치하고, HTML 진입점의 JavaScript·TypeScript·JSX·TSX 모듈을 하나의 HTML로 묶는 실행기입니다. 결과 HTML은 기존 아티팩트 게시 API/`keeper_artifact_publish`로 게시할 수 있습니다.

이 실행기는 **기존 Keeper 실행 레인 안에서 호출**합니다. 자체 샌드박스가 아니며, Dashboard나 HTTP 핸들러에서 실행하지 않습니다. 설치 스크립트 허용은 실제 프로젝트 코드를 실행하므로 호출자가 선택한 레인의 파일·네트워크 권한이 적용됩니다. 기존 실행 레인의 취소/프로세스 수명 관리를 그대로 사용합니다.

현재 층은 실행기와 파일 계약입니다. Dashboard의 폴더/ZIP 가져오기, 서버의 작업 저장·실행 레인 배정, 진행 상태, 결과 게시 연결은 다음 층에서 추가해야 합니다. 이 디렉터리만으로 프로젝트 가져오기 기능이 완성됐다는 뜻은 아닙니다.

## 준비와 호출

Node 22.18 이상, npm이 있는 실행 레인에 이 디렉터리를 설치합니다. 의존성 버전과 무결성은 함께 제공한 package-lock.json을 따릅니다.

```sh
npm ci --ignore-scripts --no-audit --no-fund
mkdir -p .artifact-runs
node --experimental-strip-types src/cli.ts --workspace .artifact-runs < project.json > project-result.json
```

프로젝트의 설치 로그는 stderr로, 결과 JSON 한 개는 stdout으로 보냅니다. 결과 전체는 파일로 보관하세요. 일반 도구 출력의 미리보기는 큰 HTML을 자를 수 있습니다. 성공은 exit 0, 실패는 exit 2와 `ok:false`입니다. 실패에도 생성된 작업 디렉터리와 요청·실패 기록을 보존합니다. 자동 재시도나 정리 작업은 하지 않습니다.

`--workspace`는 호출자가 선택한 기존 레인 디렉터리입니다. 요청 JSON으로 경로나 실행 레인을 바꾸지 않습니다. 매번 그 안에 새 작업 디렉터리를 만들며 원래 요청 파일을 덮어쓰지 않습니다.

## 입력

```json
{
  "schema": "masc.artifact_project.v1",
  "entry_html": "index.html",
  "install_scripts": false,
  "files": [
    { "path": "package.json", "content_base64": "e30=" },
    { "path": "index.html", "content_base64": "PHA+TWFzYzwvcD4=" }
  ]
}
```

`files`에는 정규 base64 파일 바이트를 넣습니다. package.json과 HTML 진입점이 필요합니다. 경로는 `/`로 구분한 상대 경로이며 `..`, 절대 경로, 중복 경로, node_modules와 .git은 받지 않습니다. 파일은 `wx`로 새로 만들므로 파일명 별칭이 다른 입력을 덮어쓰지 않습니다. 원래 업로드 바이트의 SHA와 실제 빌드 입력을 결과에 따로 남깁니다.

package-lock.json 또는 npm-shrinkwrap.json이 있으면 `npm ci`, 없으면 `npm install`을 실행합니다. 개발 의존성도 포함합니다. 설치 후 잠금 파일 내용과 SHA를 결과에 보관합니다. `install_scripts:false`는 설치 훅을 생략하며, true이면 npm의 설치 스크립트 정책에 따라 훅을 실행합니다. 호스트 환경의 인증 정보와 NODE_OPTIONS는 npm에 전달하지 않습니다. 새 HOME·설정 경로·캐시와 PATH만 사용하며, 가져온 프로젝트의 .npmrc는 그 프로젝트 설정으로 적용됩니다.

## 변환과 결과

HTML의 단일 module 진입점(로컬 script 또는 인라인 module)을 esbuild의 실제 브라우저 모듈 그래프로 묶습니다. npm 패키지, JSX 자동 런타임, TypeScript, JSON, CSS import와 동적 import를 지원합니다. 로컬 CSS link/style는 원래 위치에서 변환해 CSS 순서와 media를 유지합니다. 이미지·폰트·미디어는 data URL로 넣고, 인라인 style은 CSS AST의 URL을 변환합니다. 사용자 정의 CSS 속성의 URL도 포함합니다. 컴파일러 파일 로더는 설치된 프로젝트 디렉터리 밖의 파일을 거절합니다.

결과의 `artifact.content`가 게시할 HTML이고 `artifact.sha256`은 그 UTF-8 바이트의 SHA입니다. 이 값은 원래 프로젝트의 SHA와 다릅니다. 요청 원문은 `request.json`, 결과는 `result.json`에 보관합니다. 잠금 파일은 빌드 재현을 위해 반환하며 원래 입력 파일은 수정하지 않습니다. 실행 중인 앱의 입력은 기존 HTML 아티팩트 입력 저장 기능을 사용합니다.

외부 리소스는 가져오지 않습니다. 원문에 있는 외부 module import·CSS import·URL은 외부 연결로 남을 수 있으며, 읽기 화면에서 사용자가 허용한 출처와 브라우저 CORS/CSP 규칙을 따릅니다. 결과의 `external_resources`는 HTML에서 직접 관측한 외부 URL 목록이며 전체 실행 시 네트워크 요청 목록이 아닙니다. 원문 CSP도 유지합니다. npm 설치 네트워크는 기존 실행 레인의 네트워크 정책을 따릅니다.

현재 이 실행기는 브라우저 모듈을 직접 묶습니다. Vite/Webpack/Next 설정이나 package.json의 build 스크립트를 실행하는 범용 프레임워크 빌더는 아직 아닙니다. 서버 앱·여러 HTML 페이지/여러 module 진입점·플러그인이 필요한 query import·import map·base URL·srcset·classic async/defer·추가 module 속성은 지원하지 않습니다. 해당 경계를 발견하면 오류로 알리며, 지원하지 않는 구문이 모든 경우 자동 검출된다고 보장하지 않습니다. 이 경계와 폴더/ZIP UI·실제 Keeper 레인 배정을 후속 작업에서 연결해야 원래 프로젝트 실행 요구를 충족합니다.

## 검증

```sh
npm run check
npm test
```

focused 검사는 실제 npm 설치와 잠금 파일 재설치, React·clsx 실행, TSX·동적 import, CSS 순서/사용자 정의 속성/그림 바이트, 설치 훅 선택과 환경 분리, 경로 및 프로젝트 밖 import 거절을 확인합니다. DOM 실행 검사는 HappyDOM이며 실제 브라우저 검증은 별도입니다.

[근거] [esbuild API](https://esbuild.github.io/api/), [npm ci](https://docs.npmjs.com/cli/v11/commands/npm-ci/), 고정 설치본 esbuild 0.28.2 / parse5 8.0.1 / css-tree 3.2.1 직접 확인. 2026-10-26 KST · High. 위 버전의 설치·변환 계약에 한정합니다.

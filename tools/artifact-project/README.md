# npm·React 프로젝트 실행기

프로젝트 파일을 새 작업 디렉터리에 만들고 npm 의존성을 설치합니다. 프로젝트의 빌드 스크립트를 실행해 정적 사이트 전체를 보관하거나, 브라우저 모듈을 HTML 하나로 묶을 수 있습니다.

기존 Keeper 실행 레인 안에서 호출하는 실행기입니다. 자체 샌드박스가 아니며 Dashboard나 HTTP 핸들러에서 프로젝트 코드를 실행하지 않습니다. 설치 훅·빌드 스크립트·프레임워크 설정/플러그인은 선택한 레인의 실제 권한으로 실행됩니다. 취소/프로세스 수명 관리도 기존 레인이 담당합니다.

현재 층은 파일 계약과 실행기입니다. 폴더/ZIP 가져오기 화면, 서버 작업 저장·실제 Keeper 배정·진행 상태, 사이트 자산의 게시/서빙·미리보기 연결은 후속 작업입니다. 일반적인 서버 앱을 실행하거나 배포하는 기능은 아닙니다.

## 준비와 호출

Node 22.18 이상과 npm이 있는 실행 환경에 이 디렉터리를 준비합니다. 도구 의존성은 package-lock.json에 고정돼 있습니다.

```sh
npm ci --ignore-scripts --no-audit --no-fund
mkdir -p .artifact-runs
node --experimental-strip-types src/cli.ts --workspace .artifact-runs < project.json > project-result.json
```

요청 JSON 하나를 stdin으로 받고 결과 JSON 하나를 stdout으로 보냅니다. 설치/빌드 로그는 stderr입니다. 일반 도구의 미리보기는 큰 HTML이나 사이트 데이터를 자를 수 있으므로 전체 결과는 파일로 보관합니다. 성공은 exit 0/ok:true, 실패는 exit 2/ok:false와 알려진 작업 경로입니다. 생성한 요청·결과·실패 기록을 남기며 자동 재시도나 정리는 하지 않습니다.

`--workspace`는 호출자가 선택한 기존 레인 디렉터리입니다. 매번 그 안에 새 private 작업 디렉터리를 만들고 원래 업로드를 덮어쓰지 않습니다. Node가 없는 기본 이미지에 이 실행기만 복사해도 실행되지는 않습니다.

## 입력: 프로젝트 빌드 스크립트

```json
{
  "schema": "masc.artifact_project.v1",
  "install_scripts": false,
  "build": {
    "kind": "package_script",
    "script": "build",
    "output_directory": "dist",
    "entry_html": "index.html"
  },
  "files": [
    { "path": "package.json", "content_base64": "..." },
    { "path": "index.html", "content_base64": "..." },
    { "path": "src/main.tsx", "content_base64": "..." }
  ]
}
```

files는 원래 프로젝트의 정규 base64 파일 바이트입니다. package.json이 필요합니다. `/`로 구분한 상대 경로만 받으며 절대 경로·경로 이탈·중복·node_modules/.git을 거절합니다. 파일은 wx로 새로 만들므로 파일명 별칭이 다른 입력을 덮어쓰지 않습니다.

script는 package.json scripts에 실제로 있는 정확한 이름입니다. 없으면 설치 전에 거절합니다. `npm run -- <이름>`을 argv로 전달하며 셸 명령을 요청 필드에서 조립하지 않습니다. 명시한 스크립트와 npm의 pre/post 동작, 프로젝트의 Vite/Webpack 등 설정/플러그인을 그대로 사용합니다. output_directory는 프로젝트 아래의 정적 출력 디렉터리이고, entry_html은 그 출력 디렉터리 안의 진입점입니다. 빌드가 HTML을 새로 만들 수 있으므로 원래 입력에 그 진입점이 있을 필요는 없습니다.

설치 잠금 파일이 있으면 그 파일을 사용합니다. 없으면 `npm install --package-lock-only --ignore-scripts`로 잠금을 먼저 만듭니다. 잠금 바이트를 캡처한 다음 실제 `npm ci`를 실행합니다. 개발 의존성도 포함합니다. install_scripts는 설치 훅 선택이며, 선택한 build 스크립트를 생략하는 옵션이 아닙니다. npm run의 pre/post 동작에는 프로젝트의 npm 설정이 적용됩니다.

npm에는 새 HOME·설정 경로·캐시와 PATH를 주고 호스트 인증 정보나 NODE_OPTIONS를 전달하지 않습니다. 업로드한 .npmrc와 .env 등은 프로젝트 자체 설정입니다. 실제 네트워크 접근은 레인의 정책을 따릅니다.

## 결과: 정적 사이트

package_script의 결과는 output.kind=site입니다. output에는 entry_html, files 배열, 전체 manifest SHA가 있습니다. 각 파일은 path·bytes·sha256·content_base64를 가집니다.

빌드가 만든 HTML·JS·CSS·이미지·폰트·분할 모듈·여러 페이지를 바이트 그대로 보관합니다. 재번들링하거나 URL을 바꾸지 않습니다. 루트 상대 경로, import.meta와 동적 import, CSS URL, 파일 사이의 관계는 원래 빌드 결과의 의미를 유지합니다. 서빙 단계도 빌드에 설정한 base 경로와 출처를 지켜야 합니다. 이 결과는 기존 단일 HTML 게시 API에 그대로 넣는 본문이 아닙니다. 파일별 저장/서빙 연결이 필요합니다.

출력은 프로젝트 내부의 실제 디렉터리여야 합니다. symlink·특수 파일은 거절합니다. 각 파일을 실제 descriptor로 읽고 파일과 디렉터리 항목/identity/timestamp를 마지막에 다시 검사해 수집 중 관측된 변경을 거절합니다. 반환한 base64 바이트가 보관 사본이며 원래 작업 디렉터리가 영원히 불변이라는 뜻은 아닙니다. 모든 일반 파일을 보관하며 임의 요약이나 파일 수 제한으로 자르지 않습니다. HTML 진입점은 존재하고 UTF-8이어야 합니다.

전체 SHA는 정렬해 순회한 파일의 `{path,bytes,sha256}` 목록과 entry_html을 JSON.stringify한 UTF-8 바이트의 SHA256입니다. 각 파일의 SHA는 실제 원본 바이트에서 계산합니다. 원문 CSP/외부 URL도 그대로이므로 실제 실행 시 브라우저/서빙 정책을 별도로 지켜야 합니다.

install.mode는 실제 ci이고 lock_source는 supplied 또는 resolved입니다. lock_content/lock_sha256은 설치 전에 고정한 잠금 파일입니다. 설치 훅·build/postbuild가 나중에 파일을 바꿔도 설치 근거를 그 내용으로 덮어쓰지 않습니다. 원래 업로드의 SHA와 request.json, Node 정보, 빌드 선택, 결과를 함께 남깁니다.

## 입력과 결과: 브라우저 모듈 HTML

build를 다음과 같이 지정할 수도 있습니다.

```json
{ "kind": "browser_modules", "entry_html": "index.html" }
```

이 경우 원래 files에 HTML 진입점이 있어야 합니다. 결과는 output.kind=html이고 output.artifact에 format/content/sha256을 넣습니다. 이 HTML은 기존 아티팩트 게시 API로 게시할 수 있습니다.

단일 HTML module 진입점의 npm·JSX·TSX·TypeScript·JSON·동적 import·CSS를 실제 esbuild 그래프로 묶고 로컬 자산을 data URL로 넣습니다. HTML CSS의 순서/media를 유지하고 인라인 CSS 사용자 정의 속성의 URL도 구조적으로 변환합니다. 컴파일러 파일 로더는 설치된 프로젝트 밖 파일을 거절합니다.

이 모드는 framework build를 대체하지 않습니다. 여러 module 진입점, import map/base/srcset, classic async/defer, 플러그인 query import 등은 package_script 빌드를 사용해야 합니다. 모든 미지원 구문을 자동 검출한다고 보장하지 않습니다. external_resources는 HTML에서 직접 관측한 외부 URL이며 전체 런타임 네트워크 목록은 아닙니다. 원문 CSP와 외부 URL은 유지됩니다.

## 검증

```sh
npm run check
npm test
```

실제 npm 설치/잠금 재설치, React와 Vite 설정·플러그인·별칭·pre/post build·동적 chunk, 파일 그래프의 전체 바이트/SHA와 HTTP 경로, 검증용 DOM/ESM에서의 실제 앱 동작, 잠금 변조·최종 기록 실패·출력 수집 중 변경 등을 검사합니다. DOM 실행은 SourceTextModule+HappyDOM이며 실제 브라우저/CSP/layout/프로젝트 UI·Keeper 배정은 별도입니다.

[근거] [npm run](https://docs.npmjs.com/cli/v11/commands/npm-run/), [npm ci](https://docs.npmjs.com/cli/v11/commands/npm-ci/), [Vite production build](https://vite.dev/guide/build.html), [esbuild API](https://esbuild.github.io/api/) 및 고정 설치본. 2026-10-26 KST · High. 실제 검사 범위를 전체 브라우저나 제품 통합 증거로 넓히지 않습니다.

## 프로젝트 원본 보관

네이티브 서버 쪽 `Artifact_project_source.request_of_json`은 실행기와 같은 요청 형식을 받습니다.
`Artifact_project_source_store.save`는 원본 파일을 기존 blob 저장소에 넣은 뒤, 선택한 workspace의
`.masc/artifact_project_sources/`에 파일 목록과 빌드 방식을 기록합니다. 저장할 때마다 새 ID를
만들며 이전 원본을 덮어쓰지 않습니다. 파일 목록의 normalized blob reference가 저장소 정리 때도
원본 파일을 보존합니다.

`Artifact_project_source_store.read`는 목록 파일의 소유권·권한과 각 원본의 길이·해시를 검사한 뒤
실행기 요청을 복원합니다. 의존성을 설치하거나 프로젝트 코드를 실행하지 않습니다.
`.npmrc`나 `.env` 같은 비밀 정보도 원본에 포함될 수 있으므로, 이를 호출하는 쪽에서 인증과
원본 접근 권한을 확인해야 합니다. HTTP 업로드·조회 API, 원본 편집, 빌드 결과·사이트 저장,
Keeper 실행 연결은 후속 작업이며 가져오기 화면은 아직 없습니다.

## 빌드 결과 보관

`Artifact_project_build.input_of_json`은 CLI 응답의 `result` 객체를 검사합니다.
원본 ID와 함께 `Artifact_project_build_store.save`에 넘기면, 저장된 원본의 파일 해시·빌드 방식·
설치 훅 선택·supplied lock 파일과 비교한 뒤 lock과 출력 파일을 기존 blob 저장소에 보관합니다.
각 빌드는 새 ID를 받으며 이전 결과를 덮어쓰지 않습니다. 이 검사는 결과 데이터가 원본과 맞는지
확인하며, 신뢰하는 Keeper 레인이 실제로 실행했다는 증명은 호출하는 쪽에서 연결해야 합니다.

`read`는 결과 목록과 원본 연결을 읽고, `read_file`은 정확한 사이트 경로의 파일 하나를 해시·길이
검사 후 반환합니다. 경로를 생략하면 entry HTML을 반환합니다. `restore`는 모든 파일과 lock을
읽고 실행기의 결과 형식을 복원합니다. HTML 하나로 묶은 결과와 여러 파일로 된 정적 사이트를
모두 지원하며 파일 내용과 URL 구조를 다시 쓰지 않습니다. 반환된 코드를 서버에서 실행하지 않습니다.

원본·lock·출력은 normalized blob reference로 보존합니다. 인증·문서 권한·프레임 격리와 HTTP
파일 제공, 가져오기 화면, Keeper 실행 배정·취소·진행 상태는 실제 caller에서 이어 붙여야 합니다.

---
rfc: "server-carries-its-exact-worker-packages"
title: "Exact worker package 는 서버가 싣고 다니고, 선언은 실은 package 를 이름으로 부른다"
status: Draft
created: 2026-11-17
updated: 2026-11-17
author: vincent + claude
supersedes: []
superseded_by: null
related: ["librarian-read-waits-and-shrinks-no-further-than-the-refusal-says", "librarian-ends-waiting-requests-of-a-replaced-declaration"]
---

# Exact worker package 는 서버가 싣고 다니고, 선언은 실은 package 를 이름으로 부른다

## 0. 요약

- 2026-11-17 17:02 KST 운영 서버가 #52731 을 담은 판으로 떴다. keeper-librarian 선언은 그 판이 읽지 못하는 답(`capacity_wait`)을 하는 worker 를 가리키고 있었다. 17:11 에 선언을 손으로 바꿀 때까지 9분 동안, 그 답을 받은 원본은 다시 보내지지 않을 수 있었다(§1).
- 원인은 하나다. 서버와 Exact worker package 는 같은 규약으로 말하는데, 운영자가 따로 올린다. 두 판이 어긋난 짝이 돌 수 있다.
- 이 RFC 는 규칙 하나를 세운다. **서버와 Exact worker 가 말하는 규약은 한 곳, 서버 바이너리에서 정해진다.**
- 규칙에서 결정 넷이 나온다.
  - D1. masc 바이너리가 Exact worker package 넷과 공용 `exact_worker.py`·`protocol.py` 를 싣는다. browser Add-on 이 이미 이렇게 한다.
  - D2. 선언은 `package = "keeper-librarian"` 처럼 실은 package 를 이름으로 부를 수 있다. 서버는 이 이름을 자기가 실은 판으로 푼다. `manifest_path` 는 운영자가 판을 고정할 때 쓴다.
  - D3. 설치(`install-local-build.sh`, `install.sh`)가 실은 package 를 판마다 폴더에 쓰고 이미지를 빌드한다.
  - D4. Exact worker manifest 는 규약 판 `[world] exact_protocol` 을 적는다. 서버는 자기 판 하나만 읽고, 다른 판이나 판이 없는 manifest 는 거절한다.
- 결과: 어떤 서버도 다른 규약의 worker 와 짝을 이루지 않는다(§4). 어긋나면 그 설치는 붙지 않고, 요청은 보내지지 않은 채 기다린다.
- 방향은 사용자가 11-17 에 골랐다. 서버를 설치하면 package 도 같이 올라간다.
- 바꾸지 않는 것: worker 기록 형식, 선언 교체 규칙(#52622·#52674·#52695), `max_exact_in_flight`, exact lane 구성, frame 크기.

## 1. 지금

### 1.1 11-17 사건

시각은 KST 다.

| 시각 | 일 | 근거 |
|---|---|---|
| 16:37 | #52728·#52729·#52731 병합. #52731 은 서버가 `capacity_wait` 를 읽는 코드를 지웠다 | `gh pr view` mergedAt 07:37Z |
| 16:40 | 운영 서버 정지, `install-local-build.sh` 시작 | 서버 로그 끝 16:40:10, 설치 프로세스 시작 16:40:13 |
| 17:02 | 새 서버 시작. keeper-librarian 선언은 `0.2.3-oversize-b584e032` | `~/.local/bin/masc` 17:00:53, `masc start` 17:02:04 |
| 17:11 | 선언의 `manifest_path` 를 0.2.6 으로 바꿈. 다음 maintenance 박자에 worker 가 바뀜 | 시스템 로그 08:11Z, 0.2.6 이미지 컨테이너 |

- 0.2.6 전의 worker 는 기다리는 요청이 frame 을 채우면 submit 에 `capacity_wait` 로 답한다. 기록을 쓰기 전에 답한다(병합 전 `addons/exact_worker.py` 417행).
- 새 서버는 `absent`·`pending`·`finished` 말고는 모르는 상태로 읽는다(`lib/lane_addon/lane_addon_submit_once.ml` 36~59행). submit 의 답을 읽지 못하면 원본을 `Dispatch_pending` 에 둔다(259~270행). 다음 pass 에 worker 는 그 요청이 없다고 답하고, 원본은 기다림으로만 남는다(215~217행).
- 선언을 바꿔도 이 원본은 풀리지 않는다. 「`Dispatch_pending` original its worker has no record of」가 그 경우다.
- 17:02~17:11 시스템 로그에는 명시적 기억 접수가 이 상태로 멈췄다는 문장이 없었다. durable 원본은 따로 세지 않았다.
- 병합된 안내서와 #52731 조각은 「서버를 먼저 올린다」고 적었다. 그 순서가 이 창을 연다. #52762 가 순서를 뒤집었다.

### 1.2 지금 구조

- Exact worker package 넷(keeper-librarian, workspace-curator, candle-appraiser, hitl-auto-judge)은 `addons/` 아래에 있다. 운영자가 이미지를 빌드하고, package 를 `<base>/.masc/packages/<id>-<revision>/` 에 복사하고, 선언의 `manifest_path` 를 바꾼다.
- 서버 판과 package 판을 맞추는 일은 운영자 몫이다. 서버를 올리는 일과 package 를 고르는 일은 서로를 모른다.
- 운영 설치는 11-17 17:11 뒤로 keeper-librarian 0.2.6, workspace-curator 0.1.3, candle-appraiser 0.1.2 다. 17:11 전의 keeper-librarian(0.2.3-oversize-b584e032)과 curator·candle 은 `capacity_wait` 를 도입한 #44911(10-22) 뒤의 판이다.
- 서버는 maintenance 박자마다 선언 폴더를 다시 읽는다(`lib/lane_addon/lane_addon_runtime.ml` 4833~4860행). 그래서 서버가 도는 중에 package 나 선언이 바뀌면 그 서버가 바로 새 짝을 만든다.

### 1.3 선례: browser Add-on

- masc 바이너리가 browser Add-on package 를 싣는다(`lib/embedded_browser_addon/dune`). `.toml`·`.json`·`.md` 만 싣는다.
- 설치 스크립트가 `masc browser-lane-setup --mode addon` 을 부른다(`scripts/install-local-build.sh` 493~509행, `scripts/install.sh`). setup 은 실은 package 를 `<base>/.masc/packages/browser-ego/` 에 쓴다. manifest 를 마지막에 쓰고, 이 빌드가 싣지 않은 파일은 지운다(`lib/browser_addon_setup.ml`).
- 선언은 그 폴더를 가리킨다. 이미 있는 선언은 건드리지 않고, 꺼 둔 선언은 꺼 둔 채로 둔다.
- 다른 점이 둘 있다. browser package 는 이미지가 없다. 그리고 폴더 하나를 제자리에서 고쳐 쓴다. Exact worker 는 판마다 `server.py` 가 바뀌므로, 제자리에서 고쳐 쓰면 manifest 가 바뀌기 전에 도는 worker 가 새 `server.py` 를 본다(§5 B).

## 2. 규칙

**서버와 Exact worker 가 말하는 규약은 한 곳, 서버 바이너리에서 정해진다.**

- 규약은 서버가 worker 에게 보내는 것(submit, read, 목록 인자, 결과 전달)과 worker 가 돌려주는 것(상태, 목록 장)이다.
- 서버 빌드 S 가 실은 package 는 S 와 같은 커밋에서 나온다. 그래서 둘의 규약은 정의상 같다.
- 실은 package 가 아닌 것을 쓸 때는 manifest 가 규약 판을 적는다. 서버는 그 판이 자기 판일 때만 붙인다.

## 3. 설계

### 3.1 싣기 (D1)

- `lib/embedded_exact_addons/` 가 `addons/keeper-librarian`, `addons/workspace-curator`, `addons/candle-appraiser`, `addons/hitl-auto-judge` 와 `addons/exact_worker.py`, `addons/protocol.py` 를 싣는다. `embedded_browser_addon` 과 같은 규칙으로, `.toml`·`.json`·`.py`·`Dockerfile` 만 싣는다.
- 실은 package 마다 내용 digest 를 계산한다. 싣는 파일 이름과 바이트를 정렬해 SHA-256 으로 묶는다.

### 3.2 선언이 실은 package 를 부른다 (D2)

선언의 package 출처는 둘 중 하나다.

```ocaml
type package_source =
  | Carried of carried_id         (* package = "keeper-librarian" *)
  | Manifest of string            (* manifest_path = "../../packages/x/lane.toml" *)
```

- 선언에 `package` 와 `manifest_path` 가 둘 다 있거나 둘 다 없으면 거절한다.
- `carried_id` 는 실은 package 이름의 닫힌 합타입이다. 모르는 이름은 거절한다.
- 서버는 `Carried id` 를 자기가 실은 판의 폴더 `<base>/.masc/packages/<id>-<revision>/lane.toml` 로 푼다. 폴더가 없거나 내용 digest 가 다르면 그 선언은 붙지 않고, 이유는 「이 서버가 실은 package 가 설치되지 않았다」다.
- 선언의 의미 revision 은 지금처럼 풀린 package 에서 나온다. 서버를 올려도 실은 package 가 그대로면 revision 이 그대로라 worker 를 바꾸지 않는다.

### 3.3 설치가 package 와 이미지를 놓는다 (D3)

`masc exact-addon-setup --base-path <base>` 를 새로 둔다. `scripts/install-local-build.sh` 는 `browser-lane-setup` 다음에 늘 부른다. 릴리스 설치(`scripts/install.sh`)는 `--declared` 로 부른다. workspace 선언이 `package` 로 부르는 것만 설치하므로, Exact Add-on 을 쓰지 않는 workspace 는 이미지를 만들지 않는다(사용자 11-17 결정).

- 실은 package 마다 `<base>/.masc/packages/<id>-<revision>/` 를 쓴다. 폴더가 이미 있고 digest 가 같으면 아무것도 하지 않는다. digest 가 다르면 쓰지 않고 실패로 알린다. 같은 revision 이름에 다른 내용이 있다는 뜻이기 때문이다.
- 폴더는 한 번 쓰면 바꾸지 않는다. 도는 worker 가 마운트한 폴더가 발밑에서 바뀌지 않는다.
- 이미지 `masc-lane-<id>:<revision>` 을 실은 파일로 빌드한다. 이미지에 실은 digest 를 label 로 붙이고, 같은 label 의 이미지가 있으면 건너뛴다.
  - 이미지는 `Dockerfile` 과 공용 모듈 둘(`exact_worker.py`, `protocol.py`)만 담는다. package 자기 파일은 worker 가 폴더를 `/addon` 으로 마운트해 읽고, 그 바이트는 §3.2 의 폴더 확인이 본다. 그래서 label 값은 이 세 파일의 digest(`Lane_addon_carried.image_digest`)이고, label 이름은 `masc.lane.carried.digest` 다.
- 서버는 `package` 선언의 worker 를 붙일 때 이미지 이름이 가리키는 이미지 ID 를 풀고, 그 ID 의 label 을 읽는다. label 이 자기 digest 와 다르거나 없으면 붙지 않는다. 컨테이너는 그 ID 로 만들므로, 확인한 이미지가 곧 도는 이미지다.
  - 공용 모듈만 바뀌고 package revision 이 그대로면 두 masc 판이 같은 태그를 쓴다. 새 판의 setup 이 태그를 옮겨도, 옛 서버는 label 이 다른 그 이미지에서 worker 를 띄우지 않는다.
  - 요구 label 은 선언이 `Lane_addon_types.container` 에 싣는다. manifest 는 싣지 않는다. 요구 label 은 worker 입력이라 의미 revision 에 들어가고, 없을 때는 키를 적지 않으므로 `manifest_path` 선언의 revision 은 그대로다.
- docker 가 없거나 빌드가 실패하면 그 package 는 실패로 알린다. 서버는 이미지를 찾지 못해 worker 를 띄우지 못하고, 요청은 보내지지 않은 채 기다린다.
- setup 은 선언 파일을 쓰지 않는다. 선언이 `package = "<id>"` 로 바뀌는 일은 한 번, 운영자가 한다(§6).
- 선언이 없으면 만들지 않는다. Exact Add-on 은 운영자가 고르는 설정이고, exact lane 연결도 따로 필요하다.

### 3.4 규약 판 (D4)

- `exact_outputs` 를 선언한 manifest 는 `[world] exact_protocol = <정수>` 를 적는다.
- 서버는 상수 하나 `Lane_addon_types.exact_protocol` 을 갖는다. 규약의 도구 이름(`host_requests_tool`, `host_result_tool`)과 같은 모듈이다. manifest 파서는 이미 이 모듈만 기대므로, Eio 와 provider 를 쓰는 `Lane_addon_exact` 를 끌어오지 않는다. manifest 를 읽을 때 판이 없거나 다르면 거절한다. 거절 문장은 두 판을 모두 적는다.
- 판이 있는데 `exact_outputs` 가 없는 manifest 도 거절한다. 판은 Exact 규약을 말하는 package 만 적는다.
- 판은 서버가 읽는 worker 의 답이나 worker 가 읽는 서버의 인자가 바뀔 때 올린다. 지금까지는 `capacity_wait` 삭제(#52731)와 목록의 장 넘김(#52728, #52778)이 그런 변경이다.
- 실은 package 는 늘 서버와 같은 판이다. 이 검사는 `manifest_path` 로 고정한 package 를 위해 있다.
- 판을 올리면 판이 없거나 다른 고정 package 는 서버를 올린 순간 붙지 않는다. 그 설치의 요청은 기다린다. 11-17 사건이 「원본이 멈춘다」 대신 「그 설치가 붙지 않고 이유가 보인다」로 바뀐다.

### 3.5 기록 판

- worker 는 이미 모르는 기록 판을 거절한다(`addons/exact_worker.py` 238~239행). 기록을 고쳐 쓰지 않는다.
- 지금은 기록마다 읽을 때 거절해서, 목록 전체가 오류로 끝나는 식으로 드러난다. worker 가 시작할 때 저장소를 한 번 훑어, 모르는 판이 있으면 hard cut 안내(`docs/guides/EXACT-WORKER-STATE-HARD-CUT.md`)를 적고 끝나게 한다.
- setup 은 상태 볼륨 안을 보지 않는다. hard cut 이 필요한지는 그 볼륨을 여는 worker 만 안다.

## 4. 왜 닫히나

S(n) 을 n 번째 서버 빌드, C(n) 을 그 빌드가 실은 package 묶음, p(·) 를 규약 판으로 둔다.

- n: 같은 커밋에서 나오므로 p(S(n)) = p(C(n)) 이다.
- `package = id` 선언은 S(n) 아래에서 C(n)[id] 로만 풀린다. S(n) 프로세스는 C(n+1) 을 모르고, S(n+1) 프로세스는 C(n) 을 풀지 않는다. 그래서 n 에서 n+1 로 올리는 동안에도 실은 package 선언은 어긋난 짝을 만들지 않는다. 어느 n 에서나 같다.
- 이미지도 같다. S(n) 은 label 이 C(n) 의 digest 인 이미지에서만 worker 를 띄운다(§3.3). 같은 태그가 C(n+1) 의 이미지로 옮겨 가도 S(n) 은 그 이미지를 쓰지 않는다.
- `manifest_path` 선언은 p(manifest) = p(S) 일 때만 붙는다(D4). 아니면 붙지 않고, 보내지 않으므로 읽지 못할 답도 없다.
- 둘을 합치면 도는 짝 (서버, worker) 은 늘 p 가 같다. 11-17 사건의 부류, 곧 서버가 읽지 못하는 답이 오는 일은 생기지 않는다.
- 남는 것은 멈춤뿐이다. 이미지가 없거나 고정 package 의 판이 다르면 그 설치가 붙지 않는다. 원본은 보내지지 않았으므로 멈춘 원본이 생기지 않는다.
- 서버를 올리며 실은 package 가 바뀌면 선언의 revision 이 바뀐다. 그 뒤는 지금의 선언 교체 규칙(#52622·#52674·#52695)이 맡는다.

## 5. 대안

| 대안 | 버린 이유 |
|---|---|
| A. 설치가 선언의 `manifest_path` 를 새 판 폴더로 고쳐 쓴다 | 도는 옛 서버가 다음 maintenance 박자에 새 선언을 읽는다(§1.2). 옛 서버와 새 worker 짝이 생긴다. 막으려면 D4 가 필요하고, 막히면 서버를 다시 띄울 때까지 그 설치가 꺼진다. 운영자 편집과 설치가 같은 파일을 쓴다(`lane-declaration-editor.md` 의 외부 수정 문단) |
| B. setup 소유 폴더 하나를 제자리에서 고쳐 쓴다(browser 방식) | 파일이 manifest 보다 먼저 바뀐다. 도는 worker 가 옛 manifest 와 새 `server.py` 를 함께 본다. 옛 서버가 새 manifest 를 읽는 창도 A 와 같다 |
| C. 지금처럼 운영자가 순서를 지킨다 | 11-17 사건이다. 안내서가 틀리면 원본이 멈춘다 |
| D. 서버가 옛 답(`capacity_wait` 등)을 계속 읽는다 | 바뀔 때마다 호환 reader 가 쌓인다. hard cut 규칙에 어긋난다 |
| E. 서버가 시작할 때 선언 파일을 고쳐 쓴다 | 서버가 운영자 설정을 쓴다. A 의 편집 충돌이 그대로 남는다 |

## 6. 비용

- 바이너리가 실은 파일만큼 커진다. 네 package 와 공용 파일의 `.toml`·`.json`·`.py`·`Dockerfile` 을 합쳐 72,348 바이트다(11-17).
- 설치가 docker 에 기댄다. 이미지가 바뀐 판만 빌드하지만, docker 가 없으면 그 package 는 서버를 올린 뒤 붙지 않는다.
- 실은 package 가 바뀌는 서버 업그레이드마다 선언 교체가 일어난다. 실행 없이 끝나는 원본의 범위를 다시 읽고, 끊긴 호출은 모델에 한 번 더 묻는다. 지금 손으로 판을 바꿀 때와 같은 값이다. 실은 package 가 그대로인 업그레이드는 값이 없다.
- 운영 설치는 한 번 옮겨야 한다. keeper-librarian 은 `manifest_path` 를 `package = "keeper-librarian"` 으로 바꾼다. workspace-curator 0.1.3, candle-appraiser 0.1.2 는 기록 v1 시절 판이라 hard cut 이 먼저일 수 있다(§9 Q2).
- D4 를 넣는 판은 판이 없는 모든 고정 package 를 거절한다. D1~D3 과 같이 들어가야 운영 설치가 바로 실은 package 로 옮길 수 있다.

## 7. 층

| 층 | 내용 | 닿는 곳 |
|---|---|---|
| L0 | D4. `exact_protocol` manifest 키와 서버 상수, `exact_outputs` 를 적은 여섯 manifest(실은 넷과 operator-quiz, operator-lesson)가 판을 적음 | `lib/lane_addon/lane_addon_manifest.ml`, `lane_addon_types.ml`, 여섯 `lane.toml` |
| L1 | D1·D2. 싣기, `package` 선언 키와 `package_source` 합타입, 실은 package 풀기 | `lib/embedded_exact_addons/`, `lib/lane_addon/lane_addon_config.ml` |
| L2 | D3. `masc exact-addon-setup`, 두 설치 스크립트, 붙일 때 이미지 label 확인 | `bin/main_eio.ml`, `lib/exact_addon_setup.ml`, `scripts/install-local-build.sh`, `scripts/install.sh`, `lib/lane_addon/lane_addon_worker.ml` |
| L3 | §3.5. worker 시작 때 기록 판 훑기 | `addons/exact_worker.py` |
| L4 | 안내서. 선언 예시를 `package = "<id>"` 로, 고정 package 는 판을 맞추라고 | `docs/guides/lane-addon-toml.md`, 네 README |

- L0 과 L1·L2 는 한 번에 설치한다. L0 만 들어가면 운영 Exact 설치가 모두 붙지 않는다.
- L3 은 따로 들어가도 된다.

## 8. 검증

- manifest: `exact_protocol` 이 없거나 다르면 거절, 같으면 받음. 거절 문장에 두 판이 있음.
- 선언: `package` 와 `manifest_path` 가 둘 다 있거나 둘 다 없으면 거절. 모르는 이름은 거절. 실은 폴더가 없거나 digest 가 다르면 붙지 않고 이유가 보임.
- setup: 같은 digest 폴더는 건드리지 않음. 다른 digest 는 쓰지 않고 실패. 이미지 빌드는 가짜 docker 명령으로 인자와 label 을 확인.
- §4 의 성질: 실은 묶음이 다른 두 서버 빌드를 같은 선언 폴더에 차례로 띄운 시험에서, 어느 시점에도 worker 의 판과 서버의 판이 다르지 않음.
- 운영: 설치 뒤 `/health?full=1` 의 `keeper_memory_execution` 에서 실은 revision 으로 `serving`.

## 9. 열린 질문

- Q1. 이미지 이름. 태그(`masc-lane-<id>:<revision>`)와 digest label 로 충분한가, 아니면 manifest 가 이미지 digest 를 가리켜야 하는가. 엔진은 이미 붙일 때 이미지 정체를 기록한다(`Lane_addon_worker.image_identity`).
  - 결정(사용자 11-17): 태그와 label 로 한다. 서버가 붙일 때 label 을 본다(§3.3).
- Q2. 운영 workspace-curator 0.1.3, candle-appraiser 0.1.2 의 상태에 기록 v1 이 남았는가. 남았다면 실은 package 로 옮기기 전에 hard cut 이 필요하다.
- Q3. `install.sh` 로 받은 릴리스 바이너리의 설치에도 docker 가 있다고 볼 수 있는가.
- Q4. browser Add-on 도 `package = "browser-ego"` 로 옮길 것인가. 지금은 고정 폴더를 고쳐 쓴다.
- Q5. `host_request_pages`(#52778)는 Exact 아닌 package(퀴즈의 ask, web_search)도 쓴다. Exact package 에서는 `exact_protocol` 이 장 넘김을 함께 정하게 할 것인가.

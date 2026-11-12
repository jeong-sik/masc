---
rfc: "unbound-dashboard-asset-reads-only-a-changed-file"
title: "manifest 없는 대시보드 asset 은 파일이 바뀌었을 때만 다시 읽는다"
status: Implemented
created: 2026-11-12
updated: 2026-11-12
author: claude
related: ["0518"]
---

# manifest 없는 대시보드 asset 은 파일이 바뀌었을 때만 다시 읽는다

## 0. 요약

서버는 대시보드 번들을 보낼 때마다 866 KB 파일을 통째로 다시 읽고, 메모리에 둔 사본과 한 글자씩 견준다.
파일은 그대로인데 요청마다 866 KB 를 할당하고, 읽고, 견준다.

이 RFC 는 manifest 없는 실행(`MASC_ASSETS_DIR` 나 소스 트리의 asset 을 그대로 쓰는 실행)에서 이것을 바꾼다.

1. 요청마다 파일을 열고 검사하는 일은 지금과 똑같이 한다.
2. 연 파일의 신원(장치, inode, 크기, 수정 시각, 변경 시각)이 표에 둔 것과 같으면 본문을 읽지 않는다.
3. 신원이 다르면 지금처럼 읽고, 표 항목을 바꾼다.
4. 표에서 본문 비교(`String.equal`)가 없어진다.

구현은 #51545 다. 정한 것 셋은 §8 에 있다.

launch manifest 로 묶인 실행과 설치 release 는 바꾸지 않는다. 그쪽은 읽을 때마다 SHA-256 을 확인한다는 계약이 있다.

## 1. 배경

### 1.1 잰 것

이슈 #51400: 평문 HTTP/1.1 연결 하나로 번들을 받을 때 서버 CPU 가 RFC-0518 스택 전보다 39~42% 높다(run13, `--n 300` 두 쌍, 1.92·1.77 → 2.73·2.46 ms/MB).

같은 장면을 `sample` 로 세 쌍 찍은 값이다(ms/MB, 스택 전 → 뒤).

| 몫 | 스택 전 | 스택 뒤 | 이 RFC 뒤 |
|---|---|---|---|
| `caml_string_equal`(표의 본문 비교) | 0 | 0.09~0.12 | 없어진다 |
| `read` | 0.08~0.12 | 0.09~0.16 | asset 읽기 몫이 없어진다 |
| GC | 0.47~0.76 | 0.91~1.02 | 줄어드는지 잰다(§1.3) |
| `writev` | 0.20~0.37 | 0.52~0.63 | 그대로다(§6) |
| `openat` + `getattrlist` | 0.37~0.48 | 0.42~0.51 | 그대로다(경로 검사는 남는다) |

### 1.2 #51488 이 이 장면을 고치지 못한 이유

#51488 은 표의 비교를 "읽을 때 이미 검증한 SHA-256" 비교로 바꿨다.
그런데 탐침 서버는 `MASC_ASSETS_DIR` 로 뜨고, 이 경로에는 manifest 가 없어서 SHA-256 도 없다.
#51488 은 이 경우를 본문 비교로 남겼다. 그래서 #51488 이 든 build `5cde6a85adec` 의 프로파일에도 `caml_string_equal` 이 그대로 있다(샘플 88, 43).

### 1.3 GC 몫에 대한 가설

요청마다 읽는 866 KB 문자열은 major heap 에 바로 할당된다(108,298 words).
#51282 뒤로 이 할당은 메인 도메인이 아니라 `Systhread_host` 도메인에서 일어난다.
OCaml 5.5.2 는 GC 일감을 도메인마다 따로 계산해 전역 카운터에 더한다(`runtime/major_gc.c` 982~983행).
그래서 같은 할당량이어도 일감이 더해질 수 있다. 순증은 요청당 0 ~ 약 487,000 work 사이이고 재지 않았다(#51400 의 소스 읽기 댓글).

이 RFC 는 그 할당을 없앤다. 가설이 맞으면 GC 몫이 같이 내려가고, 틀리면 그대로다. 어느 쪽인지는 §5 의 측정이 가른다.

## 2. 결정

### D1. 범위는 manifest 없는 경로 하나다

`Web_dashboard.load_dashboard_asset` 는 세 경로로 읽는다.

| 경로 | 지금 요청마다 하는 일 | 이 RFC |
|---|---|---|
| manifest 없음(`Dashboard_assets_unbound`) | 경로 검사, 읽기, 표에서 본문 비교 | 바꾼다 |
| launch manifest 로 묶임 | root 확인, 읽기, SHA-256, 표에서 digest 비교 | 그대로 |
| 설치 release | receipt 읽기+SHA-256 두 번, asset 읽기+SHA-256, 표에서 digest 비교 | 그대로 |

아래 두 경로는 "읽을 때마다 검증한다"가 `.mli` 에 적힌 계약이다(`installed_dashboard.mli`, `web_dashboard.mli`).
그 계약을 바꾸는 일은 이 RFC 에 넣지 않는다. 두 경로의 CPU 는 잰 적이 없다(§6).

### D2. 요청마다 하는 검사는 그대로 하고, 본문 읽기만 건너뛴다

`Fs_compat.load_single_link_regular_file_beneath` 가 지금 하는 일은 이렇다.

1. root 디렉터리의 신원을 확인한다.
2. 경로의 디렉터리를 하나씩 no-follow 로 연다. 제외 디렉터리(`published-artifacts`)와 같은 신원이면 거절한다.
3. 파일을 열고 `fstat` 한다. regular file 이 아니거나 hard link 가 둘 이상이면 거절한다.
4. 크기만큼 읽는다.
5. 조상과 파일의 신원을 다시 확인하고, 파일의 `fstat` 이 3번과 같은지 본다(`same_file_snapshot`).

바꾸는 것은 4번뿐이다. 호출자가 "가진 신원"을 주고, 3번의 `fstat` 이 그것과 같으면 4번을 건너뛴다.
1·2·3·5번은 매 요청 그대로 한다. symlink 로 바꿔치기, hard link 추가, 제외 디렉터리로 들어가는 경로는 지금처럼 거절된다.

### D3. 신원은 `owned_regular_file_snapshot` 전체다

`Fs_compat.owned_regular_file_snapshot` 은 장치, inode, 소유자, 권한, 크기, 수정 시각(mtime), 변경 시각(ctime)이다.
견주는 함수는 이미 있는 `equal_owned_regular_file_snapshot` 이다. 새 비교 규칙을 만들지 않는다.

- 파일을 새 파일로 바꾸면(rename) inode 가 바뀐다.
- 제자리에서 고치면 mtime 과 ctime 이 바뀐다. ctime 은 사용자가 되돌릴 수 없다.
- 길이가 달라지면 크기가 바뀐다.

이 신원은 5번 검사가 이미 믿는 것이다. 지금 코드도 "읽는 동안 파일이 그대로였다"를 같은 필드로 판정한다.

### D4. load 와 reload 두 함수로 나누고, 결과는 합타입으로 준다

`load_single_link_regular_file_beneath` 의 호출처는 둘이다(`lib/web_dashboard.ml` 하나, 시험 하나). 이 함수가 본문과 함께 snapshot 을 주게 바꾸고, reload 를 하나 더한다.

```ocaml
val load_single_link_regular_file_beneath
  : root:string -> ?excluded_directory:owned_relative_path -> owned_relative_path
  -> (owned_regular_file_contents option, owned_regular_file_read_error) result

type owned_regular_file_reread =
  | Same_file  (** The file has the snapshot the caller holds. Nothing was read. *)
  | Read of owned_regular_file_contents

val reload_single_link_regular_file_beneath
  : root:string -> ?excluded_directory:owned_relative_path
  -> held:owned_regular_file_snapshot -> owned_relative_path
  -> (owned_regular_file_reread option, owned_regular_file_read_error) result
```

- 함수 하나가 `held:option` 을 받게 하지 않는다. 그러면 `held:None` 인데 `Same_file` 을 받는 갈래가 타입에 생기고, 표가 없는 호출자(`index.html` 을 읽는 곳들)가 일어날 수 없는 갈래를 다뤄야 한다.
- 두 함수는 검사 코드 하나를 같이 쓴다. 다른 것은 연 파일에서 무엇을 가져오는가뿐이다.
- snapshot 은 3번의 `fstat` 이다. 5번이 통과한 뒤에만 돌려준다.

`Web_dashboard` 도 같은 모양으로 바꾼다. #51488 의 `manifest_sha256 : string option` 은 "None 이면 본문을 견준다"는 뜻을 타입 밖에 두었다. 이것을 없앤다.

```ocaml
(* web_dashboard.mli *)
type asset_version =
  | Manifest_sha256 of string
  | File_snapshot of Fs_compat.owned_regular_file_snapshot

type loaded_asset = { body : string; version : asset_version }

val load_dashboard_asset : string -> (loaded_asset, asset_load_error) result

type reloaded_asset =
  | Unchanged  (** The file has the version the caller holds. *)
  | Reloaded of loaded_asset

val reload_dashboard_asset
  : held:asset_version -> string -> (reloaded_asset, asset_load_error) result
```

- manifest 가 있는 두 경로는 `held` 를 보지 않고 언제나 읽고 검증한 뒤 `Reloaded { version = Manifest_sha256 _ }` 를 준다.
- 표 항목은 `version : asset_version` 을 가진다. 표의 비교는 `asset_version` 끼리의 비교 하나다. `String.equal` 로 본문을 견주는 줄은 없어진다.

### D5. 표를 쓰는 순서

`serve_dashboard_static` 은 이렇게 한다.

1. lock 을 잡고 표에서 이름의 항목을 꺼낸다. 항목을 값으로 쥔다.
2. lock 밖에서 `reload_dashboard_asset ~held:(항목의 version)` 을 부른다. 항목이 없으면 `load_dashboard_asset` 을 부른다.
3. `Unchanged` 면 1번에서 쥔 항목의 본문을 보낸다.
4. `Reloaded` 면 지금처럼 표 항목을 바꾸고 그 본문을 보낸다. 표에 자리가 없으면 지금처럼 요청의 본문으로 보낸다.

2번을 하는 동안 다른 요청이 표 항목을 바꿔도 된다. 3번이 보내는 본문은 1번에서 쥔 항목의 것이고, 그 항목의 version 이 방금 파일에서 확인한 것이다.

표에 항목이 없는 이름(자리가 없어 못 넣은 asset)은 매번 읽는다. 지금과 같다.

### D6. 읽기는 지금 도는 곳에서 돈다

검사(1·2·3·5번)는 지금처럼 `Systhread_host` 도메인에서 돈다. 요청마다 도메인 왕복은 남는다.
없어지는 것은 그 도메인이 요청마다 하던 866 KB 할당과 `read` 다.

## 3. 왜 이 모양인가

### 3.1 digest 를 계산해서 견주지 않는다

manifest 없는 경로에 SHA-256 을 더하면 표 비교는 64자가 되지만, 읽기와 할당은 남고 해시 CPU 가 새로 든다(얼마인지는 재지 않았다). 없애려는 읽기와 할당을 그대로 둔다.

### 3.2 검사를 건너뛰지 않는다

`lstat` 한 번으로 줄이면 더 싸다. 그러나 2번(no-follow 열기, 제외 디렉터리)은 보고서 스냅숏이 asset 으로 새지 않게 막는 검사다(`test_report_snapshots_are_not_public_assets`). 이 검사는 요청마다 해야 뜻이 있다.

### 3.3 일정 시간 동안 믿지 않는다

"N초 동안은 다시 안 본다"는 상수를 고르는 설계다. 고른 값에 근거가 없고, 그 시간 동안은 바뀐 파일을 못 본다. 파일 신원은 커널이 쓰기마다 바꾸는 사실이라 상수가 필요 없다.

## 4. 알려진 한계

**같은 크기로 제자리에서 고친 쓰기가 파일 시각을 바꾸지 않으면 못 잡는다.**

- 그때 서버는 예전 본문을 계속 보낸다. 파일이 다시 바뀌거나 서버가 다시 뜨면 풀린다.
- 보내는 본문은 언젠가 그 파일의 내용이었던 것이다. 이 경로에는 manifest 가 없어서, 지금도 "파일에 있는 것을 보낸다" 말고 다른 보증은 없다.
- 잰 것(11-12): 4,096 B 파일을 같은 크기로 제자리에서 20,000번 고쳐 쓰고 매번 `fstat` 했다. 시각이 안 바뀐 쓰기는 macOS 27.2(APFS) 0건, Linux 7.0.14(overlayfs) 0건이다. OCaml 의 `Unix.stats` 처럼 시각을 float 로 읽어도 0건이다. 가장 작은 ctime 간격은 각각 3,458 ns, 2,083 ns 였다.
- 재지 않은 것: 시각 눈금이 굵은 파일 시스템(FAT 2초, 옛 Linux 커널의 jiffy 단위)에서는 눈금 한 칸 안의 두 번째 쓰기가 안 보일 수 있다. 확인 필요.
- 같은 한계가 이미 있다. 5번 검사는 "읽는 동안 안 바뀌었다"를 같은 필드로 판정한다. `File_version_cache` 도 같은 한계를 `.mli` 에 적고 쓴다. 이 RFC 는 그 창을 "읽는 동안"에서 "요청과 요청 사이"로 넓힌다.

번들은 이름에 해시가 들어간다(`index-<hash>.js`). 다시 빌드하면 다른 이름의 새 파일이 된다. `index.html` 은 이름이 그대로이고, 빌드가 이 파일을 새 inode 로 쓰는지는 확인하지 않았다.

## 5. 확인 방법

기준은 구현 전에 정한다. 구현한 뒤에 기준을 바꾸지 않는다.

**시험(파일 시스템 경계, `Fs_compat` 과 HTTP 응답)**

- 같은 파일을 `held` 로 다시 물으면 `Same_file` 이 온다.
- 파일을 다른 내용의 새 파일로 바꾸면(rename) `Read` 가 새 내용으로 온다.
- 제자리에서 길이를 바꿔 쓰면 `Read` 가 온다.
- `held` 를 줘도 hard link 가 둘이면 거절한다. 제외 디렉터리 아래 경로도 거절한다.
- HTTP/1.1 과 HTTP/2: asset 을 한 번 받은 뒤 파일을 바꾸면 다음 응답이 새 내용이다.
- 같은 크기 제자리 쓰기는 시험하지 않는다. 결과가 파일 시스템의 시각 눈금에 달려 있어서 시험이 장비마다 달라진다.

**측정(설치한 build, 같은 장비, build 를 번갈아 5쌍 이상)**

| 값 | 기준 |
|---|---|
| `sample` 의 `caml_string_equal` 샘플, `read_exact_file_descriptor` 아래 샘플 | 0 |
| 평문 연결 하나의 서버 CPU(`tls_cpu_probe.py --n 300`) | 스택 전 build `379d483de91a` 와 같은 쌍에서 견준다. 높으면 남은 차이를 `writev` 와 GC 로 나눠 적는다 |
| 도메인별 GC 일감(`Runtime_events` 의 `EV_C_MAJOR_ALLOCATED_WORK`, `EV_C_MAJOR_EXTRA_WORK`) ÷ 보낸 MB | 전·후를 적는다. §1.3 가설의 판정이다 |
| 평문 연결 넷, TLS 연결 하나·넷의 서버 CPU | run13 보다 높지 않다 |

탐침은 #51515 의 판을 쓴다. 측정할 때 장비의 load average 를 같이 적는다. 11-12 낮에는 170 을 넘어서 ms/MB 를 견줄 수 없었다.

## 6. 하지 않는 것

1. **launch manifest·설치 release 경로의 다시 읽기.** 계약이 걸려 있고 CPU 를 잰 적이 없다. 먼저 잰다. 설치 release 는 요청마다 receipt 를 두 번 읽고 해시한다.
2. **평문 HTTP/1.1 의 쓰기 조각.** 응답 하나를 256 KiB 조각 넷 이상으로 쓴다(`writev` +0.26 ms/MB). 격리 벤치는 그중 0.04~0.05 만 설명했다. 이 RFC 뒤에 남는 차이를 보고 따로 다룬다.
3. **httpun 의 응답 버퍼 복사.** HTTP/1.1 응답마다 본문을 새 bigstring 으로 복사한다. 스택 전에도 있던 일이다.
4. **`Systhread_host` 왕복 자체.** #51282 의 결정이다.

## 7. 층

| 층 | 내용 | 파일 |
|---|---|---|
| L1 | `Fs_compat` 의 load·reload, `Web_dashboard` 의 `asset_version` 과 reload, 표 항목의 `version`, `serve_dashboard_static` 의 순서, 시험. PR #51545 | `lib/fs_compat/fs_compat_owned_reader.ml/.mli`, `lib/fs_compat/fs_compat.mli`, `lib/web_dashboard.ml/.mli`, `lib/server/server_routes_http_pages.ml`, `test/test_http_pages_asset_read.ml` |
| L2 | 설치 뒤 측정 결과. PR #51602 | `docs/evidence/research/2026-11-09-h2-sse-tls/` |

`Fs_compat` 의 reload 는 표가 부르기 전에는 쓰는 곳이 없다. 그래서 일곱 파일을 한 PR 로 낸다.

## 8. 정한 것 (2026-11-12, 사용자)

| # | 물은 것 | 정한 것 | 근거 | 대가 |
|---|---|---|---|---|
| 1 | §4 의 한계를 받아들이는가 | 받아들인다 | 두 장비에서 20,000번 중 0건이다. 같은 필드를 5번 검사와 `File_version_cache` 가 이미 믿는다. 이 경로에는 내용 보증 계약이 없다 | 시각 눈금이 굵은 파일 시스템에서 개발자가 같은 크기로 제자리 수정하면 예전 asset 이 보일 수 있다 |
| 2 | 범위를 manifest 없는 경로로 한정하는가 | 한정한다 | 잰 장면이 이 경로다. 나머지 두 경로는 계약이 있고 잰 값이 없다 | 설치 release 의 요청당 읽기·해시는 남는다 |
| 3 | #51488 의 `manifest_sha256 : string option` 을 `asset_version` 합타입으로 바꾸는가 | 바꾼다 | "None 이면 본문 비교"가 타입 밖에 있다. 바꾸면 본문 비교 갈래가 사라진다 | #51488 이 바꾼 세 파일을 다시 고친다 |

## 9. 구현과 결과 (Implementation summary, 2026-11-12)

L1 은 #51545 로, L2 는 #51602 로 main 에 들어갔다.

이 RFC 가 없애려던 일(요청마다 본문 읽기, 본문 비교)은 프로파일에서 보이지 않는다. 이 RFC 를 쓴 이유였던 CPU 차이(#51400)는 #51545 가 든 build 에서도 남아 있다. 이 RFC 가 그 차이를 얼마나 줄였는지는 가리지 못했다.

§5 의 기준을 #51545 가 든 설치 build 로 확인했다. 원값은 `docs/evidence/research/2026-11-09-h2-sse-tls/` 의 run14 에 있다.

**측정**

| 값 | 기준 | 결과 |
|---|---|---|
| `sample` 의 `caml_string_equal` 샘플, `read_exact_file_descriptor` 아래 샘플 | 0 | 세 프로파일 모두 0 이다. 고치기 전에는 94·114·83, 15·17·16 이었다 |
| 평문 연결 하나의 서버 CPU | 스택 전 build 와 같은 쌍에서 견준다. 높으면 남은 차이를 `writev` 와 GC 로 나눠 적는다 | 다섯 쌍 모두 높다(중앙값 2.38 → 3.25 ms/MB, +36.6%). 남은 차이를 `writev` 와 GC 로 나누지 못했다. #51545 가 줄인 몫도 가리지 못했다 |
| 도메인별 GC 일감 ÷ 보낸 MB | 전·후를 적는다 | 재지 않았다 |
| 평문 연결 넷, TLS 연결 하나·넷의 서버 CPU | run13 보다 높지 않다 | 판정하지 못했다. load average 가 101~393 이라 run13(64~142)의 값과 견줄 수 없다. 같은 회차 안에서 TLS 여섯 줄은 다섯 쌍 모두 스택 전보다 낮고(23.3~44.2%), 평문 연결 넷은 다섯 쌍 중 넷에서 높다 |

- 프로파일에서 본문 비교와 asset 읽기는 보이지 않는다. 이 다섯 쌍에서 평문 연결 하나의 차이는 남아 있다. 그 둘이 차이에서 차지하던 몫은 이 측정으로 알 수 없다.
- §1.3 의 가설은 판정하지 못했다. §5 에서 판정 기준으로 정한 GC 일감을 재지 않았다. 866 KB 할당이 없는 build 에서 차이가 남아 있다는 것만으로는 가설을 받아들이지도 버리지도 못한다. 다른 변경이 늘린 몫이 줄어든 몫을 가렸을 수 있다.
- 남은 차이를 `writev` 와 GC 로 나누지 못한 이유는 부하다. `sample` 은 CPU 를 받지 못하고 밀려난 스레드도 센다. load average 110~150 에서 같은 실행 파일의 추정이 1.92, 8.02, 11.61 ms/MB 로 흩어졌다.
- 스택 전 build 와 설치 build 사이에는 RFC-0518 스택 말고도 하루 동안 main 에 들어간 다른 변경이 있다. 이 비교로는 차이가 어느 변경 것인지 가리지 못한다. 가리려면 같은 커밋에서 한 곳만 바꾼 실행 파일끼리 견줘야 한다(#51400).

**시험**

- `Fs_compat` 의 시험 넷은 떼어 낸 모듈로 만든 별도 빌드에서 통과했다. 실행 출력은 남기지 않았다.
- HTTP/1.1·HTTP/2 응답 시험(`test_dashboard_static_serves_a_replaced_asset`)은 type-check 만 통과했다. 실행한 기록이 없다.
- 프로파일 원문은 호스트 경로가 들어 있어 남기지 않았다. 위 표의 샘플 수는 다시 계산할 수 없다.

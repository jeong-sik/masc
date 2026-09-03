---
rfc: "0405"
status: Draft
---

# RFC-0405 — microVM 백엔드를 하나 더 고를 수 있게 한다

- Status: Draft
- Decision driver: `Micro_vm` 프로필이 Apple `container` 하나에 묶여 있어 **macOS
  26+ 에서만** 돈다. 리눅스에서 keeper 를 격리하려면 Docker(커널 공유) 아니면
  `Remote_ssh`(다른 기계) 뿐이고, 하이퍼바이저 경계를 로컬에서 얻을 길이 없다.
  2026 년에 같은 자리를 노리는 런타임이 여럿 나왔고, 그중 둘은 CLI 문법이 지금
  코드가 부르는 모양과 겹친다.
- Area: `lib/keeper/keeper_sandbox_microvm.ml`(+`.mli`),
  `lib/keeper/keeper_turn_sandbox_runtime.ml`,
  `lib/keeper/keeper_sandbox_control.ml`, `config/keepers/*.toml`
- Related: RFC-0400(게스트가 자기 트리를 소유), #31340(턴을 넘겨 게스트 채택)

## 지금 무엇이 묶여 있나

CLI 이름은 리터럴 하나다.

```ocaml
(* keeper_sandbox_microvm.ml:22 *)
let command_argv () = [ "container" ]
```

`"container"` 문자열은 3파일에만 있고, 소비자
(`keeper_turn_sandbox_runtime`, `keeper_sandbox_read_backend`, `keeper_sandbox_control`)
는 CLI 를 모른다. 의도 단위 argv 빌더만 부른다 — `inspect_argv`, `stop_argv`,
`delete_force_argv`, `keeper_work_root_mkdir_argv` 등 `.mli` 에 38개.

즉 **경계는 이미 그어져 있다.** 이 RFC 는 경계를 새로 긋는 게 아니라, 그 뒤에
구현을 하나 더 놓는다.

## 왜 프로필 변형을 늘리지 않는가

`sandbox_profile` 은 `Docker | Micro_vm | Remote_ssh` 이고, 45개 파일이 이걸
전수 매치한다. 변형을 더하면 컴파일러가 45곳 전부에 답을 강요한다 — 안전하지만
그 45곳이 답할 질문은 백엔드가 아니라 **트리가 어디 있나**(`Endpoint_owned`),
**기본 network_mode**, **읽기/쓰기 dispatch** 다. 세 답이 백엔드 셋 모두 같다.

그래서 `Micro_vm` 은 하나로 두고, 백엔드는 그 아래 값으로 고른다. 프로필은
격리 등급을 말하고, 백엔드는 그걸 누가 제공하는지를 말한다.

## 후보 (2026-09-03 확인)

| | 하이퍼바이저 | CLI | 플랫폼 | 성숙도 |
|---|---|---|---|---|
| Apple `container` (현재) | Virtualization.framework | `run` `exec` `stop` `delete` `inspect` `volume *` `image *` | macOS 26+ 전용 | v1.0 (2026-06) |
| microsandbox | libkrun | `run` `exec` `stop` `rm` `inspect` `ls` `image ls/rm` `pull` | macOS(AS) · Linux(KVM) · Windows(WHP) | **beta — breaking changes 명시** |
| gondolin | QEMU (krun 선택) | `exec` `bash` `list` `attach` — **detached 부팅 없음** | macOS · Linux, arm64 위주 | experimental · **이 모양에서 탈락** |

microsandbox 가 문법상 가장 가깝다. gondolin 은 QEMU 라 **KVM 이 필요 없다** —
중첩 가상화가 막힌 CI 나 클라우드 VM 에서도 도는 유일한 후보다.

## 설계

### D1. 백엔드는 값이고, 프로필은 그대로다

keeper TOML 에 한 줄:

```toml
sandbox_profile = "microvm"
microvm_backend = "apple_container"   # | "microsandbox" | "gondolin"
```

생략하면 플랫폼 기본값. macOS 는 `apple_container`, 리눅스는 미선언이면
`Micro_vm` 을 거절한다(지금과 같은 fail-closed). 조용한 대체는 없다.

### D2. `Keeper_sandbox_microvm` 이 디스패처가 된다

지금 `.mli` 38개를 두 묶음으로 가른다.

**백엔드가 답해야 하는 것** — CLI 문법과 그 출력에 걸린 것:

```
command_argv          turn_start_argv       exec_argv
stop_argv             delete_force_argv     inspect_argv
volume_create_argv    work_volume_mount_args
running_of_inspect_json   volume_names_of_json
live_containers_of_json   sweep_candidates_of_json
image_present / classify_image_probe / image_probe
network_args          unsupported_docker_flags
```

**백엔드와 무관한 masc 모델 상수** — 그대로 공유:

```
work_volume_guest_root   work_volume_name   keeper_work_root
shim_guest_dir / shim_binary_name / shim_config_name
shim_guest_path / shim_config_guest_path / shim_mount_args
shim_config_content      remote_env_allowlist
remote_connect_timeout_sec   remote_max_concurrent_sessions
keeper_vm_container_kind
```

두 번째 묶음이 그대로 남는 것이 중요하다. RFC-0400 의 게스트 소유 트리 모델
(work volume + shim 마운트 + 신원 스냅샷)은 하이퍼바이저가 바뀌어도 같다.

### D3. 파서는 백엔드마다 다르다

`running_of_inspect_json` 은 Apple 의 중첩을 그대로 읽는다.

```ocaml
`List (`Assoc fields :: _) -> "status" -> "state" = "running"
```

microsandbox `msb inspect` 도 gondolin `list` 도 이 모양이 아니다. 파서는
백엔드가 소유하고, **관용적으로 넘기지 않는다** — 모르는 모양은 `Error` 다.
`Ok false`(안 떠 있음)로 접으면 살아 있는 게스트를 죽은 것으로 읽는다.

### D4. 없는 백엔드는 거절이지 대체가 아니다

선언한 백엔드의 CLI 가 PATH 에 없으면 keeper 를 띄우지 않는다. Docker 로
내려가지 않는다. 지금 `docker_preflight` 가 하는 것과 같은 fail-closed 이고,
에러가 어느 CLI 를 어디서 찾았는지 말한다.

## 실측 (2026-09-03, 이 맥에서 직접 돌림)

RFC 초안은 다섯 개를 미확인으로 뒀고, 그중 둘이 타당성을 정한다고 적었다. 다 쟀다.
**gondolin 이 탈락할 수 있다는 초안의 우려는 틀렸다.**

### microsandbox (`msb` 0.6.16, brew)

| 질문 | 결과 |
|---|---|
| 비대화형 exec | `msb exec <name> -- CMD` — 됨 |
| stdin 파이프 | 됨 (`printf ... \| msb exec ... -- cat` 이 그대로 돌아옴) |
| stdout/stderr 분리 | 됨 |
| 종료코드 전달 | 됨 (`exit 42` → 42) |
| 이름으로 채택 | `create --name` 후 호출을 넘겨 `exec`/`stop`/`start` |
| 마운트 | `--mount-dir HOST:GUEST` — 됨 |
| inspect JSON | `--format json` → `{ "name": ..., "status": "Running" }` |
| rootless | macOS 에서 sudo 없이 붙음. **Linux KVM 은 미확인** |

wire 3요소(stdin·스트림 분리·종료코드)가 다 되는 것이 결정적이다. masc 의 shim
계약(프레임을 stdin 으로, 본문을 stdout 으로, trailer 를 stderr 로)이 그대로
얹힌다.

**함정 하나:** 마운트 경로는 심볼릭을 미리 풀어야 한다. macOS 에서 `/tmp/...` 를
그대로 주면 `mount: Not a directory (os error 20)` 로 죽고, `/private/tmp/...` 로
주면 붙는다.

### gondolin (`npx @earendil-works/gondolin`)

```
exec   Run a command via the virtio socket or in-process VM
list   List active VM sessions registered in the local cache
```

```
gondolin exec --sock PATH -- CMD [ARGS...]
```

`attach` 는 대화형이지만 **`exec` 가 따로 있다.** 실행 중 VM 을 유닉스 소켓
경로로 지목해 비대화형으로 명령을 보낸다. 마운트는 `--mount-hostfs HOST:GUEST[:ro]`,
하이퍼바이저는 `--vmm qemu|krun`.

Apple/microsandbox 와 다른 점은 **주소가 이름이 아니라 소켓 경로**라는 것뿐이다.
masc 가 안정적 컨테이너 이름을 유도하듯 안정적 소켓 경로를 유도하면 된다.

### gondolin 은 이 모양으로 못 붙는다 (2026-09-03 실측)

초안은 `attach` 가 대화형이라 탈락할 수 있다고 적었고, 그건 틀렸다 — `exec` 가
따로 있다. 탈락은 다른 자리에서 났다: **게스트를 띄울 방법이 없다.**

CLI 전체가 `exec` · `bash` · `list` · `attach` · `snapshot` · `build` ·
`image` 다. `create` 도 `start` 도 `up` 도 없다.

- `exec --sock PATH` 는 **이미 떠 있는** VM 을 지목한다. 만들지 않는다
- `exec` 를 `--sock` 없이 쓰면 in-process VM 이고 그 호출과 함께 죽는다
- `bash` 가 유일한 세션 생성자인데 대화형이다

비대화형으로 돌려봤다:

```
$ gondolin bash < /dev/null
(120초 매달림, timeout 으로 종료)
$ gondolin list
No running sessions.
```

매달리고, 세션도 안 남는다.

masc 는 TTY 없는 서버 프로세스에서 게스트를 띄우고, 턴과 서버 재기동을 넘겨 같은
게스트에 exec 한다(#31340). gondolin 의 지속 모델은 그게 아니라 **사람이 붙어
있는 대화형 세션**이다.

TS SDK 의 `VM.create` / `vm.exec` / `vm.close` 는 프로세스에 묶인다. 그걸 쓰려면
VM 을 들고 있는 node 사이드카가 필요하고, 그건 argv 빌더 뒤에 구현을 하나 더
놓는 이 RFC 의 모양이 아니다 — Firecracker 를 범위 밖으로 둔 것과 같은 이유다.

**그래서 gondolin 은 이 RFC 에서 뺀다.** QEMU 라 KVM 이 필요 없다는 장점은
그대로지만, 그 장점을 쓰려면 다른 통합 모양이 필요하고 그건 별도 RFC 다.

### inspect 모양이 백엔드마다 다르다는 것은 확인됐다

```
Apple          [ { "status": { "state": "running" } } ]     리스트·중첩·소문자
microsandbox   { "status": "Running", "name": ... }         객체·평면·대문자
```

D3(파서는 백엔드가 소유하고 모르는 모양은 `Error`)이 그대로 필요하다.

### 남은 미확인

- Linux 에서 microsandbox 가 KVM 접근에 권한을 요구하는지 (이 맥에서는 못 잰다)
- gondolin `list` 의 출력 모양 — 소켓 경로를 어떻게 돌려주는지

둘 다 해당 백엔드를 구현할 때 그 자리에서 재면 된다. 설계를 바꾸지 않는다.

## 검증

| 확인할 것 | 방법 |
|---|---|
| 백엔드 선택이 TOML 에서 읽힌다 | 세 값 각각으로 keeper meta 를 만들고 선택된 backend 가 argv 를 낸다 |
| 미선언 리눅스는 거절 | `microvm_backend` 없이 Linux 에서 `Micro_vm` → 부팅 거절, 이유에 플랫폼 명시 |
| CLI 부재는 거절이지 대체가 아니다 | PATH 에서 CLI 를 뺀 뒤 부팅 → Docker 로 안 내려감 |
| 파서가 모르는 모양을 삼키지 않는다 | 낯선 inspect JSON → `Error`, `Ok false` 아님 |
| 공유 상수가 안 갈라진다 | 세 백엔드가 같은 `work_volume_guest_root` · shim 경로를 쓴다 |
| 라이브 | 각 백엔드로 keeper 하나를 띄워 턴 하나를 완주 |

## 범위 밖

- **Firecracker.** CLI 가 아니라 API 소켓이라 argv 빌더 모델에 안 맞는다.
  붙이려면 (B) 가 아니라 새 dispatch 층이다.
- **Windows.** microsandbox 가 WHP 를 지원하지만 masc 는 Windows 를 타깃한 적이
  없다.
- **백엔드별 성능 비교.** 벤치마크 없이 "더 빠르다" 를 적지 않는다. 현재 Apple
  `container` 의 실측치(부팅 1.3-2.4s, 호출당 0.06-0.10s, 게스트당 ~460MB)는
  `keeper_types_profile_sandbox.ml` 에 있고, 새 백엔드는 자기 수치를 스스로
  가져와야 한다.

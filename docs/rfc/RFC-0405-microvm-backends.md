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
| gondolin | QEMU (krun 선택) | `list` `attach` `snapshot` `bash` + TS SDK | macOS · Linux, arm64 위주 | **experimental** |

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

## 미확인 — 착수 전에 재야 할 것

문서로 읽은 것과 돌려본 것은 다르다. 아래는 **아직 안 쟀다.**

1. **비대화형 exec.** masc 는 shim 에 프레임을 stdin 으로 밀고 stdout/stderr 를
   받는다. `msb exec` 가 이걸 하는지, gondolin 의 `attach` 가 대화형 전용인지.
   **gondolin 은 여기서 탈락할 수 있다.**
2. **volume 모델.** work volume 을 keeper 수명으로 두고 게스트에 마운트하는
   모양이 두 백엔드에 있는지. 없으면 트리 소유 모델을 다시 그려야 한다.
3. **게스트 수명.** 이름으로 채택(adopt)이 되는지. masc 는 턴과 서버 재기동을
   넘겨 같은 게스트를 다시 쓴다(#31340).
4. **rootless.** microsandbox 의 Linux KVM 접근에 권한이 필요한지 문서에 없다.
5. **inspect/list JSON 모양.** D3 의 파서를 쓰려면 실물이 필요하다.

1번과 3번이 핵심이다. 둘 중 하나라도 아니면 그 백엔드는 (B) 방식으로 못 붙고,
새 dispatch 층이 필요하다 — 그건 이 RFC 의 범위가 아니다.

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

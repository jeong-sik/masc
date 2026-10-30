---
status: runbook
---

# Keeper 운영 매뉴얼

[English](KEEPER-USER-MANUAL.md)

Keeper 는 MASC 가 띄우고 지켜보고 기록하는 상주 에이전트입니다. 공유 작업 공간에서
할 일을 집어 들고, 모델 런타임에 턴을 돌리고, 샌드박스 안에서 파일을 고치고 명령을
실행한 뒤, 무엇을 했는지 보드에 올립니다.

꼭 필요한 건 아닙니다. Keeper 없이 MCP 협업 서버로만 써도 되고, quickstart 기본값이
그쪽입니다. 내가 타이핑하지 않는 동안에도 일이 이어지길 바랄 때 하나 만드세요.

타입이 잡힌 에이전트 엔진은 `packages/agent_core` 를 `masc.agent_core` 내부
라이브러리로 빌드한 것입니다. 따로 배포되는 SDK 버전이나 opam pin 이 없고, MASC 의
커밋과 빌드 식별자가 기준입니다.

### 모델을 바꿀 때의 체크포인트

Keeper를 재개해도 원래 대화, 추론 출처, 완료된 도구 결과는 보존합니다. 모델을
바꿨다는 이유로 체크포인트를 지우거나 과거 도구 호출을 다시 실행하지 않습니다.
MASC는 출처가 유효한 이전 모델의 이력을 임시로 복원한 뒤, 새 사용자 입력과 턴 훅을
반영하고 대상 모델의 재생 규칙을 검사합니다. 이때 `tool_choice=none`에 따른 제외까지
반영해 공급자에게 실제로 보낼 도구 목록을 사용합니다.

대상 모델이 재생하지 않는 추론은 요청에서만 제외하고 원본 체크포인트에는 남깁니다.
최신 사용자 턴만 재생하는 계약에서는 새 사용자 질문이 이전 도구 교환을 닫을 수 있지만,
시스템 후속 메시지는 새 질문으로 취급하지 않습니다. 전송 이력을 축약하면서 원래 사용자
입력이 빠져도 남은 도구 교환이 끝났다고 판단하지 않으며, 필요한 추론을 계속 재생합니다.
진행 중인 교환에 이전 모델의
추론이나 공급자 서명이 여전히 필요하면 전송 전에 거절합니다. 출처가 없거나 손상된
이력도 거절합니다. `checkpoint.reasoning_replay`가 반복되면 대상 모델의 계약과 원본
이력을 확인해야 합니다. 체크포인트를 초기화하면 그 근거도 사라집니다.

## Keeper 하나는 파일 하나

`reviewer` 라는 Keeper 를 만든다면 이 파일 하나입니다.

```text
<base-path>/.masc/config/keepers/reviewer.toml
```

두 번째 파일은 없습니다. 프롬프트는 이 TOML 안 `keeper.instructions` 에 들어갑니다.
`instructions` 가 비어 있으면 빈 프롬프트로 시작하는 게 아니라
`lib/keeper/keeper_types_profile.ml` 이 로드 단계에서 **거부**합니다.

```toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "docker"
mention_targets = ["reviewer", "리뷰어"]

instructions = """
당신은 리뷰 Keeper 입니다. 요약문이 아니라 실제 diff 와 파일 원문을 읽어 주세요.
시그니처가 바뀌었으면 호출처를 전수로 확인해 주세요. 찾은 결함은 file:line 과
재현 조건, 추정 원인까지 같이 적어 주세요.
"""
```

### 실제로 필요한 항목

한 대의 운영 중인 런타임에서 Keeper 11개를 센 결과입니다 (2026-08-25).

| 항목 | 쓰는 곳 | 무엇을 정하나 |
|---|---:|---|
| `activation_mode` | — | 수동 시작(`manual`), 요청 시 실행(`on_demand`), 주기 자율 실행(`autonomous`) |
| `instructions` | 11/11 | Keeper 의 프롬프트 전부. 비면 거부됩니다 |
| `sandbox_profile` | 11/11 | `docker`, `microvm`, `remote_ssh` 중 하나. Keeper 는 그 안에서 돌거나 아예 돌지 않습니다 |
| `mention_targets` | 7/11 | 보드에서 이 Keeper 를 부르는 이름들 |
| `network_mode` | 6/11 | 샌드박스에서 네트워크가 닿는 범위 |
| `name` | 5/11 | 파일 이름과 표시 이름이 다를 때 |
| `always_allow` | 2/11 | 이 Keeper 의 도구 호출을 승인 대기열에 안 넣음 |

앞의 셋은 그 런타임의 모든 Keeper 가 씁니다. 나머지는 실제로 겪어 본 문제에 대한
답일 때만 넣으세요.

모르는 키가 있으면 거부합니다. 항목 전체 규칙은
[`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md) 에 있습니다.

### 서버 재시작 뒤 Apple MicroVM 재사용

시작 시 현재 Keeper TOML과 `keeper.name` 별칭에서 계산한 Apple guest는 이전 서버
PID의 생존 여부와 관계없이 보존합니다. 선언 목록이나 런타임 전체 목록을 읽지 못해도
VM을 보존합니다. 턴은 실제 부팅 정보와 요청한 plan을 대조하고
`<base-path>/.masc/microvm/identity/apple_container/`의 불변 인증 사본을
검증한 뒤 실행 중인 guest를 재사용합니다. 사실을 읽을 수 없거나 같은 plan인데 실제
설정이 다르면 guest를 보존하고 재사용을 거부합니다.

Apple 부팅은 이미지의 entrypoint를 요청한 실행 파일로 덮어씁니다. 재사용 시 읽기 전용
이미지 조회는 guest의 이미지 descriptor와 정확한 platform에 일치해야 하고, 실제 명령은
요청한 명령과 같아야 합니다. 이미지 정보가 없거나 모호하면 guest를 보존하고 재사용을
거부하며, 교체를 허가하지 않습니다. 요청이 같은 guest는 plan label을 바꾸지 않고
재사용할 수 있습니다.

`microvm_guest_ownership_unverified`는 예상한 이름의 Apple guest에서 작업 공간,
Keeper, 종류, 네트워크 또는 백엔드 라벨이 없거나 다르다는 뜻입니다. MASC는 해당
guest를 보존하고 요청을 거부합니다. inspect 결과를 읽을 수 없을 때도 guest를
보존합니다. 이 확인은 부팅 plan 라벨과 다릅니다. plan 라벨만 없거나 다른 경우에는
다른 허용 조건을 모두 통과한 뒤 교체될 수 있지만, 소유 범위 라벨이 없으면 거부합니다.

운영자는 전체 목록과 MASC가 보고한 정확한 guest 이름을 변경 없이 확인할 수 있습니다.

```sh
container list --all --format json
container inspect "$guest_name"  # 먼저 확인된 정확한 이름을 guest_name에 넣으세요
```

guest의 상태와 `masc.mcp.component`, `masc.mcp.base_path_hash`,
`masc.mcp.keeper`, `masc.mcp.kind`, `masc.mcp.network`,
`masc.mcp.microvm_backend` 라벨을 실제 작업 공간과 Keeper 설정에 대조하세요.
해시와 라벨은 관측값이며 소유권 증명이나 조회 이후 교체를 막는 장치가 아닙니다.
inspect 출력에는 환경 변수와 마운트 정보가 들어갈 수 있으므로 관련 소유자가 허용한
범위에서만 공유하세요. 독립 근거로 소유자를 확인할 수 없다면 guest와 볼륨을 보존하고,
경고를 없애기 위해 라벨을 바꾸거나 삭제·재시작하지 마세요.

공유 exec shim 설정은 endpoint를 받기 전에 초기화합니다. 설치가 없거나 잘못되면
오류를 표시합니다. shim 설치를 수리하면 다음 endpoint 접속에서 시작 시 실패를 다시
확인하므로 설정을 안전하게 준비할 수 있다면 서버 재시작이 필요하지 않습니다. 실행 중
복구할 때 호스트 shim 설정 파일이 없으면 기존 파일을 덮어쓰지 않고 다시 만듭니다.
이때 읽을 수 없거나 예상과 다른 파일은 보존하고 오류로
표시합니다. 캡처한 외부 읽기도 같은 endpoint를 유지하면서 호스트 설정을 다시 확인합니다.
외부 파일 읽기는 호스트의 인증 사본과 shim을 검증하며 VM 시작이나 빌드 삭제를 하지
않습니다. Apple에서는 guest의 범위 라벨도 확인합니다. 이런 확인은 guest가 마운트를
보고 읽을 수 있다는 사실이나 실제 마운트된 인증 inode를 증명하지 못하며, 확인 이후
guest 교체도 막지 못합니다. 서버 프로세스의 첫 소유 턴 접속은 보존 표시가 없는 실제 `_build`를 별도
디렉토리로 옮긴 뒤 삭제합니다. `.masc-keep-build`가 있으면 해당 출력을 보존합니다.

#### 빌드 준비가 실패를 보고할 때

`microvm_build_link_mkdir_failed` 또는 `microvm_build_link_apply_failed`는 0이 아닌
종료 상태나 signal을 보고할 수 있습니다. 127은 인터프리터를 시작하지 못한 경우일 수
있습니다. 로컬 종료 상태만으로 원인이나 guest 효과의 미실행을 판단하지 마세요.
guest·볼륨·링크를 보존하고 확인하세요. 서비스나 guest를 재시작해도 미확인 효과는
해결되지 않습니다.

같은 서버 프로세스에서는 backend와 Keeper 작업 볼륨마다 cleanup 기회를 한 번만
소비합니다. workspace나 network mode가 달라도 같은 이력을 사용합니다. 명시적인
request-not-sent도 이후 턴이 새 빌드 출력을 만들 수 있으므로 다시 보내지 않습니다.
영수증으로 확인된 성공은 반복하지 않습니다. 종료 상태와 일치하는 영수증이 있는
실패·signal·shim timeout·실행 전 거부도 cleanup을 소비하고 실제 `_build` 항목을 보존한 채 준비를
이어 갑니다. 영수증 누락·예외·취소 때도 runner의 명확한 request-not-sent 근거가
없으면 cleanup 결과를 미확인으로 남깁니다.
`microvm_build_cleanup_effect_unverified`는 새 실행 handoff를 제공할 수 없는 Keeper를
표시합니다. 원래 cleanup이 나중에 생긴 출력을 옮길 수 있기 때문입니다. guest와
identity를 검증할 수 있으면 진단용 attached 읽기는 가능하지만 cleanup의 종료를
증명하지는 않습니다.

준비 캐시를 무효화하면 링크를 읽기 전용으로 다시 조사합니다. build 볼륨은 일회성이므로
대상 디렉터리 생성은 멱등적으로 다시 수행할 수 있습니다. 결과가 미확인인 symlink 생성은
다른 workspace·network 이름에서도 재전송하지 않습니다. 현재 올바른 링크와 안전한 생성
계획 모두에 대상 디렉터리를 준비합니다. 조사 때 링크가 없었더라도 이전 미확인 생성이
뒤늦게 적용될 수 있기 때문입니다. 실제 디렉터리와 다른 대상을 가리키는 링크는 보존합니다.

attached 정기 정리도 같은 작업 볼륨에 자기 실행 시도를 예약합니다.
`microvm_build_maintenance_effect_unverified`는 결과가 미확인인 정리의 operation ID를
표시하며, 그 정리를 다시 보내지 않고 새 실행과 정리를 거절합니다. 명확한 종료 또는
request-not-sent 근거가 있으면 예약을 해제합니다. 진단용 읽기는 유지합니다. 기존 workspace
감사 로그의 `custom:keeper_microvm_build_maintenance`에 실행 전 intent와 결과, operation ID,
민감 정보를 가린 boundary·exit·signal·timeout·shim 오류를 기록합니다. 명령 출력과 인증
정보는 저장하지 않습니다. intent를 기록할 수 없으면 정리를 보내지 않습니다. 이 로그는
flush된 조사 근거이며 fsync 기반 실행 권위나 서버 재시작 후 자동 복구 원장이 아닙니다.

현재 읽기 전용 조사만으로 원래 symlink 생성이 종료됐다고 증명할 수 없으므로, 그 결과가
미확인이면 실행 handoff를 거부합니다. 실행 endpoint는 현재 guest 준비 세대에서 링크 조사와
필요한 대상 준비가 완료됐을 때만 제공합니다. 읽기 전용 조사 실패는 후속 handoff에서 다시
확인할 수 있습니다. 영속 symlink 결과가 미확인이 아니라면 대상 mkdir만 실패한 경우도
guest 중지나 준비 캐시 초기화 없이 같은 세대에서 재시도합니다. 경고만 남기고 실행
endpoint를 제공하지는 않습니다.

이 이력은 현재 프로세스의 이름 기반 기록입니다. 서버를 재시작하면 사라지고 첫 handoff가
cleanup을 다시 시도할 수 있습니다. 미확인 효과를 복구하려고 재시작하지 마세요. 서버
재시작을 넘는 durable no-replay, 물리 볼륨 identity와 다른 프로세스의 변경을 막는 fencing은
제공하지 않습니다. guest 라벨도 외부 인스턴스나 mount 교체를 막지 못합니다.

영향받은 guest 안에서 root와 Keeper uid·gid **양쪽으로** 고정 경로를 확인하세요. 대상
디렉터리 준비는 root, 링크 생성은 Keeper 권한으로 실행되므로 한 사용자의 확인으로 다른
사용자의 접근을 판단할 수 없습니다. helper는
`/usr/bin/python3`, `/usr/local/bin/python3` 순서로 선택하며 둘 다 `-x`를 통과하지
못하면 인터프리터를 선택하지 않고 127로 종료합니다. 아래 확인은 권한만 읽으며 실행
여부를 검증하지 않습니다.

```sh
for guest_runtime in /usr/bin/python3 /usr/local/bin/python3; do
  if [ -x "$guest_runtime" ]; then
    printf '%s: -x check passed; execution is not verified\n' "$guest_runtime"
  else
    printf '%s: absent or not executable for this user\n' "$guest_runtime"
  fi
done
```

확인 결과와 이후 진단 출력은 영향받는 소유자가 허용한 공유 범위 안에 두세요. Python 경로가 `-x`를
통과한 뒤 실행에 실패하면 helper는 다음 후보로 넘어가지 않습니다. 권한 확인만으로 실행
파일, 로더, guest 전송 경로나 이전 효과가 정상이라고 판단할 수 없습니다. 남은 효과의
결과와 다른 작업 공간의 소유자를 확인한 뒤 변경을 계획하세요. 이 확인만으로 소프트웨어를 설치하거나
guest를 교체하고, 서비스를 재시작하거나 재시도하지 마세요. 선택된 런타임을 사용할 수
없다면 운영자에게 신뢰할 수 있는 호환 이미지 또는 인터프리터 준비를 요청하세요. 아래
진단에도 이 두 경로 중 신뢰할 수 있는 Python이 필요합니다. 원격 checkout 탐색과 예약된
attached build 정리는 별도로 guest의 `PATH`에서 `python3`를 호출하므로, 고정 경로 확인만으로
이 명령들의 실행 가능성을 판단할 수 없습니다.

#### `_build` 항목 확인하기

링크 경고에는 체크아웃 경로가 나오지 않습니다. 심볼릭 링크가 아닌 기존 `_build`는
디렉터리일 수도, 다른 종류의 항목일 수도 있습니다. 링크 탐색은 이를 바꾸지 않습니다.
`dune-project`가 있는 체크아웃의 실제 `_build` 디렉터리는 새 서버 프로세스의 첫 소유
handoff 등 이후 handoff에서, 검사 시 체크아웃의 `.masc-keep-build`가 존재하는 것으로
확인되지 않으면 staging된 뒤 삭제될 수 있습니다. 이 마커는 해당 체크아웃의 staging을
막지만 이미 `.masc-build-removing`에 옮겨진 출력을 되살리거나 다른 쓰기 작업을 막지는
못합니다. 변경 전 영향받는 모든 소유자와 조율하고, 경고 확인만을 위해 서비스나 guest를
재시작하지 마세요.

신뢰할 수 있는 guest의 허가된 실행 경로에서 첫 handoff를 수행하는 Keeper uid·gid로
실제 작업 루트에 접근하세요. root로만 확인해서는 Keeper가 무엇을 읽을 수 있는지 알 수
없습니다. 아래 `reviewer`는 해당 Keeper의 정규화된 이름으로 바꿉니다. 이 읽기 전용 탐색은 루트 아래
세 단계까지 `_build` 심볼릭 링크, 실제 디렉터리와 다른 항목을 구분해 표시합니다. `.git`,
`_build`와 루트의 예약된 `.masc-build-removing` 트리는 건너뛰고 디렉터리 심볼릭 링크는
따라가지 않습니다. 루트 자체와 더 깊은 디렉터리는 체크아웃 탐색 범위 밖입니다.
`dune-project: True`는 해당 표시가 존재하는 것으로 해석됐다는 뜻이고,
`.masc-keep-build: True`는 그 시점에 보존 표시가 존재하는 것으로 해석됐다는 뜻입니다.
대상이 없는 표시 링크는 `False`, 표시 읽기 오류는 `unverified`입니다. 다른 오류는
stderr에 표시되며 목록이 불완전할 수 있습니다. pending 상태는 staging된 내용물을 열어
보지 않습니다. 확인 직후에도 상태는 바뀔 수 있습니다.

출력에 공유 볼륨의 경로와 링크 대상이 드러날 수 있으므로 영향받는 모든 작업 공간
소유자가 허용한 공유 범위 안에서만 보고, 보관하고, 전달하세요. 고정 경로의 인터프리터는
신뢰할 수 있는 guest 이미지에 있어야 합니다. 격리 옵션은 신뢰할 수 없는 실행 파일을
안전하게 만들지 않습니다. 루트 확인은 한 시점의 관측이며 이후 교체를 막지 않습니다.

```sh
keeper_work_root=/masc-work/reviewer  # replace with the actual guest path
[ ! -L "$keeper_work_root" ] || { printf '%s\n' 'Work root is a symlink; stop.' >&2; exit 1; }
cd -- "$keeper_work_root" || exit 1
if [ -x /usr/bin/python3 ]; then
  guest_python=/usr/bin/python3
elif [ -x /usr/local/bin/python3 ]; then
  guest_python=/usr/local/bin/python3
else
  printf '%s\n' 'No supported Python; ask the operator.' >&2
  exit 1
fi
"$guest_python" -I -S -B - <<'PY'
import os, stat, sys

def report(error):
    print("cannot inspect:", repr(error.filename), repr(error), file=sys.stderr)

def exists(path):
    try:
        os.stat(path)
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        report(error)
        return "unverified"

try:
    os.lstat("./.masc-build-removing")
    print("pending cleanup: present; contents not inspected")
except FileNotFoundError:
    print("pending cleanup: absent")
except OSError as error:
    report(error)
    print("pending cleanup: unverified")

for base, dirs, _ in os.walk(".", topdown=True, followlinks=False, onerror=report):
    rel = os.path.relpath(base, ".")
    depth = 0 if rel == "." else len(rel.split(os.sep))
    dirs[:] = [] if depth >= 3 else [d for d in dirs if d not in (".git", "_build")]
    if rel == ".":
        dirs[:] = [d for d in dirs if d != ".masc-build-removing"]
        continue
    entry = os.path.join(base, "_build")
    try:
        mode = os.lstat(entry).st_mode
    except FileNotFoundError:
        continue
    except OSError as error:
        report(error)
        continue
    if stat.S_ISLNK(mode):
        kind = "symlink"
        try:
            target = repr(os.readlink(entry))
        except OSError as error:
            report(error)
            target = "<unverified>"
    elif stat.S_ISDIR(mode):
        kind, target = "directory", "-"
    else:
        kind, target = "other", "-"
    print("checkout:", repr(rel), "_build:", kind, "target:", target,
          "dune-project:", exists(os.path.join(base, "dune-project")),
          ".masc-keep-build:", exists(os.path.join(base, ".masc-keep-build")))
PY
```

#### 체크아웃을 옮긴 뒤 보존된 `_build` 링크

MASC는 `_build` 심볼릭 링크가 현재 체크아웃에 기대되는 빌드 대상과 다르면 소유자를
확인할 수 없어 그대로 둡니다. 예를 들어 체크아웃을 `old`에서 `new`로 옮겨도 링크는
`/masc-build/old`를 가리킬 수 있습니다. 새 부팅 때 build volume이 비워져 링크가
끊기면 Dune 빌드가 실패할 수 있습니다. MASC는 이전 대상을 만들거나 링크를 자동으로
바꾸지 않습니다. Keeper 작업 루트 바로 아래 `new`의 기대 대상은 `/masc-build/new`,
`repos/new`의 기대 대상은 `/masc-build/repos:new`입니다. 이름에 `:`이 들어가면 이
방식으로 매핑할 수 없으므로 대상을 추측하지 말고 운영자에게 확인하세요. 위 읽기 전용
탐색에서 영향받는 링크를 찾을 수 있습니다.

해당 Keeper의 실행 경로 또는 허가된 guest 셸로 **해당 guest 안의 체크아웃**에서
탐색에 나온 정확한 경로를 선택하고 다음을 실행해 확인하세요. 경로는 하나의 인자로
인용하고, 이스케이프된 표시를 셸 명령으로 그대로 취급하지 마세요. 명령은 현재 경로와
링크만 읽습니다. `False`는 대상이 없거나,
접근할 수 없거나, 디렉터리가 아니라는 뜻일 수 있습니다.

```sh
if [ -x /usr/bin/python3 ]; then
  guest_python=/usr/bin/python3
elif [ -x /usr/local/bin/python3 ]; then
  guest_python=/usr/local/bin/python3
else
  printf '%s\n' 'No supported Python; ask the operator.' >&2
  exit 1
fi
"$guest_python" -I -S - <<'PY'
import os
print("checkout:", repr(os.getcwd()))
print("_build link:", repr(os.readlink("_build")) if os.path.islink("_build") else "<not a symlink>")
print("target is a directory:", os.path.isdir("_build"))
PY
```

`_build`가 심볼릭 링크가 아니거나 체크아웃·마운트가 예상한 곳이 아니라면 복구를
멈추고 실제 항목부터 살펴보세요. 기존 디렉터리에는 빌드 데이터가 있을 수 있습니다.

변경하기 전에 Keeper, 작업 공간, 체크아웃과 링크의 소유자를 확인하세요. 서로 다른
작업 공간의 동명 Keeper가 볼륨을 공유할 수 있습니다. 관련 소유자와 조율해 어느 빌드나
다른 쓰기 작업도 체크아웃과 대상을 사용하지 않는지 확인하세요. 한 guest의 프로세스
목록만으로 독점 소유를 증명할 수는 없습니다. 소유권이나 작업 상태가 불확실하면 링크와
대상을 보존하고 운영자에게 확인을 요청하세요.

체크아웃 소유자가 빌드해도 안전하다고 확인하고 운영자가 guest의 `/tmp`가 해당 guest만의
임시 저장 공간인지 확인했다면, 그 안에 새 디렉터리를 만들어 기존 링크와 이전 대상을
건드리지 않고 Dune 명령을 복구할 수 있습니다. `/tmp`에 쓸 수 있는 허가된 guest 실행
경로에서만 실행하세요.

```sh
umask 077
recovery_dir=$(mktemp -d /tmp/masc-dune-recovery.XXXXXXXX) || exit 1
printf 'Recovery build directory: %s\n' "$recovery_dir"
DUNE_BUILD_DIR="$recovery_dir" dune build
```

이후 Dune 명령에도 같은 `DUNE_BUILD_DIR`을 사용하세요. guest의 `/tmp`는 용량이 제한돼
있고 guest 메모리를 사용할 수 있으며, guest가 중지되거나 교체되면 내용이 사라질 수
있습니다. 디렉터리 권한이 0700이어도 같은 uid의 다른 프로세스와는 격리되지 않습니다.
자동으로 정리하지 않으므로 소유자와 사용 중인 빌드가 없음을 확인한 뒤 승인된 운영
절차로 그 정확한 디렉터리만 정리하세요. `/tmp`가 guest 전용인지 확인하지 못했거나 해당
실행 경로에서 쓸 수 없다면 운영자에게 요청하세요. 소유권이 불확실한 공유 볼륨으로 이
우회 경로를 옮기지 마세요. `_build`를 강제로 사용하는 스크립트는 여전히 실패할 수
있습니다.

링크를 영구 복구하려면 소유자·운영자와 조율해 이전 링크와 대상을 보존하고, 현재
체크아웃의 정확한 대상이 이 작업 공간 소유이며 사용 중이지 않은지 확인한 뒤 강제
덮어쓰기나 일괄 삭제 없이 교체하고 결과를 확인하세요. 이전 링크를 살린다는 이유로
`/masc-build/old`를 만들지 마세요. 다른 체크아웃이 쓸 수 있습니다.

작업 볼륨 확인은 guest가 마운트 부재를 직접 보고한 경우
(`microvm_work_volume_not_mounted`)와 확인 명령이 실패하거나 시간 초과된 경우
(`microvm_work_volume_probe_unverified`)를 구분합니다. 후자는 마운트 상태를
모르는 것이므로 guest와 실행 경로를 살펴본 뒤 복구 방법을 정하세요. 어느 결과도
그 자체로 GitHub 인증 정보가 잘못됐다는 뜻은 아닙니다. 두 경우 모두 guest 사용은
거부합니다.

Sandbox 상태는 work volume의 현재 discard 기본값을 `set`, `absent`, `unreadable`로
보여 줍니다. 작업 공간별 소유권이 확인되기 전에는 새 부팅에서 discard 설정을 바꾸는
helper를 자동 실행하지 않습니다. 기존 설정이 없다면 파일을 지워도 호스트 디스크가
즉시 반환되지 않을 수 있습니다. 같은 이름의 trim 또는 repair helper가 있거나 목록을
확인할 수 없으면 Apple guest의 새 부팅 또는 프로세스의 첫 인수 시 사용을 거부하고
helper를 보존합니다. 이미 캐시된 연결과 연결된 파일 읽기는 이 검사를 다시 하지 않습니다.
종료 시에도 helper를 삭제하지 않고 확인 결과를 알립니다. 이 확인은 한 시점의 관측이며 다른
프로세스의 이후 실행을 막거나 볼륨 소유권을 증명하지는 않습니다. build volume은 새
부팅 때 다시 만들며 Nerdctl/Kata의 프로세스 소유 규칙은 유지합니다.
확인 가능한 경우 `container list --all --format json`과 `container inspect <helper-이름>`으로
helper의 상태와 마운트를 읽어 책임 작업과 다른 작업 공간의 사용 여부를 조사하세요.
목록이 응답하지 않거나 소유자·작업 종료를 확인하지 못하면 helper와 볼륨을 보존하세요.
[guest 생존 RFC](rfc/RFC-keeper-guest-survives-restart.md)에 결정 배경이 있습니다.

### `mention_targets` 는 목록이고, 한 칸이 이름 하나입니다

```toml
mention_targets = ["rondo", "론도"]   # 이름 두 개
mention_targets = ["rondo, 론도"]     # 아무도 안 칠 이름 한 개
```

각 칸은 대소문자만 접히고 통째로 보관됩니다. 문자열 안의 쉼표는 칸을 나누지 않고,
그 결과를 거부하는 곳도 없습니다. 그래서 잘못 쓰면 **아무 멘션도 안 닿는 채로
조용히 지나갑니다.** 이건 자기 설정에서 한 번 다시 읽어 볼 값입니다.

## 작업 표면 (playground)

Docker 안의 작업 디렉토리는 `/home/keeper/playground/<이름>/`이고 호스트
디렉토리는 `<base>/.masc/playground/` 아래에 있다. microVM의 실행 경로는
`/masc-work/<정규화된 이름>/`이며 작업 트리는 런타임의 이름 있는 볼륨에 있다.
remote_ssh는 엔드포인트의 작업 루트를 사용한다. microVM 볼륨 이름에는 작업 공간이
없으므로 같은 런타임 저장소의 동명 Keeper는 서로의 트리를 공유할 수 있다.

microVM에서 `observation_run = "guest_local"`을 설정해도 관측 단계는 볼륨의
독점 소유권을 확인할 수 없어 이 상자를 실행하지 않고 judge로 넘긴다. 다른 허가
경로나 승인된 실행에서 공유 볼륨에 쓰는 것은 이 제한만으로 막지 못한다. 현재
Keeper 트리 안의 `Write`/`Edit`도 별도 Gate 없이 원격 쓰기 경로로 갈 수 있다.

Auto Judge에서는 `file`, `uniq`, `git ls-remote`, `git cat-file`,
`git rev-list`, `git shortlog`를 알아보면 관측 실행보다 먼저 judge에게 묻는다.
읽기만 하는 형태도 대기할 수 있다. 기존 승인이나 Always Allow가 먼저 적용될 수
있고, 인식할 수 없는 동적 명령까지 모두 판별하는 기능은 아니다.

진단을 정확하게 만드는 세 가지 사실:

- **비어 있을 수 있다.** 새 작업 트리는 비어 있을 수 있다. 빈 디렉토리에 `ls`가
  성공했다면 표면은 도달 가능하고 아직 내용이 없을 뿐이다. 기존 microVM 볼륨을
  재사용하는 경우에는 이전 파일이 남아 있을 수 있다.
- **저장소는 Keeper 가 playground 안에 직접 clone 한다.** 관습 위치는
  `playground/<이름>/repos/<repo>` 다 (예:
  `gh repo clone <owner>/<repo> repos/<repo> -- --depth 50`).
  실행 위치 추적이 이 모양을 인식해 호출을 `repo_root` / `repo_subpath` 로
  분류하므로 Gate 와 관측이 어느 저장소를 건드렸는지 읽는다. 다른 위치에
  clone 해도 동작은 하지만 `playground_subpath` 로만 분류된다.
- **playground 밖 경로 스킴은 없다.** `/home/keeper/repos/<repo>` 를
  만들어 주거나 호스트 체크아웃을 sandbox 에 mount 하는 장치는 존재하지
  않는다. playground 가 쓰기 가능한 표면의 전부다.

## 샌드박스 용량과 배치 조합

프로필은 실행 방식과 격리 방식을 고르는 설정입니다. 고른다고 해서 게스트가
정상으로 떠 있다는 뜻은 아닙니다. 아래 숫자는 지금 구현된 기본값이고, 권장하는
Keeper 수가 아닙니다. 기본값은 `lib/config/env_config_sandbox.ml`과
`lib/runtime/exec_ssh_endpoint.ml`에 있고, 이 표와 코드가 다르면 코드가
맞습니다. Keeper 전체 수나 호스트 메모리 총량을 제한하는 기능은 아직 없습니다.
[호스트 메모리 예산 RFC](rfc/RFC-keeper-guests-stay-inside-a-host-memory-budget.md)와
그 안의 hibernation 설계도 아직 초안입니다.

| 프로필 / backend | 실행 단위와 지금 제한 | 네트워크와 공유 범위 |
|---|---|---|
| `microvm` + `apple_container` | Keeper마다 게스트가 하나씩 계속 떠 있습니다. 기본은 4 vCPU, 2 GiB이고 `microvm_cpus`, `microvm_memory`로 Keeper마다 바꿀 수 있습니다. work·build 볼륨 기본값 256g/128g는 늘어날 수 있는 최대 크기이고, 지금 호스트에서 차지하는 용량이 아닙니다. | `none`, `inherit`, `policy`를 지원합니다. Keeper마다 VM이 따로 있고, `policy`의 네트워크와 허용 목록(allowlist)도 Keeper별로 씁니다. 방법은 [egress 정책 runbook](operations/egress-policy-runbook.md)에 있습니다. |
| `microvm` + `nerdctl_kata` | 같은 CPU·메모리 설정을 쓰는 Keeper별 게스트입니다. | 나가는 트래픽이 실제로 막히는지 확인하지 못해서 `policy`는 거부합니다. |
| `microvm` + `microsandbox` | backend 어댑터는 있지만, MASC가 이 backend로 게스트를 끝까지 띄우고 정리하는 흐름은 아직 완성되지 않았습니다. | `policy`는 거부합니다. 여러 Keeper를 운영하는 구성의 예시로 쓰지 마세요. |
| `docker` | Keeper마다 컨테이너가 하나씩 계속 떠 있습니다. 모든 컨테이너에 같은 기본 제한이 걸립니다(메모리 2 GiB, pids 128, nofile 245760, tmpfs 256m). Keeper TOML 필드가 아니라 workspace 공통 설정입니다. | `none`, `inherit`만 지원하고 `policy`는 거부합니다. 컨테이너는 Keeper마다 따로 있습니다. |
| `remote_ssh` | MASC가 게스트를 만들지 않고, Keeper별 CPU·메모리 제한도 없습니다. endpoint 하나의 기본 동시 세션은 8개이고, 그 endpoint를 쓰는 모든 Keeper가 나눠 씁니다. | 네트워크는 endpoint 호스트의 정책을 따릅니다. 같은 endpoint의 Keeper는 Unix 계정과 동시 세션 한도를 함께 씁니다. Keeper를 가르는 건 자기 디렉터리 밖 경로를 쓰지 못하게 검사하는 jail뿐이고, OS가 격리해 주지는 않습니다. |

전체 용량은 이렇게 계산합니다. 동시에 뜰 수 있는 게스트가 설정 최대치까지 쓴다고
보고 모두 더한 다음, 공유하는 SSH·컨테이너 한도와 MASC 서버가 쓰는 만큼을
더합니다. 볼륨 최대 크기나 게스트 안의 지금 `df` 사용량을 메모리 합계 대신
쓰지 마세요.

### Keeper 한 명에 Apple microVM 한 대

sandbox 이미지 이름은 workspace의 허용 이미지 목록(admitted sandbox image
catalog)에 있어야 합니다.

```toml
# <base>/.masc/config/keepers/builder.toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "microvm"
microvm_backend = "apple_container"
sandbox_image = "ocaml"
network_mode = "inherit"
microvm_memory = "6g"
microvm_cpus = 4
instructions = "현재 변경을 빌드하고 검토하며 정확한 증거를 보고한다."
```

이 Keeper만 쓰는 GitHub 계정은 device code 방식으로 로그인합니다.

```sh
masc keeper-github login --keeper builder --base-path /srv/masc-workspace
```

특정 주소만 열고 싶으면 `network_mode`를 `"policy"`로 바꾸고, 실제 runtime TOML에
허용 목록을 적습니다.

```toml
[egress.keepers.builder]
allow = ["github.com", "api.github.com", "*.githubusercontent.com"]
```

호스트만 적으면 443 포트를 허용합니다. `*.githubusercontent.com` 같은 wildcard는
`githubusercontent.com` 자체를 포함하지 않습니다. `policy`를 지원하지 않는
backend는 `inherit`로 몰래 바꾸지 않고 요청을 거부합니다.

### Keeper 한 명에 Docker 컨테이너 하나

```toml
# <base>/.masc/config/keepers/reviewer.toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "docker"
sandbox_image = "ocaml"
network_mode = "inherit"
instructions = "현재 diff를 검토하고 정확한 증거를 보고한다."
```

이 Keeper는 턴이 바뀌어도 자기 컨테이너를 계속 씁니다. playground는 컨테이너에
마운트한 호스트 디렉터리입니다. 메모리·pids 제한은 workspace 공통 설정이라
`microvm_memory`와 `microvm_cpus`는 적용되지 않습니다.

### SSH endpoint 하나에 Keeper 셋 — 컨테이너 한 대도 가능

endpoint는 한 번만 선언합니다.

```toml
# <base>/.masc/config/runtime.toml
[exec.ssh.endpoints.team]
host = "builder.example.net"
user = "masc-exec"
port = 22
remote_root = "/srv/masc/playground"
connect_timeout_sec = 10
max_concurrent_sessions = 8
env_allowlist = ["LANG"]
capabilities = []
private_home = false
```

Keeper마다 endpoint 아래에 자기만의 작업 디렉터리와 GitHub 설정을 둡니다.

```toml
# <base>/.masc/config/keepers/research-a.toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "remote_ssh"
remote_endpoint = "team"
network_mode = "inherit"
instructions = "배정된 작업을 조사하고 1차 출처를 인용한다."
```

```toml
# <base>/.masc/config/keepers/research-b.toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "remote_ssh"
remote_endpoint = "team"
network_mode = "inherit"
instructions = "배정된 변경을 검토하고 정확한 증거를 인용한다."
```

```toml
# <base>/.masc/config/keepers/research-c.toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "remote_ssh"
remote_endpoint = "team"
network_mode = "inherit"
instructions = "현재 조사 결과를 요약하고 출처 링크를 보존한다."
```

`max_concurrent_sessions = 8`은 Keeper마다 8개가 아니라, 셋이 함께 쓰는 전체
한도입니다. 작업 디렉터리와 GitHub 계정은 아래 명령으로 Keeper마다 따로 만들어
줍니다.

```sh
masc-exec-ssh-bootstrap \
  --base-path /srv/masc-workspace \
  --endpoint team \
  --shim /opt/masc/masc-exec-shim \
  --github-token-file research-a=/secure/tmp/research-a.token

masc-exec-ssh-bootstrap \
  --base-path /srv/masc-workspace \
  --endpoint team \
  --shim /opt/masc/masc-exec-shim \
  --github-token-file research-b=/secure/tmp/research-b.token

masc-exec-ssh-bootstrap \
  --base-path /srv/masc-workspace \
  --endpoint team \
  --shim /opt/masc/masc-exec-shim \
  --github-token-file research-c=/secure/tmp/research-c.token
```

endpoint는 운영자가 미리 만들어 둔 Linux 컨테이너 한 대여도 됩니다. 이 컴퓨터에
있어도 되고 다른 호스트에 있어도 됩니다. MASC는 그 컨테이너의 SSH 포트에 접속할
뿐, 컨테이너를 만들거나 다시 시작하거나 제한하지 않습니다. CPU·메모리·swap·pids
상한은 Docker나 쓰고 있는 컨테이너 런타임에서 직접 거세요. 계정을 같이 쓰므로
`private_home = false`는 그대로 둡니다.

세 Keeper는 디렉터리 jail과 GitHub 설정 디렉터리를 각자 갖지만, 커널과 Unix
계정은 함께 씁니다. 서로 믿을 수 있는 Keeper끼리 묶을 때 맞는 구성입니다. 다른
Keeper와 더 확실히 떼어 놓아야 하면 endpoint와 Unix 계정을 따로 선언하세요.

그래서 빌드를 하는 Keeper는 microVM으로 하나씩 떼어 놓고, 서로 믿을 수 있는
가벼운 Keeper는 공유 SSH 컨테이너에 두는 식으로 섞어 쓸 수도 있습니다. 이 배치는
운영자가 직접 고르는 설정입니다. 자동 배치나 Keeper별 cgroup 예산은 없습니다.

### 자격증명을 바꾸기 전에 샌드박스 오류를 구분하세요

| 신호 | 뜻 | 먼저 할 일 |
|---|---|---|
| `sandbox_guest_unavailable` (`microvm_work_volume_probe_unverified`가 들어 있는 경우 포함) | 게스트를 띄우거나, 떠 있는 게스트를 이어받거나, 교체하는 단계가 실패했습니다. 명령을 게스트로 보내는 연결(transport)이 실패한 경우도 같습니다. GitHub가 토큰을 거부했다는 증거는 아직 없습니다. | 게스트와 transport부터 확인하세요. 다시 로그인하거나 `gh auth status`를 반복하면, 이미 문제가 있는 게스트에 요청만 더 쌓입니다. |
| `github_identity_snapshot_unavailable` | 이 Keeper의 GitHub 로그인 정보에서 문제가 생겼습니다. 로그인 정보를 갱신하거나, 스냅샷을 만들거나, revision을 검사하는 단계가 실패한 경우입니다. 게스트나 컨테이너를 띄우다가 로그인 정보가 올바르지 않아 멈춘 경우도 같습니다. | `masc keeper-github status`나 GitHub 탭에서 이 Keeper의 GitHub 계정을 확인하세요. |
| `remote_github_unreachable` | 이 Keeper의 인증이 실패했고 GitHub API도 응답하지 않아서, 토큰이 유효한지 알 수 없습니다. | endpoint의 네트워크와 DNS부터 고친 뒤 인증을 다시 확인하세요. |
| `remote_github_identity_missing` | API는 응답했지만 이 Keeper 전용 인증이 실패했습니다. | 이 Keeper의 GitHub 계정을 다시 설정하세요. 도구를 부를 때마다 토큰을 붙여 넣지 마세요. |

2026-10-28부터 29일까지 이어진 Apple 장애
[#46602](https://github.com/jeong-sik/masc/issues/46602)가 첫 번째 경우입니다.
멈춘 runtime과 API 서버의 전역 락 때문에 여러 게스트의 `exec`가 막혔는데, 예전
MASC 오류 메시지는 이를 GitHub 로그인 실패처럼 보여 줬습니다. transport와 네트워크
문제를 확인하는 방법은 [SSH endpoint runbook](operations/ssh-endpoints-runbook.md)과
[egress 정책 runbook](operations/egress-policy-runbook.md)에 있습니다.

## 런타임 배정

Keeper 가 자기 모델을 정하지 않습니다. `runtime.toml` 이 정합니다.

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

Keeper–런타임 연결이 정해지는 곳은 이 표 하나뿐입니다. 다만 같은 이름의 레인이
있으면 레인이 먼저입니다. 적어 둔 id 가 실제로 도는 그 id 가 맞는지, 동명 레인이
있는지 먼저 확인하세요.

### 레인에 후보를 하나만 두지 마세요

위 런타임에서 8월 한 달 동안 턴 27,136개가 종료됐습니다. 21,365개는 끝났고
5,706개는 실패했습니다. 그중 5,405개의 운영자 판정이 `fail_open_next_runtime`
이었습니다 — 레인의 다음 후보로 넘어가서 계속 갔다는 뜻입니다.

현재 영수증은 실행 전에 막힌 턴에 이 값을 쓰지 않습니다. `operator_action_required`
와 함께 이유를 둘 중 하나로 적습니다. 운영자가 할 일이 서로 다르기 때문입니다.
런타임이 설정값을 거부하면 `config_invalid` 이고, 제공자가 요청을 거절하면
`authorization_refused` 입니다. 뒤쪽은 실제로는 주간·5시간 사용량 한도라서, 설정을
고치는 게 아니라 슬롯을 옮겨야 합니다. 둘 다 다음 런타임으로 넘어갔다고 주장하지
않습니다.

fallback이 관측되지 않은 최종 network/timeout 오류는 `retry_later`와
`transient_runtime_retry`를 기록합니다. 현재 턴은 끝났고 Keeper는 살아 있어 이후
keepalive 주기에 다시 시도할 수 있지만, 다른 레인 후보를 실행했다고 주장하지 않습니다.

invalid request나 response parse failure처럼 fallback이 관측되지 않은 다른 최종 provider
오류도 `retry_later`를 씁니다. 사유는 `provider_runtime_error`로 유지해 transient network
recovery로 가장하지 않습니다.

실패의 대부분은 버그가 아니었습니다. 가장 많았던 사유는 `config_error`,
`api_error_invalid_request`, `api_error_payment_required`,
`api_error_rate_limited` 입니다. 전부 후보가 하나뿐인 레인이 못 버티는 상황입니다.
쿼터가 떨어지고, 키가 만료되고, 프로바이더가 특정 요청 모양을 거절하면, Keeper 는
넘어가는 대신 멈춥니다.

이 런타임과 비슷한 모양이라면 후보를 하나만 두는 것은 턴 다섯에 하나를 그냥 버리는
선택입니다. 숫자를 그대로 옮기지 말고 자기 런타임에서 재 보세요.

## 켜고, 끄고, 지켜보기

```text
masc_keeper_up(name="reviewer")
masc_keeper_status(name="reviewer")
masc_keeper_down(name="reviewer")
```

`activation_mode = "autonomous"` 또는 `"on_demand"` 면 서버와 같이 뜨니까, 이 명령들은 평소 부팅용이 아니라
중간에 마음을 바꿀 때 씁니다.

상태는 축이 **두 개**이고, 둘이 같이 보이는 건 정상입니다.

- **health** 는 하트비트와 준비 검사가 괜찮은지 답합니다.
- **lifecycle** 은 Keeper 프로세스가 살아 있는지 답합니다.

그래서 `running` 이면서 `stale` 일 수 있습니다. 프로세스는 살아 있고 하트비트가
늦다는 뜻이고, 죽은 프로세스와는 다른 문제입니다.

여럿을 한눈에 보기엔 터미널 UI 가 가장 빠릅니다. 명단은 Keepers 화면, 도구 호출과
턴 경계가 들어오는 대로 보이는 건 Acting 화면입니다.
[`docs/TUI-GUIDE.md`](TUI-GUIDE.md) 를 보세요.

## 하루가 도는 방식

작업은 `todo` → `in_progress` → `awaiting_verification` 을 거쳐
`done` / `dropped` / `blocked` 중 하나로 갑니다.

1. 누군가 작업을 만듭니다. 내가 TUI 입력줄에서 `/task <제목>` 으로 만들거나,
   Keeper 가 `masc_add_task` 로 만듭니다.
2. Keeper 가 그 작업을 집어 들고 턴을 돌기 시작합니다.
3. 파일 수정, 명령 실행, 보드 글로 결과가 쌓입니다.
4. 끝났는지는 검증이 판정합니다. 위 런타임에서는 일한 Keeper 가 아니라 **다른
   주체**가 했습니다. 보드 글을 가장 많이 쓴 둘이 `system` 과 `verifier_exact`
   였습니다.

보드가 이걸 다 보여줍니다. 그 런타임에는 글 2,670개와 댓글 1,639개가 쌓였고,
대부분이 기계가 쓴 것입니다. 이건 예상된 모습이고, 보드에 하나의 피드 대신
하위 보드와 검색이 있는 이유이기도 합니다.

## Gate

도구 호출이 사람 승인을 기다릴지는 **세 층**이 정합니다. 넓은 쪽에서 좁은 쪽으로
확인하고, 승인을 안 물어보는 이유는 이 중 아무 층이나 될 수 있습니다.

| 층 | 어디 있나 | 적용 범위 |
|---|---|---|
| 모드 | `gate/mode.json` | 런타임 전체 |
| Keeper 항목 | Keeper TOML 의 `always_allow` | Keeper 하나 |
| 상시 규칙 | `gate/always-allowed.json` | Keeper 하나 · 도구 하나 · 요청 모양 하나 |

상시 규칙은 자기가 어느 승인에서 나왔는지 기록합니다. 그래서 뜬금없어 보이는
규칙도 누가 언제 허용했는지까지 거슬러 갈 수 있습니다.

Gate 는 승인 절차입니다. 샌드박스도 아니고 자격증명 경계도 아닙니다.
`local` 프로파일은 내 컴퓨터에서 내 권한으로 그대로 돕니다.

## 뭔가 잘못됐을 때

| 보이는 것 | 대개 이런 뜻입니다 |
|---|---|
| 명단에 Keeper 가 없다 | TOML 로드가 실패했습니다. `instructions` 가 비었거나 모르는 키가 있으면 막고 멈춥니다 |
| 멘션이 안 닿는다 | `mention_targets` 한 칸에 구분자가 들어간 문자열이 통째로 있습니다 |
| 같은 사유 코드로 턴이 몰아서 실패한다 | 프로바이더 쪽 상태입니다 — 쿼터, 키, 요청 제한. 레인의 다른 후보를 보세요 |
| `running` 인데 `stale` 이다 | 프로세스는 살아 있고 하트비트가 늦은 겁니다. 죽은 게 아닙니다 |
| TUI 에서 `data unreliable` 옆에 `0` | 읽기가 실패한 겁니다. 목록이 비었다는 뜻이 아닙니다 |
| 고쳤는데 전부 옛날 값으로 보인다 | 경로가 둘입니다. `/health?full=1` 의 `effective_base_path` 와 `effective_masc_root` 를 확인하세요 |

`.masc/config/` 밖의 파일은 입력이 아닙니다. Keeper 스냅샷, 작업 저장소, 보드 로그,
영수증, 승인 기록은 서버가 씁니다. 손으로 고치면 아무도 서로 동의하지 않는 상태가
됩니다.

## 목적에 맞는 기억 회수

Keeper의 도구 목록에 `keeper_memory_select`가 있으면 `purpose`에
“현재 E17 production에 적용되는 승인 절차는?”처럼 질문이나 판단 목적을
전달합니다. 현재 일반 기억과 파일에 근거한 기억을 계보와 함께 평가합니다.
`keeper_memory_search`는 과거 기록을 명시적으로 찾는 경우를 포함한 텍스트
검색 도구로 유지됩니다.

개인 기억 안내는 정책이 허용하고 선택 도구가 직접 제공되거나, 제공된 탐색
도구와 활성 로더를 통해 불러올 수 있을 때 목적에 따른 선택을 안내합니다.
안내를 만드는 것만으로 선택을 호출하거나 저장된 문장을 주입하지는 않습니다.
그 외에는 실제 제공된 도구에 따라 기존 검색, 아티팩트 읽기 또는 회수 불가
안내를 유지합니다.

선택에는 `typesafeai.workspace_memory_selection_enabled`, 활성 TypeSafe 레인과
사용 가능한 목적지가 필요하며 Keeper 제외 설정도 적용됩니다. 결과는
`current_decision`과 `comparison`으로 구분됩니다. 비교용 기억은 원래 사건과
환경에 속하며 현재 사건의 상태를 입증하지 않습니다. 반환에는 현재 문장과
출처 식별자 또는 개수가 들어가고, 전체 과거 근거는 비공개 평가 기록에 남습니다.

변경됐거나 확인하지 못한 근거는 미해결로 남습니다. 선택 결과가 비어 있다고
관련 정책이 없다는 뜻은 아닙니다. 선택적인 양의 정수 `limit`은 평가 뒤에
적용되며 잘린 결과 수를 별도로 알립니다. 도구 호출은 해당 요청을 위해 기억을
회수하며 자동 프롬프트 주입을 켜지는 않습니다.

## 보고서를 아티팩트로 게시하기

대화 밖에서 다시 열어볼 보고서는 Keeper에게 아티팩트로 게시해 달라고
요청하세요. `keeper_artifact_publish`에 `title`, `summary`, `format`
(`markdown` 또는 `html`), 전체 `content`를 전달합니다. `task_id`와
`goal_id`를 함께 전달하면 해당 작업으로 연결됩니다. 작성자는 실행 중인
Keeper의 이름으로 기록됩니다.

대시보드의 **Work → Artifacts**에서 목록을 검색하고 문서를 열 수 있습니다.
문서는 화면 전체를 채워 열립니다. **목록으로** 버튼으로 돌아갈 수 있고,
**보고서 정보**를 펼치면 작성자와 연결된 작업을 확인할 수 있습니다.
미리보기, 원본 보기, 버전 선택, 링크 복사, 원본 다운로드를 제공합니다.
HTML에는 인라인 JavaScript와 CSS를 넣을 수 있습니다. 미리보기에서는
외부 스크립트 로딩과 fetch가 차단됩니다.

수정할 때는 문서 `id`와 최신 `expected_revision`을 교체할 내용과 함께
전달하세요. 오래된 버전으로 수정하면 거절됩니다. 이전 버전은 버전 링크로
계속 읽을 수 있습니다. 기존 파일은 Keeper나 인증된 운영자가 그 내용을
명시적으로 게시한 뒤 목록에 나타납니다.

[아티팩트 설계와 HTTP 규칙](design/report-artifacts.md)을 참고하세요.

## 이 숫자들의 출처

여기 적힌 수치는 전부 2026-08-25 에 **운영 중인 런타임 한 대**에서 읽은 것입니다.
Keeper 11개, `.masc` 하나. 그 런타임을 설명할 뿐이고 다른 환경을 보장하지 않습니다.
턴 수치는 `.masc/keepers/*/execution-receipts/`, 항목 수치는
`.masc/config/keepers/*.toml`, 보드 수치는 보드 JSONL 파일에서 셌습니다. 목표치로
삼기 전에 자기 경로에서 다시 세 보세요.

## 같이 볼 문서

| 문서 | 용도 |
|---|---|
| [`docs/KEEPER-IDENTITY-MANUAL.ko.md`](KEEPER-IDENTITY-MANUAL.ko.md) | Jira·Notion 같은 업무 서비스를 Keeper 에 붙이기 |
| [`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md) | Keeper TOML 항목 규칙 전체 |
| [`docs/TUI-GUIDE.md`](TUI-GUIDE.md) | 터미널 UI 화면과 키 |
| [`docs/ENV-CONTRACT.md`](ENV-CONTRACT.md) | 런타임이 읽는 환경 변수 |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | bearer 토큰과 대시보드 쓰기 권한 |
| [`README.ko.md`](../README.ko.md) | 설치, MCP 클라이언트 설정, 대시보드 |

`activation_mode`는 Keeper 실행 방식의 단일 설정입니다. `manual`은 owner를
자동 복구하지 않지만 명시적 요청이 들어오면 실행할 수 있습니다. `on_demand`는
시작 시 owner를 복구하고 요청을 기다립니다. `autonomous`는 여기에 주기 자율
턴을 허용합니다. 직접 메시지, 승인 후속 작업, 실행 시각이 된 예약은 모든 모드에서
요청 작업으로 처리하며, 운영자 일시정지와 shutdown 상태가 실행보다 우선합니다.
전역 `autonomous.enabled`는 자동 시작과 자발적 작업을 제어합니다.
실제 주기 설정은 `keeper.keepalive_interval_sec`입니다. 기상 힌트만으로 작업을
생성하거나 다음 주기 실행 시각을 다시 미루지 않습니다.

## Keeper가 바쁠 때의 예약 작업

실행 시각이 된 Keeper 예약은 요청된 작업입니다. 대화가 계속 Owner 슬롯을
차지한다는 이유로 예약을 무기한 대기시키지 않습니다. 현재 턴은 도구 처리가
끝난 경계에서 체크포인트를 보존하고, Owner는 채팅 후속 작업이 슬롯을 다시
차지하기 전에 정확한 대기 예약 입력에 턴을 넘깁니다. 도구 없이 자연스럽게
끝나는 채팅도 다음 슬롯에서 대기 예약을 처리할 기회를 남깁니다. 실행 중인
도구를 중단하거나 이미 수행한 효과를 다시 실행하는 방식은 아닙니다.

이 인계는 한 턴의 슬롯 우선권이며 Job 완료를 뜻하지 않습니다. 입력을 받는
시점에 원래 큐 항목의 identity를 다시 확인합니다. 철회되거나 교체된 입력은
이전 항목의 우선권을 물려받지 않으며, 오래된 인계 예약은 채팅 진입을 막지
않도록 해제합니다. 현재 턴이 이미 받은 예약은 새 입력으로 보지 않습니다.
일시정지·shutdown과 원본 저장소의 조회 가능 여부는 계속 적용됩니다.

예약 지연을 조사할 때는 정확한 schedule ID의 조회를 확인하세요.
`/api/v1/dashboard/scheduled-automation?schedule_id=<id>`에서 다음을 구분합니다.

- `last_wake.detail`은 전달 당시의 접수 기록입니다. enqueue나 그 안의
  `awaiting_ack`만으로 현재 소비 여부를 판단할 수 없습니다.
- `keeper_queue_evidence`는 현재 대기·소비 관측을 schedule instance,
  해당 실행의 예정 시각과 payload digest에 결속합니다.
- `keeper_reaction_evidence`는 턴 시작·종료와 큐 ACK를 구분합니다.
- `runner_hold.reason.kind=previous_occurrence_unconsumed`는 이전 wake가 아직
  소비되지 않았다는 뜻입니다. 반복 예약의 다음 실행을 중복 생성하지 않고
  보류합니다.

정상 heartbeat나 runner만으로 특정 입력의 진행을 증명할 수 없습니다. 그 입력의
진입부터 종단 영수증까지 확인하세요. 다음 시각을 정상처럼 보이게 만들려고 큐를
비우거나 ACK를 만들어 넣지 않습니다.

## Goal 일시정지와 재개

[Goal 상태 제어](guides/GOAL-LIFECYCLE.md)에서 Pause/Resume과 Block/Unblock을
설명합니다. Goal 진행과 새 검증 작업의 진입을 중단하며, 연결된 Task와 다른
Keeper 턴은 각자의 상태에 따라 계속 진행됩니다.

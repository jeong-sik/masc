verdict: PASS head: aa0e05f6fcdfb4d0e5d35650dbbe07f169515971 by: bidi_partial_failure_response

# Firefox environment boundary — focused SOURCE review

**제기된 P1 후보(삭제된 Keeper Firefox 정제로 인해 Addon 소유 Firefox가 host credential 환경을 통째로 상속)는 이 고정 source의 실제 production 경로에서 확인되지 않았다.** 정제는 Firefox 함수 내부가 아니라 **host→Browser worker 최초 spawn 경계**에서 수행된다. 이후 launcher/guardian/Firefox는 이미 정제된 worker 환경을 상속한다. `Env_keeper_scrub.filter_environment`와 동일한 함수 호출은 아니지만, provider/admin/arbitrary host credential 전달을 막는 닫힌 허용목록 경계가 존재하며 이 목적에서는 더 좁다.

이 판정은 정확히 이 환경 전달 경로의 SOURCE 판단이다. whole67 승인, restack 전체 검토, 현재 head의 컴파일/시험, 실제 Firefox/Linux desktop 동작, 설치·배포 또는 sandbox 보장을 뜻하지 않는다.

## Identity / 원래 finding

- 전달받은 원문 `/tmp/masc-addon-goal-resume-20261021/browser-updater-completion-original-20261022.json`을 전체 읽었다. 원문의 표현은 미해결 **후보**였고 실제 유출을 입증한 로그가 아니었다.
- 단일 REST 재확인: #44702 open/unmerged, head `aa0e05f6fcdfb4d0e5d35650dbbe07f169515971`, branch `fix/browser-download-abandon-grants-1021`, 직접 base `b87f298f358597fd2f95239c9eb49da7a6442793`.
- #44532는 merged, merge commit `b8a67b6ac7b9823f426632cc204700ee1adbeba8`, 원래 head `5a7b2cc5a8e263d9e2d952423299e731a05b0638`임을 REST로 직접 확인했다.
- 원래 `browser_keeper_firefox.ml`과 `server_browser_keeper_firefox.ml`은 #44532 merge tree와 restack trunk `003f52e2`에서 각각 동일 blob이다(`d2480885655c88afa8cf8a5db0162f18d1f6806d`, `7f315cc1162996cd21ef3d050dc02e6f8097f6f8`). 따라서 원래 보호 경계를 과거 기억이나 별도 main6f68 tree에서 추정하지 않았다.
- 정확한 aa source의 constitution blob은 기존에 읽은 것과 같은 `37fa3b34f4089dee0796c9e22b14b705234ca740`다. git show/명명 경로/필요한 REST source만 읽었다. 로컬 missing Runtime blob은 contents API에 exact aa ref를 주어 읽고 `/tmp/masc-addon-goal-resume-20261021/firefox-env-fixed-source/lane_addon_runtime.ml`에 snapshot을 보존했다. 다른 worktree의 branch·rebase·refs·source·runtime는 바꾸지 않았다.

## 삭제되기 전 정확한 보호 경계

`b8a67b6a:lib/browser_keeper_firefox.ml:15–34`의 `firefox_environment`는 `Env_keeper_scrub.filter_environment inherited` 뒤 desktop session 이름만 덧붙였다. `b8a67b6a:lib/server/server_browser_keeper_firefox.ml:234–240`의 `start_firefox`가 **실제 spawn_logged의 명시적 `~env`**에 이 결과를 전달했다. 이것이 #44532의 실제 sink 보호였다.

`Env_keeper_scrub`는 process/runtime exact allowlist와 HTTP(S)_PROXY userinfo scrub을 제공했다. 따라서 이 module 삭제를 보고 후보를 제기한 것은 타당한 확인 질문이었다. 다만 aa에서는 old server starter 경로 자체가 없어지고 Browser worker 소유 실행으로 이동해, Firefox spawn 한 줄에서 같은 함수가 보이지 않는 것만으로 유출을 확정할 수 없다. named tree 조회에서도 old Keeper module/record/server module ML/MLI가 존재하지 않는 것을 확인했다.

## 실제 production chain 직독

| 경계 | 고정 aa source와 실제 전달 |
|---|---|
| Browser package 선택 | `addons/browser/lane.toml:4–6`: `runtime="host_process"`, `service="browser"`, executable `masc-browser-addon-worker`. `lane_addon_manifest.ml:132–139,346–358`은 이를 typed `Browser_service`로 decode하고 native execution 등 계약을 검증한다. |
| **host 환경 정제** | `lib/lane_addon/lane_addon_runtime.ml:1355–1357`: Browser_service이면 `Some (Browser_addon_environment.project (Unix.environment ()))`; generic Mcp_tools는 None. **Browser 서비스가 generic None 분기로 빠지는 구성은 아니다.** |
| 정제 결과 전달 | 동일 Runtime `:1486–1489`: `Lane_addon_native_worker.start ... ?env ...`. 앞에서 만들어진 array를 그대로 전달한다. |
| Native launcher의 실제 spawn | `lane_addon_native_worker.ml:76–91,97–99,141–143`: optional env를 검사하고 `Agent_core.Mcp.connect ... ?env`로 전달한다. |
| MCP transport forwarding | exact tree의 `packages/agent_core/lib/protocol/mcp.ml:74–92`: `connect`는 `Eio.Process.spawn ... ?env`를 직접 호출한다. **이 경로는** 같은 파일의 별도 `connect_and_load/merge_env` 경로가 아니므로 전체 host environment와 재병합하지 않는다. `.mli:91–102`도 explicit array API다. |
| native admission exec | `bin/masc_native_addon_launcher.ml:2–8` → `native_addon_lease.ml:341–363`: 원래 admission/claim을 검증한 뒤 `Unix.execvpe ... (Unix.environment ())`. 이때의 process는 이미 scrub된 환경으로 spawn된 launcher다. host/server process의 환경을 조회하는 것이 아니다. |
| Browser worker 진입 | `bin/masc_browser_addon_worker.ml:71–76`: 선택된 owned Live/BiDi backend를 worker 안에서 `Browser_addon_live_bidi.run`으로 호출한다. worker는 host credentials를 다시 구성하거나 env를 복원하지 않는다. 설정은 allocation 안의 별도 descriptor로 받는다. |
| Firefox owner launcher | `browser_addon_live_bidi.ml:187–194`: `launcher --instance ... --slot ... -- guardian ... -- firefox --no-remote --profile ... --remote-debugging-port ...`를 worker에서 spawn한다. 명시적 env 추가는 없으므로 **이미 scrub된 worker의 환경**을 상속한다. `.mli`의 `env:Eio_unix.Stdenv.base`는 Eio 자원/프로세스 manager 값이며 server의 raw string-array 환경을 다시 전달하는 API가 아니다. |
| guardian → Firefox sink | `bin/masc_browser_process_owner.ml:8–13` → `lib/browser_process_owner/browser_process_owner.ml:40–65`: guardian은 해당 inherited process 안에서 original Firefox child를 `Eio.Process.spawn`한다. 여기서도 host env 재주입은 없다. spawn manager `posix_spawn_process_mgr.ml:220–249`는 받은 env array를 실제 posix_spawn에 전달한다. |

로컬 설치 Eio의 `process.mli:97`도 `env` 생략의 의미를 “same as parent process”로 명시한다. 이는 이번 proof의 환경 상속 의미를 읽기 위해 확인한 API 문서이며 새 빌드 결과가 아니다.

## 닫힌 허용목록의 실제 내용과 비교

`Browser_addon_environment.ml:1–17`과 `.mli`를 전체 읽었다. key를 첫 '='에서 분리하고 닫힌 exact match에 없는 모든 항목/잘못된 entry를 버린다. host array를 수정하지 않는다.

남기는 것은 PATH/HOME/temp, USER/LOGNAME, 제한된 locale/TZ, EIO_BACKEND, XDG config/data/cache/runtime 경로, DISPLAY/WAYLAND_DISPLAY/XAUTHORITY, SSL certificate 및 Fontconfig 경로다. 따라서:

- `OPENAI_API_KEY`, 기타 provider key, `MASC_ADMIN_TOKEN`, `MASC_INTERNAL_MCP_TOKEN`, token-bearing MASC/dashboard URL 등 **이름을 일일이 blacklist하지 않아도 전부 미허용**이다. 임의의 새로운 credential name도 자동으로 통과하지 않는다.
- raw HTTP_PROXY/HTTPS_PROXY를 전달하지 않아 proxy userinfo가 Firefox에 재유입되지 않는다. old scrub 함수의 redaction 결과를 전달하는 것과 동작은 다르지만 credential 유출 회귀는 아니다.
- old Keeper runtime용 MASC_* 설정, Docker 접속키, editor/terminal/OPAM 관련 항목도 Browser 서비스에는 전달하지 않는다. 브라우저 설정은 host-selected descriptor에서 공급된다.
- DBUS_SESSION_BUS_ADDRESS는 의도적으로 제외돼 있다(주석도 secret-service 접근 경계를 명시). old desktop list의 이 값을 유지하기 위해 전체 env를 되살린 흔적은 없다.
- 원래 HOME/PATH/display 경로가 남는다는 사실은 동일 사용자 파일/desktop 접근 자체를 격리하지 않는다. `.mli`도 “not an operating-system sandbox”라고 명시한다. 이 감사의 PASS는 **host 환경변수 material의 상속 제한**에 한정한다. 모든 개인 credential 접근이나 malicious native code 격리를 입증하지 않는다.

새 함수를 old Keeper 함수로 단순 교체하면 오히려 Browser에 필요 없는 MASC/Docker/기타 runtime 환경을 다시 허용할 수 있다. 현재 후보만을 근거로 그 변경을 요구할 이유는 없다.

## 기존 회귀 source / 아직 없는 실행 증거

`test/test_lane_addon_native_runtime.ml:175–186,242–248,288–297`을 직접 읽었다. 이 fixture는 fake host provider sentinel과 임의 unknown-secret sentinel을 실제 부모 환경에 설정하고, Runtime이 시작한 실제 native worker 및 그 worker가 낳은 별도 child에서 모두 **key 부재**를 확인한다. PATH/LANG/EIO_BACKEND 보존과 원래 host의 provider key 유지도 검사한다. 즉 순수 allowlist 함수만 검사하는 것은 아니며 원래 Native/MCP forwarding 경계를 타는 시나리오가 source에 있다.

다만 이 child는 scripted Python child다. `test_browser_addon_live_bidi.ml`의 실제 guardian+scripted Firefox endpoint fixture도 읽었으나 그 파일은 환경 sentinel 검사를 추가로 하지 않는다. 따라서 이번 exact aa head에서 실제 guardian/Firefox content process 환경을 실행해 재확인했다고 부르지 않는다. 과거 다른 SHA의 runtime/browser 결과를 현재 head 실행 PASS로 이월하지 않았다.

추가 실행/CI/Docker/live환경 조회는 요청하거나 수행하지 않았다. generic Mcp_tools의 환경 정책, externally owned WebExtension browser, standalone 저수준 backend API를 server 프로세스에서 임의 직접 호출하는 새 소비자, 다른 sandbox/security 요구는 이 후보의 실제 Browser_service 경로와 별개이며 이번 좁은 판정 범위가 아니다.

## 결론

원래 삭제된 `firefox_environment`의 secret 제한 목적은 aa의 **Runtime Browser_service → explicit projected env → Native/MCP launcher → worker → original guardian → Firefox** 경로에서 유지된다. 이 정확한 후보에서 host credential이 raw 상속되는 실행 sink를 발견하지 않았다. 제기된 P1은 SOURCE 조사로 비재현/미확정이며 이를 막기 위한 제품 수리 필요성을 확인하지 않았다. whole restack·빌드·실제 Firefox 환경 실측의 PASS로 확대하지 않는다.

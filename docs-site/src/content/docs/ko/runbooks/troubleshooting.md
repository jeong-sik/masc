---
title: 문제 해결
description: 첫 실행과 운영에서 흔한 문제와 해결법입니다.
---

## `masc: command not found`

바이너리는 `~/.local/bin` 에 설치되는데, 갓 설치한 기기에서는 이 경로가 `PATH` 에
없는 경우가 많습니다. 셸 시작 파일에 추가하고 다시 불러오세요.

```bash
# zsh (macOS 기본)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

자세한 건 [빠른 시작](/ko/getting-started/quickstart/)의 PATH 단계를 보세요.

## 서버가 앞단에 머무르지 않고 시작하자마자 꺼짐

서버는 꺼지기 전에 이유를 찍습니다 — 마지막 줄을 읽어 보세요. 흔한 원인은
`[runtime].default` 가 완전히 정의되지 않은 `<provider>.<model>` 쌍을 가리키는
경우입니다(바인딩 누락, 또는 바인딩이 선언하지 않은 dispatch 한도). `<base-path>/
.masc/config/runtime.toml` 에서 그 쌍을 고치거나, 설치 마법사를 다시 돌려 준비된
소스를 고르세요. 필요한 모양은 [설정 파일](/ko/reference/config/)에 있습니다.

## 8935 포트가 이미 사용 중

다른 인스턴스(또는 다른 프로그램)가 기본 포트를 잡고 있습니다. 찾아서 멈추세요.

```bash
lsof -i :8935
kill <PID>
```

또는 다른 포트로 켜고 TUI 도 같은 포트로 맞추세요.

```bash
masc --base-path ~/masc --port 8936
masc-tui --base-path ~/masc --port 8936
```

## `masc-tui` 에 Keeper 가 안 보이거나 다른 작업 공간이 보임

`masc-tui` 는 `--base-path`(기본값: `MASC_BASE_PATH` 또는 현재 디렉터리)에서 작업
공간을 읽습니다. 새 터미널은 홈 디렉터리에서 시작하니, 서버를 켤 때 쓴 것과 같은
base-path 를 넘기세요: `masc-tui --base-path ~/masc`.

## Keeper 가 안 뜸

Keeper 는 명령 격리가 필요하고, MASC 는 허용된 `sandbox_profile` 없이는 Keeper 를
띄우지 않습니다. Docker 를 설치하거나 Apple Silicon 이면 `container` CLI 를 설치한
뒤 프로필을 지정하세요 — [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요. 웹
검색이나 `git push` 를 하는 Keeper 는 `network_mode = "inherit"` 도 필요합니다.
기본값 `none` 은 게스트에 네트워크를 주지 않습니다.

## 프로바이더 rate limit

프로바이더가 rate-limit 오류를 주면, MASC 는 그 역할에 등록된 다른 바인딩으로
failover 할 수 있어 진행 중인 Keeper 턴을 버리지 않습니다. 대체 슬롯을 해당 lane 에
더 넣어 설정하세요([설정 파일](/ko/reference/config/) 참고).

## TUI에 "reconnecting..." 이 반복되거나 서버 응답 지연이 길어짐

TUI에 `reconnecting...` 배너가 반복되거나 서버 지연이 튀는 경우, Eio 메인 도메인의
스케줄러가 차단성 시스템 콜 또는 대규모 GC로 인해 늦게 깨어나는 현상일 수 있습니다:

1. 서버 헬스 엔드포인트에서 스케줄러 지연 및 GC 상태 확인:
   ```bash
   curl -s http://127.0.0.1:8935/health | jq '{scheduler: .scheduler, gc: .gc}'
   ```
   `.scheduler.stalls_ge_1s`(1초 이상 스톨 횟수) 및 백분위 링(`p50`, `p95`, `p99`, `max`)을
   확인하세요. `max`가 높다면 메인 도메인의 락 획득 지연이 발생한 것입니다.

2. 실시간 스케줄러 지연 프로브 실행:
   ```bash
   MASC_URL=http://127.0.0.1:8935 scripts/harness/perf/scheduler_lag_probe.sh
   ```
   실행 중인 서버에 실시간으로 붙어 최근 1분간의 링 버퍼 지연율과 `Gc.quick_stat` 누적
   카운터를 통해 라이브 힙을 순회하지 않고도 초당 할당량(MB/s)과 GC 빈도를 진단합니다.

## 힙 메모리 급증 진단 (`heap-roots`)

서버 프로세스의 메모리 사용량이 예상보다 비정상적으로 높을 때:

```bash
curl -s http://127.0.0.1:8935/api/v1/diagnostics/heap-roots | jq .
```

이 진단 엔드포인트는 가비지 컬렉터의 라이브 힙 루트를 조사하여, 어떤 모듈·큐·캐시가
메모리를 점유하고 있는지 식별합니다.


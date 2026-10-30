# Librarian pass 하나의 비용 (2026-10-27)

새로 읽을 내용은 210바이트로 같게 두고, Keeper 가 이미 읽은 대화 크기만 1, 5, 20 MB 로 바꿨다. pass 하나의 할당과 저장 크기는 이미 읽은 대화 크기에 정비례했다. 읽을 양과는 상관이 없었다.

이슈 #46359 의 측정이다.

## 결과

| 이미 읽은 대화 | checkpoint 파일 | pass 할당 | 저장 | 가장 큰 기록 | 걸린 시간 | 프로세스 최대 RSS |
|---|---|---|---|---|---|---|
| 1 MB | 1,054,694 B | 2.01 GB (1,906배) | 6.8 MB (6.5배) | 2.2 MB | 3.4 s | 140 MB |
| 5 MB | 5,269,606 B | 8.34 GB (1,582배) | 32.3 MB (6.1배) | 10.7 MB | 9.3 s | 391 MB |
| 20 MB | 21,075,526 B | 32.93 GB (1,562배) | 127.8 MB (6.1배) | 42.6 MB | 32.0 s | 1,334 MB |

괄호 안은 checkpoint 파일 크기에 대한 배수다. 원문은 `passes.jsonl`(측정 프로그램 출력)과 `time-<MB>.txt`(`/usr/bin/time -l` 출력)다.

## 조건

- 소스: `fbf2f55ae0a`. 2026-10-27 12:01 KST 에 기동한 라이브 서버와 같은 커밋이다. #46244(끝난 체인 settle)는 들어 있고 #46247(gate 사본 제거)은 없다.
- 장비: M3 Max 16코어. 같은 시간에 라이브 서버와 다른 코딩 세션이 돌았다. 시간과 RSS 는 이 부하의 영향을 받는다. 할당과 저장 크기는 받지 않는다.
- 프로그램: `test/bench_keeper_librarian_pass.ml`. `test_keeper_librarian_durable_execution.ml` 의 fixture 를 그대로 쓴다. production durable queue, 설정한 Runtime, Python 작업자(`addons/keeper-librarian/server.py`), 공용 Exact HTTP 경로, gate 와 Memory 반영까지 실제 코드가 돈다. container 실행만 테스트 backend 로 바꿨다.
- 대화: 16 KiB 짜리 질문·답 쌍을 크기만큼 쌓았다. 반복되지 않는 문장이다. 첫 pass(baseline)로 이 대화를 읽은 것으로 표시한 뒤, 질문 하나와 답 하나(210 B)를 더하고 pass 하나를 잰다.
- 실행: `_build/default/test` 에서 크기마다 따로 `./bench_keeper_librarian_pass.exe <MB>`. 한 프로세스에 한 크기만 돌려 앞 실행의 힙이 섞이지 않게 했다.
- 빌드: fixture 가 읽는 파일도 `_build` 로 복사해야 해서 실행 파일과 함께 빌드한다.

```sh
dune build --root . ./test/bench_keeper_librarian_pass.exe \
  $(git ls-files addons/keeper-librarian | sed 's#^#./#') \
  ./addons/protocol.py ./addons/exact_worker.py \
  ./config/prompts/librarian.md ./config/prompts/keeper.md
```

## 무엇을 쟀나

- **pass 할당**: `drive_advanced` 앞뒤의 `Gc.quick_stat` 차이(`minor_words + major_words - promoted_words`, 8바이트 word). 이 fixture 에서 pass 는 한 domain 과 그 systhread 에서 돈다. Python 작업자는 다른 프로세스라 빠진다.
- **저장**: pass 앞뒤 `lane-addons` 디렉터리 파일 크기 합의 차이.
- **프로세스 최대 RSS**: fixture 준비와 대화 생성까지 포함한 프로세스 전체 값이다. pass 만의 값이 아니다.

## 읽는 법

- 저장이 checkpoint 의 약 6배인 것은 #46359 에 적은 구조와 맞다. capture 안에 같은 대화가 네 번 들어가고(checkpoint 원문, 다시 인코딩한 메시지, trace 조각, 모델 입력), 그 capture 가 history 기록과 gate 기록에 한 번씩 더 들어간다.
- 할당이 checkpoint 의 약 1,600배인 것은 같은 기록을 여러 번 인코딩·digest·검증·다시 읽기 때문으로 본다. 어느 단계가 몇 배인지는 이 측정에서 나누지 않았다.
- 라이브 Keeper 에 대입하면 이렇다(추정이다). checkpoint 가 5 MB 인 Keeper 는 턴이 끝날 때마다 pass 하나에 약 8 GB 를 할당하고, pass 동안 수백 MB 를 쥔다. Librarian lane 은 Keeper 마다 하나라서, 300명이 동시에 pass 를 돌면 동시에 쥐는 양이 Keeper 수만큼 곱해진다.

## #46247 을 얹었을 때

#46247(gate 기록에서 capture 사본을 빼고 digest 로 가리킴)의 변경을 `fbf2f55ae0a` 위에 그대로 적용해(`git diff 76735b8794b 2239524eea7 -- lib test`, 충돌 없음) 같은 프로그램을 돌렸다. 그 빌드에서 `test_keeper_librarian_durable_execution` 23개가 통과했다. 원문은 `with-46247/`.

| 이미 읽은 대화 | pass 할당 (전 → 후) | 저장 (전 → 후) | 시간 (전 → 후) | 프로세스 최대 RSS (전 → 후) |
|---|---|---|---|---|
| 1 MB | 2.01 → 1.51 GB (−25%) | 6.8 → 2.3 MB (−66%) | 3.4 → 1.8 s | 140 → 125 MB |
| 5 MB | 8.34 → 6.16 GB (−26%) | 32.3 → 10.8 MB (−66%) | 9.3 → 6.9 s | 391 → 320 MB |
| 20 MB | 32.93 → 24.28 GB (−26%) | 127.8 → 42.7 MB (−67%) | 32.0 → 28.8 s | 1,334 → 1,004 MB |

- 저장은 3분의 1 로 줄었다. gate 기록에 들어가던 capture 사본이 빠진 만큼이다.
- 할당은 4분의 1 만 줄었다. 할당은 여전히 checkpoint 의 약 1,150배이고, 대화 크기에 정비례하는 모양은 그대로다. 남은 몫은 #46359 의 capture 안 중복과 같은 기록을 여러 번 인코딩·검증하는 비용이다.

## L2(#46394)와 L3(#46397)

같은 main 커밋 `6d0658cfbd0` 위의 두 층을 쟀다. 소스 `test/` 에서 `../_build/default/test/bench_keeper_librarian_pass.exe` 로 돌렸다. 원문은 `l2-46394/`, `l3-46397/` 이다.

- L2(`7d74a6979af`): 형식은 그대로 두고, 커밋 중 같은 original 을 다시 확인할 때 digest 로 비교한다.
- L3(`28c15691f63`): original 이 읽은 범위를 input 에 한 번만 담고, 출처는 `{count, digest}` 로 가리킨다. 하드컷이다.

**읽을 내용 210 B**

| 이미 읽은 대화 | pass 할당 (#46247 → L2 → L3) | 저장 (L2 → L3) | 시간 (L2 → L3) |
|---|---|---|---|
| 1 MB | 1.51 → 0.97 → 0.12 GB | 2.3 MB → 166 KB | 1.4 → 0.32 s |
| 5 MB | 6.16 → 3.88 → 0.18 GB | 10.8 MB → 166 KB | 5.2 → 0.32 s |
| 20 MB | 24.28 → 15.20 → 0.38 GB | 42.7 MB → 166 KB | 18.3 → 0.83 s |

L3 의 저장은 대화 크기와 상관없다. 할당은 고정분 약 107 MB 에 checkpoint 1바이트당 약 13바이트다.

**이미 읽은 대화 5 MB, 읽을 범위를 키움** (`5:<MB>` 인자)

| 읽을 범위 | pass 할당 | 저장 | 시간 |
|---|---|---|---|
| 1 MB (L2) | 5.77 GB | 18.2 MB | 6.5 s |
| 1 MB (L3) | 1.81 GB | 3.33 MB | 1.9 s |
| 2 MB (L3) | 3.47 GB | 6.50 MB | 3.2 s |
| 3 MB (L3) | 4.16 GB | 9.66 MB | 4.4 s |

- L3 에서 1 MB 범위의 저장 3.33 MB 는 셋으로 나뉜다. history original 1.14 MB, 공용 Exact 실행기의 `exact-requests` 1.09 MB, `host-results` 1.09 MB 다(#46399).
- 읽을 범위 4 MB 이상(`5:4`, `5:5`)은 L2 와 L3 모두 모델을 부르지 못하고 "Original history host terminal is absent" 로 끝났다(#46398). 그래서 표에 없다.

## 이 측정이 말하지 않는 것

- 300명 서버 전체의 메모리 정점. 이 프로그램은 Keeper 한 명, pass 하나만 돈다.
- 실제 모델의 응답 시간이나 container 작업자의 비용.

# 요청의 앞부분만 받은 provider 가 응답하는지 (2026-11-12)

[RFC-0492](../../rfc/RFC-0492-provider-connections-are-reused-from-one-process-cache.md) §6 시험 5 의 실행 기록이다. 정정이나 재측정으로 이 폴더를 바꾸지 않는다. 새 측정은 새 폴더에 둔다.

- 날짜와 시각은 UTC 다. 이 폴더가 든 branch 의 base 는 `origin/main` `4ae17976a4a2` 다.
- 요청은 `glm-coding`(`api.z.ai`)과 `openrouter`(`openrouter.ai`)로 보냈다. 운영자가 두 provider 에 보내도 된다고 승인했다. `ollama_cloud` 는 운영자가 한도에 막혀 있다고 해서 보내지 않았다.
- 키는 환경 변수 `ZAI_API_KEY` 와 `OPENROUTER_API_KEY` 에서 읽는다. 스크립트는 키를 출력하지 않는다.
- 모델은 `glm-5.3-flash` 와 `nvidia/nemotron-3.5-super-vl:free` 다. 본문은 메시지 하나(`"ok"`), `max_tokens` 8 이다. 본문 크기는 glm 92바이트, openrouter 112바이트다.

## 재현

```
python3 -I glm_partial.py quota | run | control-fin | stall
python3 -I openrouter_partial.py control | stall
```

두 스크립트는 외부 provider 에 실제 요청을 보낸다. 운영자 승인을 받고 돌린다. 출력은 표준 출력뿐이고 파일을 쓰지 않는다. 스크립트가 TLS 위에서 요청을 직접 쓰고(`ssl.MemoryBIO`), 연결을 FIN 으로 닫는 방식과 닫지 않고 기다리는 방식을 가른다.

## 읽은 값

| 실행 | 시각 | 보낸 것 | 결과 |
|---|---|---|---|
| glm `run` 의 정상 요청 | 07:35Z | 요청 전체 | 200, 본문에 `usage`, 2.2초 |
| glm `run` 의 부분 요청 4건 | 07:35Z | 본문 0·1·46·91/92바이트, TCP FIN(TLS close_notify 없음), 읽기 방향은 열어 둠 | 모두 응답 0바이트, 0.0초에 닫힘 |
| glm `control-fin` | 07:43Z | 요청 전체, 그다음 FIN | 응답 0바이트, 0.0초에 닫힘 |
| glm `stall` 2건 | 07:49~07:51Z | 본문 46·91/92바이트, FIN 없이 연결을 열어 두고 기다림 | 둘 다 60.0초 뒤 서버가 응답 0바이트로 닫음 |
| openrouter `control` | 07:59Z | 요청 전체 | 200, 본문에 `usage`, 0.5초 |
| openrouter `stall` 2건 | 08:00~08:01Z | 본문 56·111/112바이트, FIN 없이 기다림 | 둘 다 15.1초 뒤 서버가 RST 로 끊음, 응답 0바이트 |

- 200, completion, 408 은 부분 요청 어디에서도 오지 않았다.
- 요청을 모두 보낸 뒤 FIN 만 보내도(`control-fin`) glm 은 응답 없이 닫았다. FIN 으로 닫는 방식은 침묵이 요청이 불완전해서인지 FIN 때문인지 가르지 못한다. 그래서 `stall` 을 썼다.
- 보낸 요청은 glm 8건(정상 1, FIN 부분 4, FIN 대조 1, `stall` 2)이고 openrouter 4건(정상 1, `stall` 3)이다.

## 읽을 때의 한계

- `stall` 은 클라이언트가 멈춘 경우다. 연결이 RST 나 FIN 으로 끊기는 경우는 보지 못했다. 끊기는 쪽은 `control-fin` 이 보였듯 요청이 온전해도 침묵이라 가르지 못한다.
- 사용량이 생기는지는 재지 못했다. glm 의 사용량 창은 정수 퍼센트(`TOKENS_LIMIT` 93%)이고, 정상 요청 1건도 값을 못 움직였다(`glm-run-20261112.log`). openrouter 는 무료 모델이라 사용량이 0 이다. 서버가 요청을 처리하고 응답만 버렸을 가능성은 배제하지 못한다.
- 닫힌 시각이 다르다. glm 은 60초에 FIN, openrouter 는 15초에 RST 다. 서버 앞단의 대기 정책으로 보이지만 어느 계층인지는 확인하지 않았다.
- openrouter 첫 `stall` 시도는 서버의 RST 를 스크립트가 처리하지 못해 죽었다. 그 시도가 응답을 받았는지 기록이 없어서 스크립트를 고치고 2건을 다시 보냈다. 이 시도의 로그는 traceback 에 로컬 경로가 있어 올리지 않았다. 예외는 `ConnectionResetError: [Errno 54] Connection reset by peer` 이고 시작 15초 뒤에 났다.
- `openrouter-stall-20261112.log` 의 `first byte at` 은 TLS 핸드셰이크 바이트까지 세므로 응답이 온 시각이 아니다. 응답 바이트 수는 `response N bytes` 가 맞다.
- 사용량 창의 값은 운영자 계정의 것이다.
- 한 장비, 한 시점의 값이다. 요청 하나씩 5건 이하라서 서버의 변동은 재지 못했다.

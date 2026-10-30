# Board 댓글 폭 비교

같은 합성 fixture와 실측 242×41 터미널에서 비교했다. 작성자는 `wkbl-reader`, 본문은 열 번 반복한 한국어 문단이다. 원래 screenshot의 운영 데이터를 재사용하지 않는다.

| 항목 | 수정 전 | 수정 후 |
|---|---|---|
| source commit | `65562ff5f7567f9b3a3b2c2b466d556d368d85ba` | `40ebc2634e418770ca10eb7065a561cd5c6005a1` |
| 실행 파일 SHA256 | `198037a1354a3e565f5ec7d474e1b2579fa637a5b3d31fae2e8ca124633e765f` | `60f681e0321af93e26ca87c335df6056388471ad0b8d5b5cc8d3bb59decc0ef1` |
| 실행 | native 기준 바이너리 | Linux CI 바이너리 / Ubuntu 22.04 amd64 Docker |
| 화면 | [before](board-comparison-before/board-detail-240.png) | [after](board-comparison-after/board-detail-240.png) |
| terminal text | [before](board-comparison-before/board-detail-240.txt) | [after](board-comparison-after/board-detail-240.txt) |

수정 전에는 댓글을 작성자 옆의 잔여 폭으로 감싼 뒤 아래 행에 배치해 52행이 된다. 수정 후에는 댓글 영역 전체 폭으로 감싸 21행이 된다. source-bound fixture 실행 증거이며 운영 반영, 모든 TUI 화면 검증, 전체 PR checks의 성공을 뜻하지 않는다. 화면 오른쪽 observer 오류는 fixture API 부재다.

수정 파일은 [probe run 36648531190](https://github.com/jeong-sik/masc/actions/runs/36648531190)의 artifact `linux-x64-probe-40ebc2634e418770ca10eb7065a561cd5c6005a1-attempt-1` (artifact ID `11069774380`)에서 받았다. SHA256SUMS의 네 실행 파일을 검사했고 `masc_tui.exe --build-commit`을 확인했다. 캡처 뒤 TUI SHA256을 다시 계산해 manifest와 대조했다.

당시 Docker image ID는 Ubuntu `sha256:b8b6ee6aa931ecd9d0d952abc34dc0e5f7c6a30c6bb71b079fe399fde0329c02`, proxy `sha256:1b0e598b21b7f5232c16b23d4c9846cb8bd13a24128301140441a10d04bb5535`다. source artifact와 fixture는 같지만 native와 Docker의 timezone이 달라 metadata 시각은 각각 09:00과 00:00으로 표시된다. 시각 표시의 차이를 이 PR의 변경 효과로 해석하지 않는다.

## 캡처 재현

`scripts/capture-tui-audit.py`는 Playwright Chromium, PATH의 ttyd(또는 `--ttyd`)와 Python fixture helper가 필요하다. 직접 실행할 native TUI 바이너리만 받는다. `--binary-file`을 사용하면 같은 파일이어야 하며 wrapper가 다른 artifact를 대신 증명하지 않는다. Linux artifact는 Linux 안에서 capture 도구·Chromium·ttyd와 함께 실행한다.

```sh
python3 scripts/capture-tui-audit.py /path/to/masc_tui.exe \
  --out /tmp/board-comparison-new --board-only --author wkbl-reader
```

새 도구는 과거 fixture와 달라졌으며 아래 Docker driver를 다시 실행하는 방법이 아니다. 과거 before/after manifest에 새 provenance나 artifact hash 보증을 소급 적용하지 않는다. 새 비교는 양쪽 바이너리를 같은 새 fixture와 같은 native 실행 환경에서 실행해 별도 디렉터리에 저장한다.

캡처 당시 실제 [driver 원문](board-probe-driver.sh.txt)과 [proxy 원문](board-fixture-proxy.py.txt)을 보관한다. driver SHA256은 after manifest의 `driver_sha256`이다. 원문에 적힌 `/tmp` 경로는 당시 artifact/proxy 위치이며 재현 시 준비한 위치로 바꿔야 한다. proxy image `masc-test-tool-matrix:fixture`는 당시 호스트의 Python 3.11.2 포함 image다. 해당 image도 필요하다. 재현 환경을 준비하지 않은 상태에서 이 원문을 곧바로 실행할 수 있다고 주장하지 않는다.

TUI는 `--host` 옵션 없이 loopback으로 HTTP에 연결한다. 전용 proxy container가 같은 port의 loopback을 host fixture로 전달하고 TUI container가 그 network namespace를 공유한다. 임시 fixture workspace만 연결하며, 종료 시 driver가 자신이 만든 proxy를 삭제한다. 활성 운영 세션과 runtime 디렉터리는 사용하지 않는다. manifest의 `complete`는 이 캡처 요청이 종료됐다는 뜻이며 전수조사 완료 플래그가 아니다.

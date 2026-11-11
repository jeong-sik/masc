# librarian 프롬프트 v9 고정 기준 비교 기록, 2026-11-11

[#51190](https://github.com/jeong-sik/masc/pull/51190)이 이 기록을 근거로 쓴다.
비교 절차는 [RFC-0517](../../../rfc/RFC-0517-the-librarian-keeps-one-correct-fact-per-piece-of-knowledge.md) §2.3을 따른다.
이 폴더에는 숫자와 이름만 있다. 기억 본문, 모델 답 원문, E-real 기록은 넣지 않았다.

## 무엇을 확인했나

- 정리안 v9가 고정 기준에서 지금 템플릿보다 나빠진 칸 없이 좋아진 칸을 내는가.
- E-real에서 v9 답이 라이브와 다르게 지운 기억은 무엇인가.
  - 고정 기준은 이 칸을 판정하지 않는다. 사람이 읽는다.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 비교 규칙 | #50876 head `669c814ddae1`의 `scripts/tinker/librarian/prompt_compare.py`(sha256 `2bf4a1fe…`)와 `prompt_lines.json`(sha256 `62e638ff…`). 정리안을 돌리기 전에 고정했다 |
| 하네스 고정값 | 같은 head의 `pass_lines.json`(sha256 `6bd963c7…`). 모든 run의 `summary.json`이 같은 값을 적었다 |
| 지금 템플릿 | `config/prompts/librarian.md` sha256 `ec5cb66f…`. main `7bda02e85ad4`의 파일과 같다 |
| 정리안 v9 | sha256 `575a6849…`. #51190의 파일과 같다 |
| E-synth | 67건, seed 20261110, requests sha256 `f9e1441c…`(`pass_lines.json`의 `e_synth.requests_sha256`) |
| E-real | 라이브 admission 기록 52건, manifest sha256 `d22c1150…`(`pass_lines.json`의 `e_real.manifest_sha256`). 기록은 git이 무시하는 snapshot에만 있다 |
| Inkling | Tinker `thinkingmachines/Inkling-2-Small:peft:262144`. 한 쪽에 두 번 돌렸다 |
| GLM | `glm-5.3-flash`. MASC GLM 슬롯과 같은 요청 모양(`scripts/tinker/librarian/README.md` 「Request shape」)이고 출력 상한은 32,768이다. 한 쪽에 한 번 돌렸다 |

## run 파일

run은 git이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 모델 답은 `calls.jsonl`에만 있다.
`calls.jsonl` 줄 수가 `rows.jsonl`보다 많은 것은 재시도와 이어 받기 기록이다.
GLM v9는 네트워크 장애 뒤 같은 `--out`으로 이어 받았다.

| run | 템플릿 | `rows.jsonl` 줄 | sha256 | `calls.jsonl` 줄 | sha256 |
| --- | --- | --- | --- | --- | --- |
| `p0-inkling-synth-1` | 지금 | 67 | `c8261c7980c0…` | 134 | `8fccd1f77e72…` |
| `p0-inkling-synth-2` | 지금 | 67 | `250d7fd22e24…` | 134 | `4f7c09e26b98…` |
| `p0-inkling-real-1` | 지금 | 52 | `fedabb3c4ea4…` | 104 | `36f4410cf9ca…` |
| `p0-inkling-real-2` | 지금 | 52 | `c825aed03f78…` | 104 | `62a6e1cf83d4…` |
| `p1v9-inkling-synth-1` | v9 | 67 | `ad1cfbdd41af…` | 134 | `1932ec1c7b3f…` |
| `p1v9-inkling-synth-2` | v9 | 67 | `d5ebc42025d7…` | 134 | `34851c2bca3e…` |
| `p1v9-inkling-real-1` | v9 | 52 | `8398abd5004a…` | 104 | `551b6dae7525…` |
| `p1v9-inkling-real-2` | v9 | 52 | `7505dc6fe4da…` | 104 | `5e791f5f9234…` |
| `p0-glm-synth` | 지금 | 67 | `916b97643671…` | 71 | `9b4b238a4e7f…` |
| `p0-glm-real` | 지금 | 52 | `eb7101bfeedf…` | 52 | `3200a20dbb94…` |
| `p1v9-glm-synth` | v9 | 67 | `0330c8740fe2…` | 143 | `da19bb7eff3b…` |
| `p1v9-glm-real` | v9 | 52 | `0b0cd7ef66a5…` | 81 | `486618b88541…` |

합침 판정은 블라인드다. 판정자는 재료 기억, 합친 claim, 그 요청의 후보만 본다. 라벨, 모델, 템플릿은 모른다.

| 판정 폴더 | `judge/decisions.jsonl` 줄 | sha256 |
| --- | --- | --- |
| `p0-inkling-merges-1` | 21 | `3d92120c0a4a…` |
| `p0-inkling-merges-2` | 20 | `412b52a81417…` |
| `p1v9-inkling-merges-1` | 26 | `fab69c9af922…` |
| `p1v9-inkling-merges-2` | 13 | `4669053bd65c…` |
| `p0-glm-merges` | 29 | `0356c047888a…` |
| `p1v9-glm-merges` | 35 | `229ada884c6b…` |

어느 run에도 라벨 밖 지우기가 없어서 지우기 판정 폴더가 없다(`runs.json`의 `drops`가 모두 null).

## 명령

```sh
cd <#50876 head 669c814ddae1 checkout; artifacts/tinker/librarian/ 에 위 run 이 있다>
uv run scripts/tinker/librarian/prompt_compare.py \
  --runs artifacts/tinker/librarian/p1v9-runs-full.json \
  --out artifacts/tinker/librarian/p1v9-compare-full.json
```

- `compare.json`은 그 출력을 바이트 그대로 옮긴 것이다(sha256 `f4a1b9fd6afd…`).
- `runs.json`은 입력을 옮겨 적은 파생본이다.
  - 원본(sha256 `5a21389349f4…`)은 run 폴더를 절대 경로로 적었다.
  - 파생본은 같은 폴더를 `artifacts/tinker/librarian/` 기준 상대 경로로 적었다.

## 결과

나빠짐은 d < −2.5σ, 좋아짐은 d > 2σ다.
σ는 두 쪽을 합친 비율의 이항 표준오차다(`prompt_compare.py` docstring).

| 모델 | 칸 | 지금 템플릿 | v9 | d/σ | 판정 |
| --- | --- | --- | --- | --- | --- |
| Inkling | E-synth 유효 답 | 126/134 | 128/134 | +0.55 | 같음 |
| Inkling | E-real 유효 답 | 93/104 | 94/104 | +0.23 | 같음 |
| Inkling | 남는 기억 정확도 | 156/194 | 162/194 | +0.79 | 같음 |
| Inkling | 낡은 상태 지운 비율 | 5/82 | 27/82 | +4.33 | 좋아짐 |
| Inkling | 판정 합침 재현율 | 7/58 | 6/58 | −0.29 | 같음 |
| Inkling | 지우기 정밀도 | 30/30 | 55/55 | — | 같음 |
| Inkling | 흡수 정밀도 | 14/41 | 11/39 | −0.57 | 같음 |
| GLM | E-synth 유효 답 | 59/67 | 54/67 | −1.19 | 같음 |
| GLM | E-real 유효 답 | 42/52 | 40/52 | −0.48 | 같음 |
| GLM | 남는 기억 정확도 | 77/97 | 75/97 | −0.35 | 같음 |
| GLM | 낡은 상태 지운 비율 | 25/41 | 28/41 | +0.69 | 같음 |
| GLM | 판정 합침 재현율 | 8/29 | 12/29 | +1.11 | 같음 |
| GLM | 지우기 정밀도 | 43/43 | 41/41 | — | 같음 |
| GLM | 흡수 정밀도 | 22/29 | 18/36 | −2.13 | 같음 |

`compare.json`의 끝: `worse = []`, `better = ["inkling.stale_drop_recall"]`, `complete = true`, `goes_in = true`.

GLM 흡수 정밀도는 22/29에서 18/36으로 내려갔다. −2.5σ 선 안이라 규칙으로는 "같음"이다.

### 무효 답 가운데 `new_claim_without_support`

`rows.jsonl`의 `problems`에서 센 수다.

| 모델 | 지금 템플릿 (E-synth / E-real, run별) | v9 (E-synth / E-real, run별) |
| --- | --- | --- |
| Inkling | 2·1 / 3·2 (합 8) | 2·1 / 2·2 (합 7) |
| GLM | 2 / 4 (합 6) | 4 / 3 (합 7) |

## 사람이 읽은 E-real 지우기

`compare.json`의 `real_record`는 라이브 답이 남긴 기억을 지운 수(`dropped_not_in_live`)를 쪽마다 적는다.
v9에서 새로 생긴 것은 두 모델 합쳐 4건이다.
기억 글, 모델이 적은 지우기 사유, 후보가 관측된 시각, 카테고리 한도를 같이 읽었다.

| 모델 | 읽은 결과 |
| --- | --- |
| Inkling(두 번 중 한 번) | 잃음. 다음 날 아침에 쓸 기록을 쓴 그날 지웠다. 사유는 "그날만 유효한 일회성 메모"였다 |
| GLM | 맞게 지움. 같은 기억을 쓸 날이 지난 뒤의 요청에서 지웠다. 겹침을 막는 규칙은 다른 기억에 있다 |
| Inkling(두 번 중 한 번) | 사유가 맞음. 한도 30을 1개 넘은 카테고리에서, 취소된 task에 묶인 교훈 하나를 지웠다 |
| GLM | 사유가 맞음. 끝난 장애 기록을 지웠다. 원인과 수리는 병합된 PR과 Board 글에 있다 |

지금 템플릿에서 지우던 1건(교정으로 바뀐 기억)은 v9 GLM에서 지우지 않았다.

## 재지 않은 것

- 라이브 admission 레인의 첫 슬롯(DeepSeek flash)은 재지 않았다.
- durable·cleanup 패스도 이 본문을 읽는다. 하네스는 admission만 잰다.
- E-synth에는 "쓸 날이 남은 기록"이 없다. 그래서 위의 Inkling 손실 같은 경우는 고정 기준이 재지 못한다.
- 라이브에서 지우기는 흡수 게이트를 거치지 않는다. 지우기 확인은 RFC-0517 §7.2가 정할 일로 남아 있다.

## 2026-11-11 밤에 바뀐 것

- 위 「run 파일」 표의 run 폴더와 판정 폴더가 있던 worktree가 2026-11-11 22:16 KST에 지워졌다. git이 무시하는 폴더라 같이 지워졌다. 표의 줄 수와 sha256은 대조할 파일이 없다.
- `compare.json`, `runs.json`과 이 README의 숫자는 지워지기 전에 낸 것이고 바뀌지 않았다.
- E-real 스냅샷도 같이 지워졌다. 기록 52건 가운데 2건은 서버가 이미 본문을 지운 뒤라 다시 뜨지 못했다. 지금 고정한 E-real은 남은 50건이고, 사라진 2건의 digest는 `scripts/tinker/librarian/e_real_manifest.json`의 `of.gone`에 있다.
- 이때 `scripts/tinker/librarian/prompt_lines.json`이 sha256으로 고정하고 있던 기준선 `rows.jsonl`(`p0-*`)도 위 표의 파일이다.

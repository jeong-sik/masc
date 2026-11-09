# masc_board_comment 결과가 쓴 글을 되돌려 주던 몫 (2026-11)

`masc_board_comment` 는 성공하면 댓글 레코드를 그대로 돌려줬어요. 레코드에는 방금 쓴 글(`content`)이 들어 있어요. 글은 호출 인자로 이미 Keeper 컨텍스트에 있어서, 같은 바이트가 두 번 실려요. 이 폴더는 그 몫을 장부로 세는 스크립트와, 글을 뺀 변경(#50620) 앞의 기준선이에요.

## 기준선 (변경 앞)

창은 2026-11-02T00:00Z ~ 11-09T10:30Z(7.44일)이고 장부 `~/me/.masc/tool_calls` 전체예요.

| 항목 | 값 |
|---|---|
| 성공한 `masc_board_comment` 호출 | 5,855 |
| 실패(`disposition == failed`) / 인자 거절(`Your call to "`로 시작) | 119 / 586 |
| 성공 응답 바이트 합 | 11,268,077 |
| 그중 방금 쓴 글을 되풀이한 바이트 | 8,930,558 (79.3%) |
| 글을 되풀이한 호출 | 5,409 (92.4%) |
| 응답 바이트 중앙값 | 1,878 |
| 응답이 도구 출력 경계에서 잘린 호출(`_truncated`) | 289 (4.9%) |
| 쓴 직후 같은 Keeper 의 다음 호출이 같은 글의 `masc_board_post_get` (60초 안) | 379 (6.5%) |

- 마지막 줄은 글이 응답에 있을 때의 값이에요. 글을 뺀 뒤 이 값이 오르면, Keeper 가 쓴 글을 확인하려고 다시 읽는다는 뜻이에요. 변경 뒤에 같은 정의로 다시 재요.
- 응답에서 글을 뺀 나머지(id, post_id, author, 시각, audience, votes, unresolved, 위치)는 이 변경 뒤에도 그대로 가요. 나머지는 응답 바이트의 20.7%예요.
- 도구 전체로 보면 입력 문자열(200바이트 이상)이 결과에 되풀이되는 몫은 7일(11-02~11-09) 성공 호출 155,991건의 출력 211.5 MB 중 12.21 MB(5.8%)였고, 그중 `masc_board_comment` 가 8.16 MB예요. 다음은 `masc_schedule_note_add` 1.79 MB(그 도구 출력의 84.3%), `masc_board_post` 1.02 MB(66.7%)예요. 이 집계는 일회용 스크립트로 냈고 저장소에 없어요. `masc_board_post` 는 결과에서 글을 다시 읽는 곳(`post_of_write_data`)이 있어서 같은 방법으로 못 빼요.

## 스크립트

```bash
python3 docs/evidence/board-comment-result-2026-11/comment_result_echo.py \
  --base-path ~/me --since 2026-11-02T00:00:00 --end 2026-11-09T10:30:00 \
  --json-out docs/evidence/board-comment-result-2026-11/result-before-2026-11-02_11-09T10-30.json
```

정의는 스크립트 머리말에 있어요. 장부만 읽고 아무것도 쓰지 않아요(`--json-out` 제외). 시험은 `python3 -m unittest discover -s docs/evidence/board-comment-result-2026-11` 이에요. 시험 20개, 변이 10개를 모두 잡아요.

## 배포 뒤 재는 법

서버가 이 변경이 든 빌드로 뜬 시각(`/health` 의 시작 시각)에서 60초 뒤부터 같은 길이 이상을 재요.

```bash
python3 docs/evidence/board-comment-result-2026-11/comment_result_echo.py \
  --base-path ~/me --since <부팅 +60초 UTC> --end <지금 UTC>
```

- 기대: `repeated_text_share` 가 0에 가깝고, `answer_bytes_median` 이 1,878에서 수백 바이트로 내려가고, `answers_cut_short` 이 0이에요.
- 확인할 것: `read_after_write.share` 가 6.5%에서 얼마나 오르는지. 크게 오르면 글을 뺀 것이 Keeper 의 확인 습관과 부딪힌다는 신호예요.
- 표본이 적으면(부팅 직후 몇 시간) 값을 말하지 않아요. 기준선은 하루 평균 약 790건(5,855건 / 7.44일)이에요.

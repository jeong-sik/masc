---
name: verify-before-claiming-done
description: "Checks a completion claim against output from a command run just now, from the start, before saying done, fixed, passing, merged or ready, or before submitting a task for verification. Covers which command proves the claim, why a cached or partial green does not, how to read exit status instead of a summary line, and how keeper_lane_status shows whether the last Execute actually ran."
---

# 완료를 말하기 전에 검증

**방금 돌린 검증 출력 없이는 완료를 말하지 않는다.** "될 것이다", "통과할 것이다",
"고쳤으니 됐다"는 검증이 아니라 예측이다. 안 돌린 것을 됐다고 말하면 다음 사람이 그 말
위에 쌓고, 틀린 게 드러나는 시점이 늦을수록 되돌리는 값이 커진다.

## 다섯 단계

말하기 전에 이 순서를 밟는다.

1. **무엇이 증명하나.** 이 주장을 증명하는 명령을 짚는다. "테스트 통과"면 그 스위트,
   "빌드됨"이면 그 빌드, "머지해도 된다"면 머지할 커밋에서 돈 빌드와 스위트다.
2. **처음부터 돌린다.** 방금, 끝까지. 캐시가 성공을 재생하는 도구는 출력 없이 초록을
   보여준다. 결과가 캐시에서 왔는지 모르겠으면 캐시를 우회해 다시 돌린다.
3. **출력을 읽는다.** 종료 코드, 실패 개수, 마지막 줄. 요약 문구가 아니라 종료 코드로
   판정한다. 도중에 죽은 스위트는 절반짜리 합계를 전부인 것처럼 찍는다.
4. **출력이 주장을 덮나.** 초록인 검사가 말하려는 범위를 실제로 덮는지 본다. 컴파일
   초록은 테스트 초록이 아니고, 한 스위트 초록은 전체 초록이 아니다.
5. **그다음에** 명령과 출력을 같이 적어 말한다.

## 마지막 Execute 가 실제로 돌았나

`keeper_lane_status` 는 실행 레인이 microvm·원격 SSH 일 때 그 엔드포인트로 마지막으로
나간 Execute 가 어떻게 끝났는지 `last_dispatch` 로 보여준다. `outcome` 이
`payload_finished` 면 `status`(`exit=0` 등)가 명령의 종료 상태이고, `lane_failed` 면 명령이
아니라 레인이 실패한 것이다. `at_unix` 가 내가 돌린 시각보다 앞서거나 `status` 가 기억과
다르면, 돌리지 않은 것을 돌렸다고 믿고 있는 것이다. 이 기록은 엔드포인트마다 하나라서,
그 뒤에 다른 Execute 가 나갔으면 그 호출의 기록으로 바뀐다. 이것은 검증의 절반이다. 명령이
실제로 끝났다는 것만 알려주고, 그 출력이 주장을 덮는지는 위 3·4단계가 판정한다.
docker 레인은 이 기록이 없어 `last_dispatch` 가 늘 `null` 이고, 서버가 재시작해도 비워진다.
그러니 `null` 을 "아무것도 안 돌았다"로 읽지 않는다.

## 멈추는 신호

- "될 것이다 / 통과할 것이다 / 고쳤으니 됐다" 라고 쓰고 있다 → 아직 안 돌렸다.
- 합성 데이터나 목업만으로 "완성"이라 부르고 있다 → 실제 입력으로 끝까지 한 번 돌린다.
- 테스트를 돌린 트리와 올린 커밋이 다르다 → 올린 커밋에서 다시 확인한다.
  `git commit --amend` 는 스테이지된 변경만 얹는다.
- CI 결과를 안 보고 "머지 완료"라 말하고 있다 → push 뒤 결과를 본다.
- "이 오류는 안 난다"고 말하려는데, 지켜본 시간이 그 오류가 원래 나던 간격보다 짧다 →
  "없다"가 아니라 "아직 못 봤다"다.
- 상태 코드나 목록 표시만 보고 판정하고 있다 → 실제 내용을 연다. HTTP 200 이 오류
  화면을 그릴 수 있고, squash 병합은 원래 커밋 SHA 를 남기지 않는다.

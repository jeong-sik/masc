(* Fusion — 시간당 발동 카운터 (구현).
   계약/문서: fusion_budget.mli, docs/rfc/RFC-0252 §6/§10

   (bucket, count) Atomic.t + CAS 루프 → lock-free, 추가 의존 없음(stdlib Atomic). *)

type t = (string * int) Atomic.t

let create () : t = Atomic.make ("", 0)

(* check(c < limit) → incr을 단일 CAS로 묶어 peek→incr TOCTOU를 닫는다 (멀티
   도메인에서도 limit 초과 발행 없음). bucket이 바뀌면 새 윈도우로 리셋하며 첫
   발동을 허용(limit>=1 가정). c >= limit이면 증가 없이 Error. *)
let rec try_incr_if_under (t : t) ~hour_bucket ~limit =
  let ((b, c) as cur) = Atomic.get t in
  if not (String.equal b hour_bucket) then
    let next = (hour_bucket, 1) in
    if Atomic.compare_and_set t cur next then Ok 1
    else try_incr_if_under t ~hour_bucket ~limit
  else if c >= limit then Error ()
  else
    let next = (b, c + 1) in
    if Atomic.compare_and_set t cur next then Ok (c + 1)
    else try_incr_if_under t ~hour_bucket ~limit

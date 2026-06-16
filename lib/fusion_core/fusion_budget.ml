(* Fusion — 시간당 발동 카운터 (구현).
   계약/문서: fusion_budget.mli, docs/rfc/RFC-0252 §6/§10

   (bucket, count) Atomic.t + CAS 루프 → lock-free, 추가 의존 없음(stdlib Atomic). *)

type t = (string * int) Atomic.t

let create () : t = Atomic.make ("", 0)

let rec incr_and_count (t : t) ~hour_bucket =
  let ((b, c) as cur) = Atomic.get t in
  let next = if String.equal b hour_bucket then (b, c + 1) else (hour_bucket, 1) in
  if Atomic.compare_and_set t cur next then snd next
  else incr_and_count t ~hour_bucket

let current_count (t : t) ~hour_bucket =
  let b, c = Atomic.get t in
  if String.equal b hour_bucket then c else 0

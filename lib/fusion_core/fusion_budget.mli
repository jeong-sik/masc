(** Fusion — 시간당 발동 카운터 (RFC-0252 §6/§10).

    시간당 발동 상한을 강제하는 캡슐화된 상태. 하드코딩 글로벌이나
    휴리스틱이 아니라 명시적 [t]를 호출자가 보유한다. 현재 시각은 코어에 들이지
    않고 호출자가 [hour_bucket](예 ["2026-06-16T18"])으로 주입한다 — 결정론적·
    테스트 가능. bucket이 바뀌면 자동으로 새 윈도우(이전 카운트는 잊어 메모리 bounded).

    동시성: [(bucket, count) Atomic.t] + CAS 루프로 lock-free(도메인/파이버 안전). *)

type t

(** 빈 카운터 생성. 호출자(서버/도구)가 단일 인스턴스를 보유한다. *)
val create : unit -> t

(** [hour_bucket]의 카운트를 1 증가시키고 새 값을 반환. bucket이 직전과 다륾면
    1로 리셋(새 시간 윈도우). *)
val incr_and_count : t -> hour_bucket:string -> int

(** [hour_bucket]의 카운트가 [limit] 미만일 때만 1 증가시키고 새 값을 반환.
    limit에 도달하거나 초과한 상태면 [Error ()]를 반환하며 카운트를 변경하지
    않는다. 이 연산은 원자적이다. *)
val try_incr_if_under : t -> hour_bucket:string -> limit:int -> (int, unit) result

(** 증가 없이 현재 카운트 조회(다른 bucket이면 0). *)
val current_count : t -> hour_bucket:string -> int

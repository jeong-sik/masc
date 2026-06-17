(** Fusion — 시간당 발동 카운터 (RFC-0255 §6/§10).

    시간당 발동 상한을 강제하는 캡슐화된 상태. 하드코딩 글로벌이나
    휴리스틱이 아니라 명시적 [t]를 호출자가 보유한다. 현재 시각은 코어에 들이지
    않고 호출자가 [hour_bucket](예 ["2026-06-16T18"])으로 주입한다 — 결정론적·
    테스트 가능. bucket이 바뀌면 자동으로 새 윈도우(이전 카운트는 잊어 메모리 bounded).

    동시성: [(bucket, count) Atomic.t] + CAS 루프로 lock-free(도메인/파이버 안전). *)

type t

(** 빈 카운터 생성. 호출자(서버/도구)가 단일 인스턴스를 보유한다. *)
val create : unit -> t

(** [hour_bucket]의 카운트가 [limit] 미만이면 원자적으로 1 증가시키고 새 카운트를
    [Ok]로, [limit] 이하(0 또는 음수)거나 이미 [limit] 이상이면 증가 없이
    [Error ()]를 반환한다. 검사와 증가가 단일 CAS라 peek→incr TOCTOU가 없다(멀티
    도메인 동시 발동에도 [limit] 초과 발행 없음).
    bucket이 직전과 다르면 새 윈도우로 리셋하며 첫 발동을 허용한다. *)
val try_incr_if_under : t -> hour_bucket:string -> limit:int -> (int, unit) result

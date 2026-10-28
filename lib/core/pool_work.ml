(** Pool_work — a compute together with the kind of work it does. *)

type kind =
  | Cpu
  | Io

type 'a t = {
  kind : kind;
  body : unit -> 'a;
}

let cpu body = { kind = Cpu; body }
let io body = { kind = Io; body }

let weight = function
  | Cpu -> Domain_pool.weight_cpu
  | Io -> Domain_pool.weight_io
;;

let wrap w f = { kind = w.kind; body = (fun () -> f w.body) }

let submit w = Executor_pool_ref.submit_or_inline ~weight:(weight w.kind) w.body

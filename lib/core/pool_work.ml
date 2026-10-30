(** Pool_work — a compute together with the kind of work it does. *)

type kind =
  | Cpu
  | Io

type 'a t = {
  kind : kind;
  name : string;
  body : unit -> 'a;
}

let cpu ~name body = { kind = Cpu; name; body }
let io ~name body = { kind = Io; name; body }

let weight = function
  | Cpu -> Domain_pool.weight_cpu
  | Io -> Domain_pool.weight_io
;;

let wrap w f = { kind = w.kind; name = w.name; body = (fun () -> f w.body) }

let submit w =
  Executor_pool_ref.submit_or_inline ~weight:(weight w.kind) ~name:w.name w.body

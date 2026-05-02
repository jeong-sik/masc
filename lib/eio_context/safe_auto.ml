(** SafeAuto effect handler to prevent backtrace loss on discontinue.
    Ensures source path is attached to the effect payload before discontinuation. *)

open Effect.Deep

type source_path = string [@@deriving show]

(** Invariant: source path must be non-null. *)
let invariant_source_path_non_null (p: source_path) =
  if String.length p = 0 then failwith "SafeAuto invariant violated: source path is null"

type _ Effect.t +=
  | Halt : source_path * string -> unit Effect.t

exception Safe_autonomy_halt of source_path * string

let with_safe_auto (source : source_path) (f : unit -> 'a) : 'a =
  invariant_source_path_non_null source;
  match_with f ()
  { retc = (fun x -> x);
    exnc = (fun e -> raise e);
    effc = fun (type a) (eff : a Effect.t) ->
      match eff with
      | Halt (p, msg) ->
          Some (fun (k : (a, _) continuation) ->
            invariant_source_path_non_null p;
            discontinue k (Safe_autonomy_halt (p, msg)))
      | _ -> None
  }

let halt (source : source_path) (msg : string) : unit =
  invariant_source_path_non_null source;
  Effect.perform (Halt (source, msg))

(* See keeper_execution_join.mli for the happens-before and weak-ownership
   arguments that make this deterministic without leaking cancelled calls. *)

module Invocation_key = struct
  type t = Agent_core.Tool_contract.Invocation.t

  let equal left right = left == right
  let hash = Hashtbl.hash
end

module Invocation_table = Ephemeron.K1.Make (Invocation_key)

let table : string Invocation_table.t = Invocation_table.create 64
let lock = Mutex.create ()

let record ~invocation ~execution_id =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () -> Invocation_table.replace table invocation execution_id)

let discard ~invocation =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () -> Invocation_table.remove table invocation)

let take ~invocation =
  Mutex.lock lock;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lock)
    (fun () ->
      match Invocation_table.find_opt table invocation with
      | Some execution_id ->
        Invocation_table.remove table invocation;
        Some execution_id
      | None -> None)

module For_testing = struct
  let size () =
    Mutex.lock lock;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock)
      (fun () ->
         Invocation_table.clean table;
         Invocation_table.length table)

  let clear () =
    Mutex.lock lock;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock)
      (fun () -> Invocation_table.reset table)
end

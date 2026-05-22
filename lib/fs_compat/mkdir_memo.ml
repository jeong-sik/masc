(* RFC-0162 §3.1. See [mkdir_memo.mli] for the contract.

   Race: two domains may both miss-and-mkdir; the second [mkdir_p]
   call is a harmless EEXIST inside the caller's primitive. The
   mutex only guards the [Hashtbl] op so the [mkdir_p] callback
   runs unlocked and can itself acquire fs locks without nesting. *)

let done_ : (string, unit) Hashtbl.t = Hashtbl.create 32
let mu = Stdlib.Mutex.create ()

let mkdir_p_memoized ~(mkdir_p : string -> unit) (path : string) : unit =
  let cached =
    Stdlib.Mutex.protect mu (fun () -> Hashtbl.mem done_ path)
  in
  if not cached
  then begin
    mkdir_p path;
    Stdlib.Mutex.protect mu (fun () -> Hashtbl.replace done_ path ())
  end
;;

let reset_for_testing () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset done_)
;;

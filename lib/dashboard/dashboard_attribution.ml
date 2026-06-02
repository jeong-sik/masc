(** See [Dashboard_attribution.mli]. *)

let per_gate_cap = 200

(* Guards [table]. Critical sections are short — queue push, fold, or clear.
   Stdlib.Mutex is chosen over Eio.Mutex because record/read may be called
   from different domains, and the section never yields to Eio. *)
let mu = Mutex.create ()

(* Per-gate FIFO. Head = oldest, tail = newest. *)
let table : (string, (Attribution.t * float) Queue.t) Hashtbl.t =
  Hashtbl.create 8

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let record_with_time ~now (attr : Attribution.t) =
  with_lock (fun () ->
      let q =
        match Hashtbl.find_opt table attr.gate with
        | Some q -> q
        | None ->
          let q = Queue.create () in
          Hashtbl.add table attr.gate q;
          q
      in
      Queue.push (attr, now) q;
      while Queue.length q > per_gate_cap do
        ignore (Queue.pop q)
      done)

let record attr = record_with_time ~now:(Unix.gettimeofday ()) attr

(* Snapshot newest-first: fold accumulates as (new :: acc) reversed by
   Queue.fold's left-fold over FIFO order, so a second reverse after take. *)
let snapshot_newest_first q limit =
  (* Queue.fold traverses oldest -> newest; prepend makes the list
     newest-first without an extra reverse. *)
  let all = Queue.fold (fun acc x -> x :: acc) [] q in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  take limit all

let recent ?gate ?(limit = 50) () =
  let limit = max 0 limit in
  with_lock (fun () ->
      match gate with
      | Some g ->
        (match Hashtbl.find_opt table g with
         | Some q -> snapshot_newest_first q limit
         | None -> [])
      | None ->
        let all =
          Hashtbl.fold
            (fun _ q acc ->
              Queue.fold (fun acc x -> x :: acc) acc q)
            table []
        in
        (* Sort by timestamp descending. *)
        let sorted =
          List.sort (fun (_, t1) (_, t2) -> compare t2 t1) all
        in
        let rec take n = function
          | [] -> []
          | _ when n <= 0 -> []
          | x :: xs -> x :: take (n - 1) xs
        in
        take limit sorted)

type gate_summary = {
  gate : string;
  passed : int;
  policy_failed : int;
  transition_blocked : int;
  partial_pass : int;
  total : int;
}

let summary () =
  with_lock (fun () ->
      Hashtbl.fold
        (fun gate q acc ->
          let passed = ref 0
          and pf = ref 0
          and tb = ref 0
          and pp = ref 0 in
          Queue.iter
            (fun (a, _ts) ->
              match a.Attribution.outcome with
              | Attribution.Passed -> incr passed
              | Attribution.Policy_failed _ -> incr pf
              | Attribution.Transition_blocked _ -> incr tb
              | Attribution.Partial_pass _ -> incr pp)
            q;
          {
            gate;
            passed = !passed;
            policy_failed = !pf;
            transition_blocked = !tb;
            partial_pass = !pp;
            total = Queue.length q;
          }
          :: acc)
        table [])

let reset () = with_lock (fun () -> Hashtbl.clear table)

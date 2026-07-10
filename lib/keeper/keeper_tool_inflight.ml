(** Keeper_tool_inflight — live registry of in-flight keeper tool calls.

    Mirrors {!Keeper_recurring}'s storage discipline: a [Hashtbl] guarded by an
    [Eio.Mutex] via {!Eio_guard} so module-init and non-Eio tests work without
    triggering [Effect.Unhandled]. See the [.mli] and RFC-0336 Phase A. *)

type entry = {
  keeper_name : string;
  tool_name : string;
  job_id : string;
  started_at : float;
  deadline_at : float option;
}

(* ================================================================ *)
(* Storage                                                           *)
(* ================================================================ *)

let entries : (string, entry) Hashtbl.t = Hashtbl.create 16

let mu = Eio.Mutex.create ()
let with_rw f = Eio_guard.with_mutex mu f
let with_ro f = Eio_guard.with_mutex_ro mu f

(* ================================================================ *)
(* CRUD                                                              *)
(* ================================================================ *)

let register ~keeper_name ~tool_name ?deadline_ms ~job_id () =
  let started_at = Time_compat.now () in
  let deadline_at =
    match deadline_ms with
    | None -> None
    | Some ms -> Some (started_at +. (float_of_int ms /. 1000.0))
  in
  let entry = { keeper_name; tool_name; job_id; started_at; deadline_at } in
  with_rw (fun () -> Hashtbl.replace entries job_id entry);
  entry

let unregister ~job_id = with_rw (fun () -> Hashtbl.remove entries job_id)

let list ~keeper_name =
  with_ro (fun () ->
    Hashtbl.fold
      (fun _ e acc -> if e.keeper_name = keeper_name then e :: acc else acc)
      entries [])
  |> List.sort (fun a b -> compare a.started_at b.started_at)

let list_all () =
  with_ro (fun () -> Hashtbl.fold (fun _ e acc -> e :: acc) entries [])
  |> List.sort (fun a b -> compare a.started_at b.started_at)

(* ================================================================ *)
(* Testing                                                           *)
(* ================================================================ *)

let clear () = with_rw (fun () -> Hashtbl.clear entries)

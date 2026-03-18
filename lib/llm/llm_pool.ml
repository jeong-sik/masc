(** Provider-based LLM concurrency pool — implementation.

    One [Eio.Semaphore.t] per (provider, model) pair.
    Acquire blocks the fiber; release is guaranteed via [Fun.protect]. *)

type provider_id = string
type model_id = string

type slot_key = {
  provider : provider_id;
  model : model_id;
}

type slot = {
  key : slot_key;
  semaphore : Eio.Semaphore.t;
  timeout_sec : float;
  capacity : int;
}

(** Pool handle.  [slots] is populated once by [create] and never mutated
    afterward — all concurrent reads from fibers are safe without a mutex.
    Concurrency control is per-slot via [Eio.Semaphore]. *)
type t = {
  slots : (string, slot) Hashtbl.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
}

let slot_key_to_string key = key.provider ^ ":" ^ key.model

let create ~clock configs =
  let slots = Hashtbl.create (List.length configs) in
  List.iter (fun (key, capacity, timeout_sec) ->
    let id = slot_key_to_string key in
    let slot = {
      key;
      semaphore = Eio.Semaphore.make capacity;
      timeout_sec;
      capacity;
    } in
    Hashtbl.replace slots id slot
  ) configs;
  { slots; clock }

let with_slot t key f =
  let id = slot_key_to_string key in
  match Hashtbl.find_opt t.slots id with
  | None -> Error (Printf.sprintf "unknown slot: %s" id)
  | Some slot ->
    (* Acquire permit with timeout — fiber yields here if pool is full *)
    let acquired =
      try
        Eio.Time.with_timeout_exn t.clock slot.timeout_sec (fun () ->
          Eio.Semaphore.acquire slot.semaphore);
        true
      with
      | Eio.Time.Timeout -> false
      | Eio.Cancel.Cancelled _ as exn -> raise exn
    in
    if not acquired then
      Error (Printf.sprintf "timeout waiting for slot %s (%.1fs)" id slot.timeout_sec)
    else
      (* Run f with guaranteed semaphore release *)
      match
        Fun.protect
          ~finally:(fun () -> Eio.Semaphore.release slot.semaphore)
          (fun () -> f ())
      with
      | result -> Ok result
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
          Error (Printf.sprintf "slot %s: %s" id (Printexc.to_string exn))

let stats t =
  Hashtbl.fold (fun _id slot acc ->
    let in_use = slot.capacity - Eio.Semaphore.get_value slot.semaphore in
    (slot.key, in_use, slot.capacity) :: acc
  ) t.slots []

let has_capacity t key =
  let id = slot_key_to_string key in
  match Hashtbl.find_opt t.slots id with
  | None -> false
  | Some slot -> Eio.Semaphore.get_value slot.semaphore > 0

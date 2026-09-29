(* See the .mli. Reads run on fibers of the UI domain and a critical section
   here never suspends, so the mutex only has to cover a read that some later
   caller makes from a system thread. *)

type 'a kept = {
  etag : string;
  value : 'a;
}

type 'a t = {
  mutex : Mutex.t;
  mutable current : (string, 'a kept) Hashtbl.t;
  mutable previous : (string, 'a kept) Hashtbl.t;
}

(* A sizing hint for one tick's reads, not a bound. *)
let addresses_per_tick = 32

let create () =
  {
    mutex = Mutex.create ();
    current = Hashtbl.create addresses_per_tick;
    previous = Hashtbl.create addresses_per_tick;
  }

let find t ~address =
  Mutex.protect t.mutex (fun () ->
      match Hashtbl.find_opt t.current address with
      | Some kept -> Some kept
      | None -> (
          match Hashtbl.find_opt t.previous address with
          | Some kept ->
              Hashtbl.replace t.current address kept;
              Some kept
          | None -> None))

let request_headers = function
  | Some kept -> [ ("If-None-Match", kept.etag) ]
  | None -> []

let not_modified = 304

(* Header names are case-insensitive (RFC 9110 section 5.1). *)
let entity_tag headers =
  List.find_map
    (fun (name, value) ->
      if String.equal (String.lowercase_ascii name) "etag" then Some value else None)
    headers

let keep t ~address kept =
  Mutex.protect t.mutex (fun () -> Hashtbl.replace t.current address kept)

let drop t ~address =
  Mutex.protect t.mutex (fun () ->
      Hashtbl.remove t.current address;
      Hashtbl.remove t.previous address)

let settle t ~address ~sent ~status ~headers ~decode =
  match sent with
  | Some kept when status = not_modified -> Ok kept.value
  | Some _ | None ->
      let decoded = decode () in
      (match (decoded, entity_tag headers) with
       | Ok value, Some etag -> keep t ~address { etag; value }
       | Ok _, None | Error _, (Some _ | None) -> drop t ~address);
      decoded

let start_generation t =
  Mutex.protect t.mutex (fun () ->
      t.previous <- t.current;
      t.current <- Hashtbl.create addresses_per_tick)

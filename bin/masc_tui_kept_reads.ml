(* See the .mli. The mutex is held only around table lookups and updates,
   never across [send] or [decode]. Reads run on fibers of the UI domain, and
   one caller today reads from a system thread: [open_stored_image] in
   masc_tui.ml. *)

type 'a kept = {
  etag : string;
  value : 'a;
}

type 'a t = {
  mutex : Mutex.t;
  mutable current : (string, 'a kept) Hashtbl.t;
  mutable previous : (string, 'a kept) Hashtbl.t;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(* A sizing hint for one refresh pass's reads, not a bound. *)
let addresses_per_pass = 32

let create () =
  {
    mutex = Mutex.create ();
    current = Hashtbl.create addresses_per_pass;
    previous = Hashtbl.create addresses_per_pass;
  }

let lookup t ~address =
  match Hashtbl.find_opt t.current address with
  | Some kept -> Some kept
  | None -> Hashtbl.find_opt t.previous address

let find t ~address = Mutex.protect t.mutex (fun () -> lookup t ~address)

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

(* A 304 confirms [kept], so it counts as asked for in the generation the
   answer arrived in. A generation may have started while the read was out.
   A read of the same address that finished meanwhile and kept a different
   tag holds the newer answer, and it stays. *)
let reaffirm t ~address kept =
  Mutex.protect t.mutex (fun () ->
      match lookup t ~address with
      | Some held when not (String.equal held.etag kept.etag) -> ()
      | Some _ | None -> Hashtbl.replace t.current address kept)

let drop t ~address =
  Mutex.protect t.mutex (fun () ->
      Hashtbl.remove t.current address;
      Hashtbl.remove t.previous address)

let read t ~address ~send ~decode =
  let sent = find t ~address in
  match send (request_headers sent) with
  | Error _ as error -> error
  | Ok response -> (
      match sent with
      | Some kept when response.status = not_modified ->
          reaffirm t ~address kept;
          Ok kept.value
      | Some _ | None ->
          let decoded = decode response in
          (match (decoded, entity_tag response.headers) with
           | Ok value, Some etag -> keep t ~address { etag; value }
           | Ok _, None | Error _, (Some _ | None) -> drop t ~address);
          decoded)

let start_generation t =
  Mutex.protect t.mutex (fun () ->
      t.previous <- t.current;
      t.current <- Hashtbl.create addresses_per_pass)

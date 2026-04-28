type t = {
  id : string;
  ts : float;
  category : string;
  payload : Yojson.Safe.t;
  prev_hash : string option;
}

let initialized = ref false

let init_random () =
  if not !initialized then begin
    Random.self_init ();
    initialized := true
  end

(* ULID-lite: 16 hex chars timestamp-ms + "-" + 26 hex chars random. *)
let generate_id () =
  init_random ();
  let now_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0) in
  let ts_hex = Printf.sprintf "%016Lx" now_ms in
  let r1 = Random.int64 0x100000000L in
  let r2 = Random.int64 0x100000000L in
  let r3 = Random.int64 0x10000L in
  let r_hex = Printf.sprintf "%08Lx%08Lx%04Lx" r1 r2 r3 in
  ts_hex ^ "-" ^ r_hex

let make ~category ~payload ~prev_hash =
  { id = generate_id ();
    ts = Unix.gettimeofday ();
    category;
    payload;
    prev_hash;
  }

let canonical_json t =
  let prev =
    match t.prev_hash with
    | None -> `Null
    | Some h -> `String h
  in
  let fields = [
    "id", `String t.id;
    "ts", `Float t.ts;
    "category", `String t.category;
    "payload", t.payload;
    "prev_hash", prev;
  ] in
  Yojson.Safe.to_string (`Assoc fields)

let compute_hash t =
  let s = canonical_json t in
  Digestif.SHA256.digest_string s |> Digestif.SHA256.to_hex

let hash_for_chain = compute_hash

let to_json t =
  let prev =
    match t.prev_hash with
    | None -> `Null
    | Some h -> `String h
  in
  `Assoc [
    "id", `String t.id;
    "ts", `Float t.ts;
    "category", `String t.category;
    "payload", t.payload;
    "prev_hash", prev;
  ]

let of_json = function
  | `Assoc fields ->
    let get_string k =
      match List.assoc_opt k fields with
      | Some (`String s) -> Ok s
      | _ -> Error (Printf.sprintf "Envelope.of_json: missing or bad %s" k)
    in
    let get_float k =
      match List.assoc_opt k fields with
      | Some (`Float f) -> Ok f
      | Some (`Int i) -> Ok (float_of_int i)
      | _ -> Error (Printf.sprintf "Envelope.of_json: missing or bad %s" k)
    in
    let get_payload () =
      match List.assoc_opt "payload" fields with
      | Some v -> Ok v
      | None -> Error "Envelope.of_json: missing payload"
    in
    let get_prev_hash () =
      match List.assoc_opt "prev_hash" fields with
      | Some `Null -> Ok None
      | Some (`String s) -> Ok (Some s)
      | None -> Ok None
      | _ -> Error "Envelope.of_json: bad prev_hash"
    in
    (match
       get_string "id",
       get_float "ts",
       get_string "category",
       get_payload (),
       get_prev_hash ()
     with
     | Ok id, Ok ts, Ok category, Ok payload, Ok prev_hash ->
       Ok { id; ts; category; payload; prev_hash }
     | Error e, _, _, _, _
     | _, Error e, _, _, _
     | _, _, Error e, _, _
     | _, _, _, Error e, _
     | _, _, _, _, Error e -> Error e)
  | _ -> Error "Envelope.of_json: expected object"

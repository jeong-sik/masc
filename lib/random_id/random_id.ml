(** Cryptographically random identifier helper.

    See [random_id.mli] for API rationale. Implementation is the
    canonical form of the pattern that was duplicated across
    verification/board/workspace/transport correlation sites — every
    site did [Crypto_rng.generate N |> hex encode] with
    slight formatting variance. *)

let hex_char n = Char.chr (if n < 10 then Char.code '0' + n else Char.code 'a' + n - 10)

let hex ~bytes =
  let rnd = Crypto_rng.generate bytes in
  let len = String.length rnd in
  let buf = Bytes.create (len * 2) in
  for i = 0 to len - 1 do
    let b = Char.code (String.get rnd i) in
    Bytes.set buf (i * 2) (hex_char (b lsr 4));
    Bytes.set buf (i * 2 + 1) (hex_char (b land 0x0f))
  done;
  Bytes.to_string buf

let prefixed ~prefix ~bytes =
  prefix ^ hex ~bytes

(* NDT-OK: UUIDv7 minting is an explicit nondeterministic boundary.  The wall
   clock supplies the RFC timestamp while the process-seeded PRNG supplies the
   opaque random/counter tail; consumers never branch on that tail. *)
type logical_ms_clock = {
  now_ms : unit -> int64;
  advance : unit -> unit;
}

let logical_ms_clock raw_now_ms =
  let last_ms = ref Int64.min_int in
  let now_ms () =
    let observed_ms = raw_now_ms () in
    let current_ms = Int64.max observed_ms !last_ms in
    last_ms := current_ms;
    current_ms
  in
  let advance () =
    if Int64.equal !last_ms Int64.max_int
    then invalid_arg "UUIDv7 logical millisecond clock exhausted"
    else last_ms := Int64.succ !last_ms
  in
  { now_ms; advance }

let uuid_v7_clock =
  logical_ms_clock (fun () ->
    (* NDT-OK: UUIDv7 timestamp source at the identifier-minting boundary. *)
    Int64.of_float (Unix.gettimeofday () *. 1000.0))

let uuid_v7_generator =
  Uuidm.v7_monotonic_gen
    ~now_ms:uuid_v7_clock.now_ms
    (* NDT-OK: process-seeded entropy for the UUIDv7 opaque tail. *)
    (Random.State.make_self_init ())

let uuid_v7_mutex = Mutex.create ()

let rec generate_uuid_v7_locked () =
  match uuid_v7_generator () with
  | Some uuid -> Uuidm.to_string uuid
  | None ->
    (* RFC 9562 permits advancing the logical timestamp after exhausting the
       12-bit monotonic counter. This also prevents a backwards wall-clock
       adjustment from blocking ID minting until real time catches up. *)
    uuid_v7_clock.advance ();
    generate_uuid_v7_locked ()

let uuid_v7 () =
  Mutex.protect uuid_v7_mutex generate_uuid_v7_locked

let parse_uuid_v7 value =
  if String.length value <> 36
  then Error (Printf.sprintf "expected 36 characters, got %d" (String.length value))
  else
    match Uuidm.of_string value with
    | Some uuid when Uuidm.version uuid = 7 && Uuidm.variant uuid >= 8
                     && Uuidm.variant uuid <= 11 ->
      Ok (Uuidm.to_string uuid)
    | Some uuid when Uuidm.version uuid <> 7 ->
      Error (Printf.sprintf "expected UUID version 7, got %d" (Uuidm.version uuid))
    | Some uuid -> Error (Printf.sprintf "invalid UUID variant %d" (Uuidm.variant uuid))
    | None -> Error "invalid UUID syntax"

module For_testing = struct
  let logical_ms_clock raw_now_ms =
    let clock = logical_ms_clock raw_now_ms in
    clock.now_ms, clock.advance
end

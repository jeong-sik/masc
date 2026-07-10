(* Bounded preview for identifier validation errors. These values originate from
   external requests/config/JSON, so emitting the full invalid value can amplify
   logs. *)
let preview_id s =
  if String.length s <= 32 then s
  else Printf.sprintf "%s… (%d bytes total)" (String.sub s 0 32) (String.length s)
;;

module Keeper_name = struct
  type t = string
  let is_valid s =
    let len = String.length s in
    s <> "." && s <> ".." && len > 0 && len <= 64 &&
    let rec check i =
      if i = len then true
      else
        let c = s.[i] in
        match c with
        | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' -> check (i + 1)
        | _ -> false
    in check 0

  let of_string s =
    if is_valid s then Ok s
    else
      let reason =
        if String.equal s "." then "reserved name '.'"
        else if String.equal s ".." then "reserved name '..'"
        else if String.length s = 0 then "empty string"
        else if String.length s > 64
        then Printf.sprintf "length %d exceeds 64" (String.length s)
        else "contains characters outside [A-Za-z0-9_-]"
      in
      Error
        (Printf.sprintf
           "Invalid keeper_name %S: %s"
           (preview_id s)
           reason)

  let to_string s = s
  let equal = String.equal
end

module Trace_id = struct
  type t = string
  let is_valid s =
    s <> "." && s <> ".." && Keeper_name.is_valid s
  let of_string s =
    if is_valid s then Ok s
    else (
      (* Branch on specific failure so operators see which constraint
         rejected the input rather than the bare label.  Order matches
         [is_valid]'s short-circuit evaluation. *)
      let reason =
        if String.equal s "." then "reserved name '.'"
        else if String.equal s ".." then "reserved name '..'"
        else if String.length s = 0 then "empty string"
        else if String.length s > 64
        then Printf.sprintf "length %d exceeds 64" (String.length s)
        else "contains characters outside [A-Za-z0-9_-]"
      in
      Error (Printf.sprintf "Invalid trace_id %S: %s" (preview_id s) reason))
  let to_string s = s
  let equal = String.equal
end

module Task_id = struct
  type t = string
  let is_valid s = String.length s > 0
  let of_string s =
    if is_valid s then Ok s
    else
      Error
        (Printf.sprintf "Invalid task_id %S: empty string" (preview_id s))
  let to_string s = s
  let equal = String.equal
end

module Uid = struct
  (** Stable unique identifier for a keeper, assigned once and never changed.
      Format: "keeper-<uuidv4>" (44 chars total).
      Uses [Uuidm.v4_gen] with an [Eio.Mutex]-protected RNG for fiber safety,
      following the same discipline as [Client_identity]. *)

  type t = string

  let prefix = "keeper-"

  let rng = Random.State.make_self_init ()
  let rng_mutex = Eio.Mutex.create ()
  let with_rng f = Eio.Mutex.use_ro rng_mutex (fun () -> f rng)

  let generate () =
    let uuid = with_rng (fun r -> Uuidm.v4_gen r ()) in
    prefix ^ Uuidm.to_string uuid

  let is_valid s =
    let plen = String.length prefix in
    String.length s = plen + 36
    && String.sub s 0 plen = prefix
    && (let uuid_str = String.sub s plen 36 in
        match Uuidm.of_string uuid_str with
        | Some _ -> true
        | None -> false)

  let of_string s =
    if is_valid s then Ok s
    else Error (Printf.sprintf "Invalid keeper uid format: '%s'" s)

  let to_string s = s
  let equal = String.equal
  let compare = String.compare

  let to_json s = `String s

  let of_json = function
    | `String s ->
        (match of_string s with
         | Ok t -> Ok t
         | Error e -> Error e)
    | other ->
        Error
          (Printf.sprintf "Expected string for Keeper_id.Uid (received %s)"
             (Json_util.kind_name other))
end

module For_testing = struct
  let unsafe_trace_id_of_string s = s
end

(** Polymorphic variants for use in keeper_meta without depending on a
    specific JSON library.  Callers wrap/unwrap at the boundary. *)
let uid_to_yojson s = `String s

let uid_of_yojson : [ `String of string | `Null ] -> (Uid.t, string) result =
  function
  | `String s ->
      (match Uid.of_string s with
       | Ok t -> Ok t
       | Error e -> Error e)
  | `Null -> Error "Expected non-null string for Keeper_id.Uid (received null)"

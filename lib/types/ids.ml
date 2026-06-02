(** MASC MCP Types - Newtypes (Prevent string mixups) *)

(** Agent identifier - prevents mixing with task_id, file_path, etc. *)
module Agent_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let generate () =
    let rng = Random.State.make_self_init () in
    Uuidm.v4_gen rng () |> Uuidm.to_string |> of_string
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Agent_id (received %s)"
             (Json_util.kind_name other))
end

(** Task identifier - prevents mixing with agent_id, etc. *)
module Task_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t  (* Auto-generate unique ID *)
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let _id_counter = Atomic.make 0
  let generate () =
    let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
    (* [fetch_and_add] atomically returns the pre-increment value, avoiding
       the [incr; get] split where two fibers can observe the same counter
       value and produce duplicate task IDs within the same millisecond. *)
    let seq = (Atomic.fetch_and_add _id_counter 1 + 1) land 0xFFFF in
    Printf.sprintf "task-%d-%04x" timestamp seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Task_id (received %s)"
             (Json_util.kind_name other))
end

(** Thread identifier - conversation thread ID *)
module Thread_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let _id_counter = Atomic.make 0
  let generate () =
    let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
    (* See Task_id.generate — [fetch_and_add] closes the split-atomic race
       so concurrent callers cannot produce duplicate IDs within the same
       millisecond. *)
    let seq = (Atomic.fetch_and_add _id_counter 1 + 1) land 0xFFFF in
    Printf.sprintf "thread-%d-%04x" timestamp seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Thread_id (received %s)"
             (Json_util.kind_name other))
end

(** Turn identifier - individual turn within a thread *)
module Turn_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : thread_id:string -> seq:int -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let generate ~thread_id ~seq =
    Printf.sprintf "%s-turn-%04d" thread_id seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Turn_id (received %s)"
             (Json_util.kind_name other))
end

(** Keeper identifier - deterministic UUIDv5 from namespace + name + path *)
module Keeper_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : name:string -> path:string -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
  module Trace_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
  module Task_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let generate ~name ~path =
    let input = Printf.sprintf "masc-keeper:%s:%s" name path in
    Uuidm.v5 Uuidm.ns_dns input |> Uuidm.to_string |> of_string
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Keeper_id (received %s)"
             (Json_util.kind_name other))
  module Keeper_name = struct
    type t = string
    let is_valid s =
      let len = String.length s in
      len > 0 && len <= 64 &&
      let rec check i =
        if i = len then true
        else
          let c = s.[i] in
          match c with
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' -> check (i + 1)
          | _ -> false
      in check 0
  end
  module Trace_id = struct
    type t = string
    let is_valid s = s <> "." && s <> ".." && Keeper_name.is_valid s

    (* Bounded preview for error messages — trace_id inputs originate
       from external requests / config files; full dump risks log
       spam on bad input. 32 bytes matches the pattern from iter#83
       [decode_global_id] (#16903). *)
    let preview s =
      if String.length s <= 32 then s
      else Printf.sprintf "%s… (%d bytes total)" (String.sub s 0 32) (String.length s)

    let of_string s =
      if is_valid s then Ok s
      else (
        (* Branch on the specific failure so operators see which
           constraint rejected the input rather than the bare label.
           Order matches [is_valid]'s short-circuit evaluation. *)
        let reason =
          if String.equal s "." then "reserved name '.'"
          else if String.equal s ".." then "reserved name '..'"
          else if String.length s = 0 then "empty string"
          else if String.length s > 64
          then Printf.sprintf "length %d exceeds 64" (String.length s)
          else "contains characters outside [A-Za-z0-9_-]"
        in
        Error (Printf.sprintf "Invalid trace_id %S: %s" (preview s) reason))
    let to_string s = s
    let equal = String.equal
  end
  module Task_id = struct
    type t = string
    let is_valid s = String.length s > 0

    (* Same 32-byte preview pattern as [Trace_id.preview] for log
       size bounding on external input. *)
    let preview s =
      if String.length s <= 32 then s
      else Printf.sprintf "%s… (%d bytes total)" (String.sub s 0 32) (String.length s)

    let of_string s =
      if is_valid s then Ok s
      else
        Error
          (Printf.sprintf "Invalid task_id %S: empty string" (preview s))
    let to_string s = s
    let equal = String.equal
  end
end

(** Credential identifier - random UUIDv4 *)
module Credential_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let generate () =
    let rng = Random.State.make_self_init () in
    Uuidm.v4_gen rng () |> Uuidm.to_string |> of_string
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Credential_id (received %s)"
             (Json_util.kind_name other))
end

(** Relay GraphQL-style global ID: base64("type:uuid") *)
let make_global_id ~type_ id =
  let raw = Printf.sprintf "%s:%s" type_ id in
  Base64.encode_string raw

let decode_global_id s =
  (* Truncate the input preview to bound log size when [s] is large
     (callers receive arbitrary strings from external systems). 32 bytes
     is enough to identify the shape (type prefix, length class) without
     dumping a full malicious payload into the error path. *)
  let preview =
    if String.length s <= 32 then s
    else Printf.sprintf "%s… (%d bytes total)" (String.sub s 0 32) (String.length s)
  in
  match Base64.decode s with
  | Ok decoded -> (
      match String.split_on_char ':' decoded with
      | type_ :: rest -> Ok (type_, String.concat ":" rest)
      | _ ->
        Error
          (Printf.sprintf
             "Invalid global ID format: decoded %S missing 'type:id' separator (input %S)"
             decoded
             preview))
  | Error (`Msg b64_msg) ->
    Error
      (Printf.sprintf
         "Invalid base64: %s (input %S)"
         b64_msg
         preview)

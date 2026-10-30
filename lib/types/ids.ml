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

(** Tool execution identifier — RFC-0233 canonical join key. One mint
    per tool execution at the dispatch boundary; every store that
    records the execution carries the same value. *)
module Execution_id : sig
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
    (* Same fetch_and_add discipline as [Task_id.generate]: two fibers in
       the same millisecond still get distinct sequence numbers. *)
    let seq = (Atomic.fetch_and_add _id_counter 1 + 1) land 0xFFFF in
    Printf.sprintf "exec-%d-%04x" timestamp seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for Execution_id (received %s)"
             (Json_util.kind_name other))
end

(** Turn reference — RFC-0233 §7. Canonical per-turn join key, derived
    deterministically from the [(trace_id, absolute_turn)] pair already
    recorded on {!Turn_record.t}. Serializes as ["<trace_id>#<absolute_turn>"]
    so keeper chat rows and board posts join on one stable value across
    reloads, with no mapping table. Distinct from {!Turn_id} (a
    thread-relative ["<thread>-turn-N"] label); the name collision is
    avoided on purpose. *)
module Turn_ref : sig
  type t
  val make : trace_id:string -> absolute_turn:int -> t
  val to_string : t -> string
  val of_string : string -> t option
  val trace_id : t -> string
  val absolute_turn : t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = { trace_id : string; absolute_turn : int }
  let make ~trace_id ~absolute_turn = { trace_id; absolute_turn }
  let to_string t = Printf.sprintf "%s#%d" t.trace_id t.absolute_turn
  (* Split on the LAST '#': the absolute_turn suffix is always an int, so a
     trace_id that itself contains '#' still parses unambiguously. *)
  let of_string s =
    match String.rindex_opt s '#' with
    | None -> None
    | Some i ->
      let trace = String.sub s 0 i in
      let suffix = String.sub s (i + 1) (String.length s - i - 1) in
      (match int_of_string_opt suffix with
       | Some absolute_turn when trace <> "" ->
         Some { trace_id = trace; absolute_turn }
       | Some _ | None -> None)
  let trace_id t = t.trace_id
  let absolute_turn t = t.absolute_turn
  let equal a b =
    String.equal a.trace_id b.trace_id && a.absolute_turn = b.absolute_turn
  let pp fmt t = Format.fprintf fmt "%s" (to_string t)
  let to_yojson t = `String (to_string t)
  let of_yojson = function
    | `String s -> (
      match of_string s with
      | Some t -> Ok t
      | None -> Error (Printf.sprintf "Invalid Turn_ref (received %S)" s))
    | other ->
      Error
        (Printf.sprintf "Expected string for Turn_ref (received %s)"
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



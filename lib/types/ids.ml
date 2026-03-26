(** MASC MCP Types - Newtypes (Prevent string mixups) *)

(** Agent identifier - prevents mixing with task_id, file_path, etc. *)
module Agent_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | _ -> Error "Expected string for Agent_id"
end

(** Task identifier - prevents mixing with agent_id, etc. *)
module Task_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val generate : unit -> t  (* Auto-generate unique ID *)
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let _id_counter = Atomic.make 0
  let generate () =
    let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
    Atomic.incr _id_counter;
    let seq = Atomic.get _id_counter land 0xFFFF in
    Printf.sprintf "task-%d-%04x" timestamp seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | _ -> Error "Expected string for Task_id"
end

(** Thread identifier - conversation thread ID *)
module Thread_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let _id_counter = Atomic.make 0
  let generate () =
    let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
    Atomic.incr _id_counter;
    let seq = Atomic.get _id_counter land 0xFFFF in
    Printf.sprintf "thread-%d-%04x" timestamp seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | _ -> Error "Expected string for Thread_id"
end

(** Turn identifier - individual turn within a thread *)
module Turn_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val generate : thread_id:string -> seq:int -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end = struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let generate ~thread_id ~seq =
    Printf.sprintf "%s-turn-%04d" thread_id seq
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | _ -> Error "Expected string for Turn_id"
end

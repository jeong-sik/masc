(** MASC MCP Types - Newtypes (Prevent string mixups) *)

(** What every string-backed ID shares: the string itself, written as a JSON
    string. [Kind.kind] names the ID in the error [of_yojson] returns for a
    value that is not a JSON string. The signatures, with [t] abstract, are in
    [ids.mli]. *)
module String_id (Kind : sig
  val kind : string
end) =
struct
  type t = string
  let of_string s = s
  let to_string t = t
  let equal = String.equal
  let pp fmt t = Format.fprintf fmt "%s" t
  let to_yojson t = `String t
  let of_yojson = function
    | `String s -> Ok s
    | other ->
        Error
          (Printf.sprintf "Expected string for %s (received %s)" Kind.kind
             (Json_util.kind_name other))
end

(** A string ID minted as ["<prefix>-<ms>-<seq>"]. Every application of the
    functor owns its counter. [Atomic.fetch_and_add] returns the
    pre-increment value in one step, so two fibers in the same millisecond
    cannot read the same counter value and mint the same ID, as an [incr]
    followed by a [get] would let them. *)
module Sequenced_id (Spec : sig
  val kind : string
  val prefix : string
end) =
struct
  include String_id (Spec)
  let counter = Atomic.make 0
  let generate () =
    let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
    let seq = (Atomic.fetch_and_add counter 1 + 1) land 0xFFFF in
    Printf.sprintf "%s-%d-%04x" Spec.prefix timestamp seq
end

let new_uuid_v4 () =
  let rng = Random.State.make_self_init () in
  Uuidm.v4_gen rng () |> Uuidm.to_string

(** Agent identifier - prevents mixing with task_id, file_path, etc. *)
module Agent_id = struct
  include String_id (struct let kind = "Agent_id" end)
  let generate () = new_uuid_v4 () |> of_string
end

(** Task identifier - prevents mixing with agent_id, etc. *)
module Task_id = Sequenced_id (struct
  let kind = "Task_id"
  let prefix = "task"
end)

(** Tool execution identifier — RFC-0233 canonical join key. One mint
    per tool execution at the dispatch boundary; every store that
    records the execution carries the same value. *)
module Execution_id = Sequenced_id (struct
  let kind = "Execution_id"
  let prefix = "exec"
end)

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
module Thread_id = Sequenced_id (struct
  let kind = "Thread_id"
  let prefix = "thread"
end)

(** Turn identifier - individual turn within a thread *)
module Turn_id = struct
  include String_id (struct let kind = "Turn_id" end)
  let generate ~thread_id ~seq = Printf.sprintf "%s-turn-%04d" thread_id seq
end

(** Keeper identifier - deterministic UUIDv5 from namespace + name + path *)
module Keeper_id = struct
  include String_id (struct let kind = "Keeper_id" end)
  let generate ~name ~path =
    let input = Printf.sprintf "masc-keeper:%s:%s" name path in
    Uuidm.v5 Uuidm.ns_dns input |> Uuidm.to_string |> of_string
end

(** Credential identifier - random UUIDv4 *)
module Credential_id = struct
  include String_id (struct let kind = "Credential_id" end)
  let generate () = new_uuid_v4 () |> of_string
end

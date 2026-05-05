module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_suspend - Agent suspension and circuit breaker tools

    Implements masc_suspend handler and circuit breaker check_can_join.
    Part of MASC Social v4 Tier 1 security layer.

    @since 0.6.0
*)

(** {1 Context} *)

type context =
  { config : Coord.config
  ; caller_agent : string option (** Who is calling the tool *)
  }

(** {1 Blacklist Management} *)

(** Blacklist entry: agent_id -> until timestamp *)
let blacklist : (string, float * string) Hashtbl.t = Hashtbl.create 32

let blacklist_lock = Eio.Mutex.create ()

let add_to_blacklist ~agent_id ~until ~reason =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    Hashtbl.replace blacklist agent_id (until, reason))
;;

let check_blacklist ~agent_id =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    let now = Time_compat.now () in
    (* Bulk prune expired entries when table accumulates beyond 32 *)
    if Hashtbl.length blacklist > 32
    then
      Hashtbl.filter_map_inplace
        (fun _id (until, reason) -> if Stdlib.Float.compare now until >= 0 then None else Some (until, reason))
        blacklist;
    match Hashtbl.find_opt blacklist agent_id with
    | None -> None
    | Some (until, reason) ->
      if Stdlib.Float.compare now until >= 0
      then (
        Hashtbl.remove blacklist agent_id;
        None)
      else Some (until, reason))
;;

let remove_from_blacklist ~agent_id =
  Eio.Mutex.use_rw ~protect:true blacklist_lock (fun () ->
    Hashtbl.remove blacklist agent_id)
;;

(** {1 Coord Operations} *)

(** Check if agent is in the current room *)
let is_agent_in_room config ~agent_id =
  let state = Coord.read_state config in
  List.mem agent_id state.Masc_domain.active_agents
;;

(** Force an agent to leave the room (uses Coord.update_state for consistency) *)
let force_leave config ~agent_id ~reason =
  (* Use update_state for atomic read-modify-write (same pattern as Coord.leave) *)
  let _ =
    Coord.update_state config (fun s ->
      { s with Masc_domain.active_agents = List.filter (fun a -> not (String.equal a agent_id)) s.active_agents })
  in
  (* Broadcast the forced leave *)
  let message =
    Printf.sprintf "[SYSTEM] Agent '%s' forcibly removed: %s" agent_id reason
  in
  try
    ignore (Coord.broadcast config ~from_agent:"system" ~content:message)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.error "broadcast (force leave) exception: %s" (Stdlib.Printexc.to_string exn)
;;

(** masc_suspend removed: pruned from surfaces. *)

let schemas : Masc_domain.tool_schema list = []

(** {1 Dispatch} *)

let dispatch _ctx ~name:_ ~args:_ = None

(** {1 Blacklist Check for Join} *)

(** Call this before allowing an agent to join.
    Returns Error with message if blacklisted. *)
let check_can_join ~agent_id =
  match check_blacklist ~agent_id with
  | None ->
    (* Also check circuit breaker *)
    Circuit_breaker.check_global ~agent_id
  | Some (until, reason) ->
    let remaining = Stdlib.Int.of_float (until -. Time_compat.now ()) in
    Error
      (Printf.sprintf
         "Agent '%s' is suspended for %d more seconds. Reason: %s"
         agent_id
         remaining
         reason)
;;

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_requires_join = [ "masc_suspend" ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
       Tool_spec.register
         (Tool_spec.create
            ~name:s.name
            ~description:s.description
            ~module_tag:Tool_dispatch.Mod_suspend
            ~input_schema:s.input_schema
            ~handler_binding:Tag_dispatch
            ~requires_join:(List.mem s.name _tool_spec_requires_join)
            ~visibility:Tool_catalog.Hidden
            ~allow_direct_call_when_hidden:true
            ()))
    schemas
;;

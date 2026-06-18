(** Cognitive Gravity Event Bus — Phase4 GC Trigger Wiring

    Three-layer architecture:
    1. {!decay_trigger} — typed trigger variants that signal decay conditions.
    2. {!decay_event} — a concrete event emitted when a trigger fires.
    3. {!register_trigger} / {!dispatch} / {!emit} — the registry pattern.

    BLOCKER A fix: uses ordered list instead of Hashtbl to guarantee
    registration-order dispatch.
    BLOCKER B fix: wires custom equal_decay_trigger for trigger matching.
    BLOCKER 1 fix: re-raises Eio.Cancel.Cancelled instead of absorbing it.
    BLOCKER 2 fix: matches on constructor only, not full payload values. *)

(* ------------------------------------------------------------------ *)
(* Types — matches .mli exactly                                       *)
(* ------------------------------------------------------------------ *)

type decay_trigger =
  | TurnElapsed of { age : int; min_age : int }
  | NoNewMentions of { turns : int; min_idle : int }
  | Contradiction of { fact_id : string; staleness : float }
  | ManualDecay of { fact_ids : string list; rate : float }
[@@deriving show]

type decay_event = {
  trigger : decay_trigger;
  target_fact_ids : string list;
  delta : float;
  applied_at_turn : int;
}

(* ------------------------------------------------------------------ *)
(* Trigger constructor matching — matches on variant only, not        *)
(* payload values (BLOCKER 2 fix). Used for dispatch/emit to find     *)
(* handlers registered for a trigger *type*, not a specific value.    *)
(* ------------------------------------------------------------------ *)

let trigger_constructor (t : decay_trigger) : decay_trigger =
  match t with
  | TurnElapsed _ -> TurnElapsed { age = 0; min_age = 0 }
  | NoNewMentions _ -> NoNewMentions { turns = 0; min_idle = 0 }
  | Contradiction _ -> Contradiction { fact_id = ""; staleness = 0.0 }
  | ManualDecay _ -> ManualDecay { fact_ids = []; rate = 0.0 }

(* ------------------------------------------------------------------ *)
(* Registry — ordered list preserves insertion order (BLOCKER A)      *)
(* ------------------------------------------------------------------ *)

type handler = decay_event -> unit

let registry : (decay_trigger * handler) list ref = ref []
let mutable_events : decay_event list ref = ref []
let turn_counter : int ref = ref 0
let default_setup_done : bool ref = ref false

let rec ensure_dir path =
  if path = "" || path = Filename.current_dir_name
  then ()
  else if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then invalid_arg (Printf.sprintf "not a directory: %s" path))
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
      if not (Sys.file_exists path && Sys.is_directory path)
      then invalid_arg (Printf.sprintf "not a directory: %s" path))

(* ------------------------------------------------------------------ *)
(* Registration — prepend for O(1); dispatch iterates in reverse      *)
(* (i.e. registration order)                                          *)
(* ------------------------------------------------------------------ *)

let register_trigger trigger ~handler =
  registry := (trigger, handler) :: !registry

let invoke_handler handler event =
  try handler event
  with Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.warn
           "cognitive_gravity_event_bus: handler raised: %s"
           (Printexc.to_string exn)

(* ------------------------------------------------------------------ *)
(* Dispatch — evaluate all registered triggers, return events         *)
(* ------------------------------------------------------------------ *)

let dispatch () =
  let all = List.rev !registry in
  let events =
    List.filter_map (fun (registered, handler) ->
      let event =
        match registered with
        | TurnElapsed { age; min_age } when age >= min_age ->
          Some { trigger = registered; target_fact_ids = []; delta = 0.02; applied_at_turn = !turn_counter }
        | NoNewMentions { turns; min_idle } when turns >= min_idle ->
          Some { trigger = registered; target_fact_ids = []; delta = 0.05; applied_at_turn = !turn_counter }
        | Contradiction { fact_id; staleness } when staleness > 0.0 ->
          Some { trigger = registered; target_fact_ids = [fact_id]; delta = 0.10 *. staleness; applied_at_turn = !turn_counter }
        | ManualDecay { fact_ids; rate } when fact_ids <> [] && rate > 0.0 ->
          Some { trigger = registered; target_fact_ids = fact_ids; delta = rate; applied_at_turn = !turn_counter }
        | _ -> None
      in
      Option.iter (invoke_handler handler) event;
      event
    ) all
  in
  mutable_events := events;
  turn_counter := !turn_counter + 1;
  events

(* ------------------------------------------------------------------ *)
(* Emit — fire handlers whose trigger *constructor* matches, in       *)
(* registration order. Uses trigger_constructor to match on variant    *)
(* only, not payload values (BLOCKER 2 fix).                          *)
(* ------------------------------------------------------------------ *)

let emit event =
  let event_ctor = trigger_constructor event.trigger in
  let matching =
    List.filter (fun (registered, _handler) ->
      trigger_constructor registered = event_ctor)
      !registry
  in
  let matching_rev = List.rev matching in
  List.iter (fun (_registered, handler) -> invoke_handler handler event) matching_rev

(* ------------------------------------------------------------------ *)
(* Default delta values                                               *)
(* ------------------------------------------------------------------ *)

let default_delta = function
  | TurnElapsed _ -> 0.02
  | NoNewMentions _ -> 0.05
  | Contradiction { staleness; _ } -> 0.10 *. staleness
  | ManualDecay { rate; _ } -> rate

(* ------------------------------------------------------------------ *)
(* Default target fact IDs                                            *)
(* ------------------------------------------------------------------ *)

let default_target_fact_ids = function
  | TurnElapsed _ -> []
  | NoNewMentions _ -> []
  | Contradiction { fact_id; _ } -> [fact_id]
  | ManualDecay { fact_ids; _ } -> fact_ids

(* ------------------------------------------------------------------ *)
(* Default log handler                                                *)
(* ------------------------------------------------------------------ *)

let default_log_handler store_base_path event =
  try
    let dir =
      Filename.concat
        (Filename.concat store_base_path "data")
        "cognitive-gravity-events"
    in
    ensure_dir dir;
    (* NDT-OK: wall-clock filename buckets append-only event logs; the persisted
       row payload below is derived from the explicit decay event. *)
    let date_str = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
    let filename = Filename.concat dir (Printf.sprintf "events-%s.jsonl" date_str) in
    let trigger =
      match event.trigger with
      | TurnElapsed _ -> "TurnElapsed"
      | NoNewMentions _ -> "NoNewMentions"
      | Contradiction _ -> "Contradiction"
      | ManualDecay _ -> "ManualDecay"
    in
    let json =
      `Assoc
        [ "trigger", `String trigger
        ; "target_fact_ids", `List (List.map (fun id -> `String id) event.target_fact_ids)
        ; "delta", `Float event.delta
        ; "applied_at_turn", `Int event.applied_at_turn
        ]
    in
    let line = Yojson.Safe.to_string json ^ "\n" in
    let oc = open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 filename in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc line)
  with _ -> ()

(* ------------------------------------------------------------------ *)
(* Default triggers                                                   *)
(* ------------------------------------------------------------------ *)

module Default_triggers = struct
  let setup ~store_base_path =
    if not !default_setup_done then (
      default_setup_done := true;
      let log_handler = default_log_handler store_base_path in
      register_trigger (TurnElapsed { age = 0; min_age = 3 }) ~handler:log_handler;
      register_trigger (NoNewMentions { turns = 0; min_idle = 5 }) ~handler:log_handler;
      register_trigger (Contradiction { fact_id = ""; staleness = 0.0 }) ~handler:log_handler;
      register_trigger (ManualDecay { fact_ids = []; rate = 0.0 }) ~handler:log_handler)
end

let run_gc ~base_path =
  Default_triggers.setup ~store_base_path:base_path;
  let (_events : decay_event list) = dispatch () in
  ()

module For_testing = struct
  let reset () =
    registry := [];
    mutable_events := [];
    turn_counter := 0;
    default_setup_done := false
end

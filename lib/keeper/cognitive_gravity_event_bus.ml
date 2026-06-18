(** Cognitive Gravity Event Bus — Phase4 GC Trigger Wiring

    Three-layer architecture:
    1. {!decay_trigger} — typed trigger variants that signal decay conditions.
    2. {!decay_event} — a concrete event emitted when a trigger fires.
    3. {!register_trigger} / {!dispatch} / {!emit} — the registry pattern.

    BLOCKER A fix: uses ordered list instead of Hashtbl to guarantee
    registration-order dispatch.
    BLOCKER B fix: wires custom equal_decay_trigger for trigger matching. *)

open Core

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
(* Custom equality — needed because polymorphic compare fails on      *)
(* float and string list fields (BLOCKER B)                            *)
(* ------------------------------------------------------------------ *)

let equal_decay_trigger (a : decay_trigger) (b : decay_trigger) =
  match a, b with
  | TurnElapsed { age = a1; min_age = a2 }, TurnElapsed { age = b1; min_age = b2 } ->
    Int.(a1 = b1 && a2 = b2)
  | NoNewMentions { turns = a1; min_idle = a2 }, NoNewMentions { turns = b1; min_idle = b2 } ->
    Int.(a1 = b1 && a2 = b2)
  | Contradiction { fact_id = a; staleness = b }, Contradiction { fact_id = a'; staleness = b' } ->
    String.(a = a') && Float.(b = b')
  | ManualDecay { fact_ids = a; rate = b }, ManualDecay { fact_ids = a'; rate = b' } ->
    List.equal String.equal a a' && Float.(b = b')
  | _, _ -> false

(* ------------------------------------------------------------------ *)
(* Registry — ordered list preserves insertion order (BLOCKER A)      *)
(* ------------------------------------------------------------------ *)

type handler = decay_event -> unit

let registry : (decay_trigger * handler) list ref = ref []
let mutable_events : decay_event list ref = ref []
let turn_counter : int ref = ref 0

(* ------------------------------------------------------------------ *)
(* Registration — prepend for O(1); dispatch iterates in reverse      *)
(* (i.e. registration order)                                          *)
(* ------------------------------------------------------------------ *)

let register_trigger trigger ~handler =
  registry := (trigger, handler) :: !registry

(* ------------------------------------------------------------------ *)
(* Dispatch — evaluate all registered triggers, return events         *)
(* ------------------------------------------------------------------ *)

let dispatch () =
  let all = List.rev !registry in
  let events =
    List.filter_map all ~f:(fun (registered, _handler) ->
      match registered with
      | TurnElapsed { age; min_age } when age >= min_age ->
        Some { trigger = registered; target_fact_ids = []; delta = 0.02; applied_at_turn = !turn_counter }
      | NoNewMentions { turns; min_idle } when turns >= min_idle ->
        Some { trigger = registered; target_fact_ids = []; delta = 0.05; applied_at_turn = !turn_counter }
      | Contradiction { fact_id; staleness } when staleness > 0.0 ->
        Some { trigger = registered; target_fact_ids = [fact_id]; delta = 0.10 *. staleness; applied_at_turn = !turn_counter }
      | ManualDecay { fact_ids; rate } ->
        Some { trigger = registered; target_fact_ids = fact_ids; delta = rate; applied_at_turn = !turn_counter }
      | _ -> None
    )
  in
  mutable_events := events;
  turn_counter := !turn_counter + 1;
  events

(* ------------------------------------------------------------------ *)
(* Emit — push a decay event into the processing pipeline             *)
(* ------------------------------------------------------------------ *)

let emit event =
  let matching =
    List.filter !registry ~f:(fun (registered, _handler) ->
      equal_decay_trigger registered event.trigger)
  in
  let matching_rev = List.rev matching in
  List.iter matching_rev ~f:(fun (_registered, handler) ->
    try handler event
    with exn ->
      Log.warn ~mod_name:"cognitive_gravity_event_bus" ~msg:"emit handler raised"
        ~metadata:[("exn", Exn.to_string exn)]
  )

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
    let dir = Filename.concat store_base_path "cognitive-gravity-events" in
    let _ = Unix.mkdir dir in
    let date_str = Time.now () |> Time.to_string in
    let filename = Filename.concat dir (Printf.sprintf "events-%s.jsonl" date_str) in
    let json = String.concat ~sep:","
      [ "\"trigger\":\"" ^ (match event.trigger with
          | TurnElapsed _ -> "TurnElapsed"
          | NoNewMentions _ -> "NoNewMentions"
          | Contradiction _ -> "Contradiction"
          | ManualDecay _ -> "ManualDecay") ^ "\""
      ; "\"target_fact_ids\":" ^ (event.target_fact_ids |> List.map ~f:(fun id -> "\"" ^ id ^ "\"") |> String.concat ~sep:"," |> fun s -> "[" ^ s ^ "]")
      ; "\"delta\":" ^ Float.to_string event.delta
      ; "\"applied_at_turn\":" ^ Int.to_string event.applied_at_turn
      ]
    in
    let line = "{" ^ json ^ "}\n" in
    Out_channel.append_lines filename [line]
  with _ -> ()

(* ------------------------------------------------------------------ *)
(* Default triggers                                                   *)
(* ------------------------------------------------------------------ *)

module Default_triggers = struct
  let setup ~store_base_path =
    let log_handler = default_log_handler store_base_path in
    register_trigger (TurnElapsed { age = 0; min_age = 3 }) ~handler:log_handler;
    register_trigger (NoNewMentions { turns = 0; min_idle = 5 }) ~handler:log_handler;
    register_trigger (Contradiction { fact_id = ""; staleness = 0.0 }) ~handler:log_handler;
    register_trigger (ManualDecay { fact_ids = []; rate = 0.0 }) ~handler:log_handler
end
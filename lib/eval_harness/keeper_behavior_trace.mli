(** Keeper_behavior_trace — shadow trace harness foundation (P3-2).

    A shadow trace is a deterministic, replayable record of keeper tool
    invocations used to regression-test identity, surface, and descriptor
    behavior.  This module provides the data model, selectors, and JSON
    serialization.  Dashboard [behavioral_rails] and CI replay ratchets are
    deliberate follow-ups. *)

type event =
  { agent : string
  ; turn : int
  ; tool : string
  ; arguments : Yojson.Safe.t
  }
(** A single tool-invocation event in a keeper turn. *)

type fixture =
  { name : string
  ; identity : string
  ; surface : string list
  ; events : event list
  }
(** A replay fixture: fixed identity, fixed allowed tool surface, and the
    expected event sequence. *)

type selector =
  | Any
  | Tool of string
  | Agent of string
  | Turn_range of int * int
(** Descriptor-aware selector. [Tool name] matches the canonical tool name;
    [Agent name] matches the agent field; [Turn_range (lo, hi)] matches turns
    inclusive. *)

val select : selector -> event list -> event list
(** Filter events by selector. *)

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result

val fixture_to_json : fixture -> Yojson.Safe.t
val fixture_of_json : Yojson.Safe.t -> (fixture, string) result

(** Worker_tool_input — shared JSON helpers for Agent SDK tool
    input parsing.

    Every helper expects the top-level [json] to be a JSON object
    ([`Assoc _]); a [`null] / [`String _] / [`Int _] / array
    surfaces as [Error "input must be a JSON object"] (for the
    Result-typed accessors) or [None] (for {!extract_float}).

    Field-shape errors carry the offending key in the message so
    the agent's error log surfaces which input was malformed.
    The exact wording is part of the contract — operator dashboards
    grep these strings to triage tool-input mismatches. *)

val json_to_string : Yojson.Safe.t -> string
(** Pretty-print [json] via [Yojson.Safe.pretty_to_string]. Used
    for diagnostic logging where the call site already has the
    full input value. *)

val extract_string :
  string ->
  Yojson.Safe.t ->
  (string, string) result
(** Pull a required [`String _] field at [key] from a JSON
    object.

    @return [Ok s] on a string match,
            [Error "<key> must be a string"] when the field is
            present but a different shape,
            [Error "missing required field: <key>"] when the
            field is absent,
            [Error "input must be a JSON object"] when the
            top-level value is not an object. *)

val extract_optional_string :
  string ->
  Yojson.Safe.t ->
  (string option, string) result
(** Like {!extract_string} but treats both absence and explicit
    [`Null] as [Ok None]. A non-string non-null value still
    surfaces as [Error "<key> must be a string"]. *)

val extract_tasks_array :
  Yojson.Safe.t ->
  ((string * string) list, string) result
(** Decode the [tasks] field as a non-empty JSON array of
    [{ "title": string; "description": string }] objects, in
    input order. Empty array surfaces as
    [Error "tasks must be a non-empty JSON array"]. The first
    item-level error short-circuits with that error verbatim
    (no aggregation). *)

val extract_float :
  string ->
  Yojson.Safe.t ->
  float option
(** Pull a numeric field at [key], coercing [`Int n] to
    [Float.of_int n]. Returns [None] for any other shape, an
    absent key, or a non-object top-level value — callers that
    need to distinguish "missing" from "wrong type" should use
    a stricter [(float, string) result] helper instead (none
    exists yet). *)

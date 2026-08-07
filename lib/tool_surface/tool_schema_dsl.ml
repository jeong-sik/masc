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

(** Tool_schema_dsl — shared JSON Schema builder helpers for MCP tool definitions.

    Reduces per-property boilerplate from ~5 lines of raw Yojson.Safe.t
    to 1 line. Consolidated from duplicate definitions in
    Sdk_tool_contract. *)

let string_prop description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun k -> `String k) required));
      ("additionalProperties", `Bool false);
    ]

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

(** Board_core_classify — Post visibility/kind converters and classification.

    Contains exact conversion helpers and post-kind accessors.

    @since God file decomposition — extracted from board_core.ml *)

include Board_types

let visibility_to_string = function
  | Public -> "public"
  | Unlisted -> "unlisted"
  | Internal -> "internal"
  | Direct -> "direct"

let visibility_of_string = function
  | "public" -> Some Public
  | "unlisted" -> Some Unlisted
  | "internal" -> Some Internal
  | "direct" -> Some Direct
  | _ -> None

(** Issue #8392: schema enums for [visibility] used to be hand-rolled
    in [board_tool.ml:699], matching the same drift class as #8354
    (task_status), #8372 (agent_status), #8386 (agent_role). All
    constructors are nullary so the simple [List.map] trick works.
    Adding a 5th constructor will fail compilation in
    [visibility_to_string] and in the test asserts. *)
let all_visibilities = [ Public; Unlisted; Internal; Direct ]
let valid_visibility_strings =
  List.map visibility_to_string all_visibilities

let post_kind_to_string = function
  | Human_post -> "direct"
  | Automation_post -> "automation"
  | System_post -> "system"

let post_kind_of_string = function
  | "direct" -> Some Human_post
  | "automation" -> Some Automation_post
  | "system" -> Some System_post
  | _ -> None


(** Take at most [n] elements from a list. *)
let take = List.take

let classify_post_kind (p : post) = p.post_kind

let post_classification_reason (p : post) =
  match p.meta_json with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "classification_reason" fields with
     | Some (`String reason) when not (String.equal (String.trim reason) "") ->
       Some reason
     | Some _ | None -> None)
  | Some _ | None -> None
;;

let post_matches_filters ~exclude_system ~exclude_automation (p : post) =
  let kind = p.post_kind in
  (not exclude_system || not ((=) kind System_post))
  && (not exclude_automation || not ((=) kind Automation_post))

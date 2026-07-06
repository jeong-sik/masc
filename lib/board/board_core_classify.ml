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

(** Board_core_classify — Post visibility/kind converters and accessors.

    Contains conversion helpers, classification reason rendering, and the
    reclassify_report type used by filesystem backends.

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

let meta_source = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "source" fields with
      | Some (`String source) ->
          let source = String.lowercase_ascii (String.trim source) in
          if String.equal source "" then None else Some source
      | _ -> None)
  | _ -> None

let meta_field meta_json key =
  match meta_json with
  | Some (`Assoc fields) -> List.assoc_opt key fields
  | _ -> None

let nonempty_json_string = function
  | `String value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | _ -> None

let judgment_reason = function
  | `String _ as value -> nonempty_json_string value
  | `Assoc fields ->
      let find keys =
        List.find_map
          (fun key ->
             match List.assoc_opt key fields with
             | Some value -> nonempty_json_string value
             | None -> None)
          keys
      in
      find [ "summary"; "reason"; "classification_reason" ]
  | _ -> None

let meta_explicit_classification_reason meta_json =
  match
    (match meta_field meta_json "classification_reason" with
     | Some value -> nonempty_json_string value
     | None -> None)
  with
  | Some _ as reason -> reason
  | None ->
      [ "judgment"; "judgement" ]
      |> List.find_map (fun key ->
             match meta_field meta_json key with
             | Some value -> judgment_reason value
             | None -> None)

let classify_post_kind (p : post) = p.post_kind

let post_classification_reason (p : post) =
  match meta_explicit_classification_reason p.meta_json with
  | Some reason -> reason
  | None ->
      let author = Agent_id.to_string p.author in
      match p.post_kind, meta_source p.meta_json with
      | Human_post, Some "dashboard_board_post" ->
          "Direct board post created from the dashboard without automation override."
      | Human_post, Some source ->
          Printf.sprintf
            "Direct board post without automation override (source=%s)." source
      | Human_post, None ->
          "Direct board post without automation provenance."
      | Automation_post, Some (("agent_board_post" | "keeper_board_post") as source) ->
          Printf.sprintf
            "Automation classification based on source=%s, author=%s, and the automation post_kind contract."
            source author
      | Automation_post, Some "dashboard_board_post" ->
          "Dashboard board post classified as automation by explicit post_kind contract."
      | Automation_post, Some source ->
          Printf.sprintf "Automation provenance source: %s." source
      | Automation_post, None ->
          "Automation post preserved by explicit board post_kind contract."
      | System_post, _ ->
          "System post reserved for platform or operator authored messages."

let post_matches_filters ~exclude_system ~exclude_automation (p : post) =
  let kind = p.post_kind in
  (not exclude_system || not ((=) kind System_post))
  && (not exclude_automation || not ((=) kind Automation_post))

type reclassify_report = {
  backend : string;
  dry_run : bool;
  scanned : int;
  changed : int;
  unchanged : int;
  skipped : int;
  apply_failures : int;
  changed_post_ids : string list;
  invalid_post_ids : string list;
}

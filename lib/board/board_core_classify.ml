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

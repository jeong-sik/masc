(** Exact Board visibility and post-kind wire conversions. *)

include module type of struct
  include Board_types
end

val take : int -> 'a list -> 'a list

val visibility_to_string : visibility -> string
val visibility_of_string : string -> visibility option
val all_visibilities : visibility list
val valid_visibility_strings : string list

val post_kind_to_string : post_kind -> string
val post_kind_of_string : string -> post_kind option

val classify_post_kind : post -> post_kind
val post_classification_reason : post -> string option

val post_matches_filters :
  exclude_system:bool -> exclude_automation:bool -> post -> bool

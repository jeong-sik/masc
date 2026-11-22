(** Shared viewport scrolling and index clamping helpers across all TUI domain
    sub-stores. *)

val default_viewport_rows : int
(** Default visible row budget ([15]) used when a caller does not supply an
    explicit [viewport_rows]. *)

val clamp_index : int -> int -> int
(** Clamp [idx] into [[0; len - 1]], returning [0] whenever [len <= 0]. *)

val adjust_scroll : ?viewport_rows:int -> scroll:int -> int -> int
(** Symmetric viewport scroll adjustment: pulls [scroll] up when [selected]
    moves above the top edge, pushes [scroll] down when [selected] moves past
    the bottom edge, and holds [scroll] steady inside the viewport. *)

val adjust_grouped_scroll :
  ?viewport_rows:int -> scroll:int -> header_row:int -> int -> int
(** Grouped-list scroll adjustment that restores a group's [header_row] when
    moving back to its first member or index [0]. *)

val clamp_scroll : ?max_scroll:int -> int -> int
(** Clamp a free-scroll offset into [[0; max_scroll]] (or [[0; +inf)] when
    [max_scroll] is omitted). *)

val contains_ci : needle:string -> string -> bool
(** Case-insensitive ASCII substring search shared across store filters. *)

val drop : int -> 'a list -> 'a list
(** Drop the first [n] elements of a list (returns the input unchanged when
    [n <= 0], and [[]] when [n >= List.length xs]). *)

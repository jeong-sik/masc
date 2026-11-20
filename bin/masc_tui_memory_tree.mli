(** Hierarchical Memory UI components: mode strip, semantic category badges,
    World -> Shared -> Keeper summary card, and Memory category tree sidebar.

    Pure by construction: no terminal I/O, no mutation, no unhandled
    exceptions. *)

val memory_mode_strip :
  ?lead:string ->
  ko:bool ->
  cols:int ->
  active:[ `Recent | `Retrieved | `Changes | `Storage ] ->
  unit ->
  string
(** Numbered sub-mode strip ([1:최근 2:조회 3:변화 4:저장]) aligned 1:1 with the
    digit shortcuts bound in [Masc_tui]. *)

val category_badge :
  ko:bool -> Masc.Keeper_memory_os_types.category -> string * string
(** Crisp category label (without middle-truncation mangling) paired with its
    semantic SGR style (never {!Masc_tui_ansi.Theme.info}). *)

val filter_badge :
  ko:bool -> Masc_tui_types.memory_category_filter -> string * string
(** Badge label and SGR style for any category filter entry. *)

val world_hierarchy_card :
  ko:bool ->
  width:int ->
  world:Masc_tui_memory_world.reading ->
  health:Masc.Tui_decode_memory_health.memory_health_snapshot option ->
  unit:Masc_tui_memory_usage.display_unit ->
  string list
(** Fixed-height framed card linking Workspace World/Shared claims to Keeper
    fleet memory totals. Returns [[]] when [width < Masc_tui_card.min_width]. *)

val sidebar_tree_rows :
  ko:bool ->
  width:int ->
  height:int ->
  world:Masc_tui_memory_world.reading ->
  selected:Masc_tui_types.memory_category_filter ->
  entries:(Masc_tui_types.memory_category_filter * int option) list ->
  (Masc_tui_types.memory_category_filter option * string) list
(** Renders the hierarchical sidebar linking World/Shared root state to each
    filterable Keeper memory category branch with counts and selection state. *)

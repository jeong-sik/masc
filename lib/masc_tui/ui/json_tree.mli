(** Structured, collapsible, syntax-colored JSON tree widget over
    {!Yojson.Safe.t} — permanently replacing raw monochrome JSON dumps. *)

module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid

type value_display =
  | Object_node of { count : int }
  | Array_node of { count : int }
  | String_val of string
  | Redacted_secret
  | Int_val of int
  | Float_val of float
  | Bool_val of bool
  | Null_val

type line = {
  path : string;        (** Stable dot-separated path (e.g. ["$.runtime.slots[0]"]). *)
  depth : int;
  key : string option;
  collapsible : bool;
  expanded : bool;
  value : value_display;
}

val equal_value_display : value_display -> value_display -> bool
val equal_line : line -> line -> bool

val is_secret_key : string -> bool
(** [true] for key names indicating sensitive credentials (e.g. [api_key],
    [x-api-key], [access_token], [secret], [password], [passphrase],
    [credential], [authorization], [bearer], [pat]), while excluding LLM
    token telemetry ([input_tokens], [output_tokens], [cache_read_tokens],
    [max_tokens], [tokens_per_sec], [token_usage]) and non-secret pointer keys
    ([api_key_env], [token_file], [secret_path]). *)

val is_secret_value : string -> bool
(** [true] for string values matching structural secret patterns (e.g. [sk-...],
    [ghp_/gho_/ghu_/ghs_/ghr_/github_pat_...], [AKIA...], [xoxb-...],
    [Bearer ...], embedded URL credentials [://user:pass@], PEM private keys). *)

val toggle_path : string -> collapsed:string list -> string list
(** Toggle a node's collapsed state in an immutable path list. *)

val flatten :
  ?max_depth:int ->
  ?collapsed:string list ->
  ?redact_secrets:bool ->
  Yojson.Safe.t ->
  line list
(** Project a {!Yojson.Safe.t} document into visible collapsible tree rows.
    Nodes in [collapsed] or at depth [>= max_depth] render as compact
    summaries ([{N keys}] / [[N items]]). *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?scroll:int ->
  ?selected:int ->
  line list ->
  int
(** Paint flattened JSON tree lines directly onto [Cell_grid.t] with theme
    syntax coloring and geometric fold indicators. Returns total line count. *)

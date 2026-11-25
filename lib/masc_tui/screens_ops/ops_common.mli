(** Shared pure rendering helpers, v2.5 spatial rhythm & 4-tier typography
    utilities, 3-channel SSOT status projections, OSC 8 reference formatting,
    and compact bilingual utilities for Operations screens ([Keepers] and
    [Work]). *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

val theme_of_model : Model.t -> Theme.t
val default_caps : Presenter.capabilities
val say : Model.t -> ko:string -> en:string -> string
val contains_ci : needle:string -> string -> bool

val layout_bp : Model.t -> Layout.breakpoint
(** Project {!Model.breakpoint} onto {!Layout.breakpoint}. *)

val pad_x_for : model:Model.t -> Rect.t -> int
(** Responsive card inner horizontal padding: [2] on Wide/Standard cards, [1]
    on Compact/narrow cards, [0] on ultra-tight test rects ([w < 20]). *)

val put_line :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  max_w:int ->
  style:Style.t ->
  string ->
  int
(** Draw single-line sanitized text truncated cleanly to [max_w] terminal
    columns. Returns columns advanced. *)

val draw_pills :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  bg:Color.t ->
  (string * bool * Theme.status_token option) list ->
  int
(** Paint a horizontal strip of restrained v2.5 toggle/tab pills (active uses
    elevated [surface_2] + [▎] rail + Tier-1 Bold underline; inactive uses
    Tier-3 [text_secondary], 2-space separation) and return columns advanced. *)

val draw_keycap_bar :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  bg:Color.t ->
  (string * string) list ->
  int
(** Paint a horizontal row of elevated keycap badges ([surface_2] Bold key +
    quiet label, 2-space gaps) inside [rect] and return columns advanced. *)

val draw_kv_row :
  Cell_grid.t ->
  rect:Rect.t ->
  y:int ->
  theme:Theme.t ->
  bg:Color.t ->
  label_w:int ->
  key:string ->
  value:string ->
  ?val_fg:Theme.rgb ->
  ?val_attrs:Attr.t ->
  unit ->
  unit

val draw_kpi_line :
  Cell_grid.t ->
  rect:Rect.t ->
  y:int ->
  theme:Theme.t ->
  bg:Color.t ->
  label:string ->
  short_label:string ->
  value:string ->
  val_style:Style.t ->
  unit
(** Paint a compact KPI [label value] row inside [rect], automatically falling
    back to [short_label] or a budget-capped prefix so [value] is never starved
    to 0 width on Standard/Compact columns. *)

val scrub_secrets_in_text : string -> string
(** Scrub embedded API tokens ([sk-...], [ghp_...], [xoxb-...], [AKIA...]),
    [Bearer ...] credentials, URL [user:pass@host] credentials, PEM private
    keys, and [secret_key=...] / ["secret_key": "..."] assignments from
    free-form or truncated text. *)

val scrub_json_secrets : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively scrub embedded secrets inside JSON string leaves while leaving
    secret-named object keys for {!Json_tree.flatten}'s dedicated redaction
    badge. *)

val draw_hrule :
  Cell_grid.t ->
  rect:Rect.t ->
  y:int ->
  theme:Theme.t ->
  bg:Color.t ->
  ?title:string ->
  unit ->
  unit

val draw_observed_empty :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  'a Observed.t ->
  empty_msg:Say.t ->
  unit
(** Render a clean typed status body for [Loading], [Absent], [Unreported],
    [Failed], or an empty [Value] collection using Tier-4 italic whispers (and
    Coral non-italic left rail on [Failed]) without leaving a raw void. *)

val format_age : now_unix:float -> float -> lang:Say.lang -> string
val format_due_delta : now_unix:float -> float -> lang:Say.lang -> string
(** Signed schedule due countdown: ["5m 뒤"] / ["in 5m"] for future timestamps
    and ["5m 늦음"] / ["5m late"] for overdue timestamps. *)
val format_hhmm : ?tz_offset_sec:int -> float -> string
val samples_of_floats : float list -> Chart.Series.sample array
val format_milli_candles : int -> string
val format_milli_string : string -> string

val rewrite_masc_links_for_markdown : string -> string
(** Rewrite bare [board:p-...] and [github:owner/repo/...] tokens into
    clickable Markdown links for OSC 8 rendering so raw wire IDs never leak
    into Goal/Task/Chat bodies. *)

val keeper_has_attention : Attention.t -> string -> bool
val keeper_incident_count : Incidents.t -> string -> int

val keeper_attention_badge : Glyph.t * Theme.status_token * Say.t
val keeper_idle_badge : Glyph.t * Theme.status_token * Say.t

val keeper_live_status :
  has_attention:bool ->
  Wire_fleet.keeper_summary ->
  Glyph.t * Theme.status_token * Say.t
(** Strictly project Channel 1 ([has_attention]) and Channel 2
    ([keeper_summary.health]) onto a width-1 geometric glyph, status tone, and
    bilingual label. Never reads Channel 3 historical incidents. *)

val activation_label : Wire_fleet.activation_mode -> Say.t
val turn_lane_label : Wire_fleet.turn_lane -> Say.t

val keeper_infra_tag : Infra_store.t -> string -> string * Theme.status_token
(** Classify a keeper's sandbox backend from [Infra_store.t] ([vm], [ssh],
    [dkr], or absent em-dash). *)

val keeper_sandbox_tag :
  model:Model.t -> string -> string * Theme.status_token
(** Classify a keeper's compact sandbox tag ([vm], [ssh], [dkr], or em-dash),
    checking live {!Infra_store.t} first and falling back to
    {!Fleet_store.sandbox_profile_of}. *)

val keeper_sandbox_label :
  model:Model.t -> string -> string * Theme.status_token
(** Full human sandbox backend label ([apple_container], [remote_ssh],
    [docker], or [—]) for hero headers and inspectors. *)

val human_runtime_label :
  model:Model.t -> Wire_fleet.keeper_summary -> string
(** Resolve a clean human runtime/model label via
    {!Wire_runtime.human_runtime_slot_label}, stripping raw provider hashes. *)

val keeper_candle_milli :
  model:Model.t -> string -> (int * string) option
(** Return [(nominal_milli, decayed_milli_str)] for a keeper from the Candle
    ledger or fleet roster fallback map. *)

val keeper_turn_summary :
  lang:Say.lang -> Wire_fleet.keeper_summary -> string

val goal_phase_badge :
  Wire_work.goal_phase -> Glyph.t * Theme.status_token * Say.t

val task_status_badge :
  Wire_work.task_status -> Glyph.t * Theme.status_token * Say.t

val task_assignee_opt : Wire_work.task_status -> string option
val task_started_at_opt : Wire_work.task_status -> string option
val task_is_active : Wire_work.task_status -> bool
val task_is_done : Wire_work.task_status -> bool
val task_is_awaiting_verification : Wire_work.task_status -> bool

val review_state_badge :
  Wire_work.review_observation_state -> Glyph.t * Theme.status_token * Say.t

val schedule_status_badge :
  Wire_work.schedule_status -> Glyph.t * Theme.status_token * Say.t

val wake_disposition_text :
  lang:Say.lang -> Wire_work.wake_disposition -> string * Theme.status_token

(** The Overview's Plan usage section: one strip per provider account, the way
    a mixer shows one channel strip per input. Each strip says how full the
    account's usage windows are, when they reset, and how long ago the
    provider said so.

    Every value is the provider's own report, as
    [GET /api/v1/runtime/resolved] carries it. Nothing here guesses a
    threshold: a meter is drawn in the exhausted style only when the reported
    value is at or past the full value of its own unit and the server did not
    classify the window as counting something a model call does not need;
    such a window is drawn dim whatever its value. The one other fact
    drawn is the runtime catalogue's [quota_exhausted], as an
    [exhausted (observed)] tag on the account whose quota scope it names.

    Pure apart from reading the terminal's local zone for clock times. *)

type section = {
  title : string;
  lines : string list;
      (** The section's rows in draw order: reported accounts first, then by
          account name. A budget shorter than this list cuts from the
          bottom. *)
  account_count : int;
      (** Accounts represented by those rows. One account can have several
          usage windows, so this can be smaller than [List.length lines]. *)
  account_row_counts : int list;
      (** Row count per account, in display order. *)
  note_lines : string list;
      (** Runtime catalogue errors after the account rows. *)
}

type visible = {
  lines : string list;
  shown_accounts : int;
  hidden_accounts : int;
  hidden_notes : int;
}

val visible_rows : section -> rows:int -> visible
(** Only complete account groups fit. One row is reserved to say what was
    omitted when the section is taller than its budget. *)

val section :
  providers:Masc_tui_types.overview_providers_reading ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  now:float ->
  width:int ->
  section option
(** [None] before the first read. A read with no account says
    ["no usage data"]. A failed read is one line,
    ["usage data unavailable: <reason>"]. [width] is the cells a row may use;
    a meter takes what the other columns leave, from 10 to 24 cells. When
    even 10 cells do not fit beside the hearing age, the age is left out. *)

val utilization_text : Masc.Tui_decode.provider_usage_utilization -> string
(** The value as a whole percent, so accounts read in one unit. A percent is
    shown as reported; a fraction is multiplied by 100 and floored, so
    [0.9999] reads [99%] and never [100%]. *)

val meter : cells:int -> float -> string
(** A meter [cells] cells wide filled to the given share of full, drawn with
    eighth-block glyphs so the fill moves by an eighth of a cell. The fill is
    rounded down, so only a share at or past full draws a full meter, and a
    share above zero draws at least one eighth. The share is
    held to [0, 1] for drawing only; a share that is not a number draws an
    empty meter, and the row's value text still prints it as reported. *)

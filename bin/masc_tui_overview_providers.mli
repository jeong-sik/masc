(** The Usage surface's Plan usage section: one strip per provider account,
    the way a mixer shows one channel strip per input. Each strip says how full the
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
          account name. *)
}

val scope_id : Masc.Tui_decode_usage.provider_usage_account -> string
(** The server's id for the scope, as its usage history names it. *)

val scope_id_cells : int
(** How much of a scope id a row draws to tell scopes apart. *)

val scope_name : Masc.Tui_decode_usage.provider_usage_account -> string

val section :
  providers:Masc_tui_types.overview_providers_reading ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  account_emails:Masc_tui_types.overview_account_emails_reading ->
  now:float ->
  width:int ->
  section option
(** [None] before the first read. An account that has not reported since the
    server started draws no row unless the runtime catalogue observed its
    quota exhausted; then it draws one ["no usage data"] row with that tag. A
    read with no row to draw says ["no usage data"]. A failed read is one line,
    ["usage data unavailable: <reason>"]. [width] is the cells a row may use;
    a meter takes what the other columns leave, from 10 to 24 cells. When
    even 10 cells do not fit beside the hearing age, the age is left out.

    An account whose providers have a read email draws it dim under its name.
    The name column is as wide as the widest account name: an email that fits
    it goes on the account's second window row, and otherwise, or when the
    account draws one row, on a row of its own. A failed email read adds one
    note, ["account emails unread: <reason>"], after the runtime notes, and so
    do rows this build cannot read. *)

val utilization_text : Masc.Tui_decode_usage.provider_usage_utilization -> string
(** The value as a whole percent, so accounts read in one unit. A percent is
    shown as reported; a fraction is multiplied by 100 and floored, so
    [0.9999] reads [99%] and never [100%]. *)

val share_of_full : Masc.Tui_decode_usage.provider_usage_utilization -> float

val meter : cells:int -> float -> string
(** A meter [cells] cells wide filled to the given share of full, drawn with
    eighth-block glyphs so the fill moves by an eighth of a cell. The fill is
    rounded down, so only a share at or past full draws a full meter, and a
    share above zero draws at least one eighth. The share is
    held to [0, 1] for drawing only; a share that is not a number draws an
    empty meter, and the row's value text still prints it as reported. *)

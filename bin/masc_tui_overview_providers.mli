(** The Usage surface's Plan usage section: one card per provider account.
    Each card labels the reported used percentage and the window's role,
    says when it resets, and shows the last report time beside every window.

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
(** [None] before the first read. Every known account draws a bordered card,
    including an explicit state when no usage has been reported. Empty and failed
    reads keep their explicit source states. A wide viewport places two cards
    beside each other; a narrow viewport stacks them. Every row fits [width]
    terminal cells. Emails, reset times, hearing age and catalogue observations
    are wrapped metadata rather than columns that displace utilization meters.
    Window roles still decide which full values are alarms. *)

val utilization_text : Masc.Tui_decode_usage.provider_usage_utilization -> string
(** The value as a whole percent or a USD credit amount. A percent is
    shown as reported; a fraction is multiplied by 100 and floored, so
    [0.9999] reads [99%] and never [100%]. *)

val share_of_full : Masc.Tui_decode_usage.provider_usage_utilization -> float option
(** [None] for uncapped USD use: an amount with no denominator has no meter. *)

val meter : cells:int -> float -> string
(** A meter [cells] cells wide filled to the given share of full, drawn with
    eighth-block glyphs so the fill moves by an eighth of a cell. The fill is
    rounded down, so only a share at or past full draws a full meter, and a
    share above zero draws at least one eighth. The share is
    held to [0, 1] for drawing only; a share that is not a number draws an
    empty meter, and the row's value text still prints it as reported. *)

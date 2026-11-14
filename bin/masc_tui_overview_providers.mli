(** The Usage surface's Plan usage section: one row per reported window, in
    groups for reported full limits or observed exhaustion, other reported windows,
    and accounts without windows to show.
    A row names the account and window, draws a bar and the percent used, and
    says when the window resets. A window priced in USD also shows its amounts.
    A window heard at a different time than its account's newest report says so.

    USD amounts describe the named window and its cap, not an inferred account
    balance.

    A summary separates full last-reported limits from catalogue-observed
    exhaustion. Shaded meter cells show the unused part of the reported limit.

    Every value is the provider's own report, as
    [GET /api/v1/runtime/resolved] carries it. Nothing here guesses a
    threshold: a meter is drawn in the exhausted style only when the reported
    value is at or past the full value of its own unit and the server did not
    classify the window as counting something a model call does not need;
    such a window is marked as other use whatever its value. A window that sits under
    [At_limit_or_exhausted] only because the catalogue observed the account exhausted
    keeps the tone its own report earns. The one other fact
    drawn is the runtime catalogue's [quota_rest], as an
    [exhausted (observed)] tag on the account whose quota scope it names.

    The containing Usage view owns the title.
    Pure apart from reading the terminal's local zone for clock times. *)

type section = {
  lines : string list;
      (** The section's rows in draw order, grouped as {!plan} orders them. *)
}

val text_for_viewport : columns:int -> rows:int -> string -> string
(** Bound a displayed label to the current viewport's UTF-8 capacity and mark
    omissions. Retain the ends where grapheme boundaries can be determined;
    an ambiguous portion is omitted. The source is unchanged. *)

(** What the runtime catalogue says about an account's quota scope. *)
type observed =
  | Not_observed_exhausted
  | Observed_exhausted of float option
      (** The latest stated reset among the scope's resting runtimes;
          [None] when none of them states one. *)

val observed_exhaustion :
  runtimes:Masc_tui_types.overview_quota_reading -> string -> observed
(** The catalogue's [quota_rest] joined by quota scope. A catalogue that
    was not read or failed observes nothing. *)

val window_at_limit : Masc.Tui_decode_usage.provider_usage_window -> bool
(** The reported value is at or past the full value of its own unit, on a
    window that gates model calls or whose role is unclassified. The same decision counts the header's
    [At limit (reported)] and puts a window in {!At_limit_or_exhausted}. *)

(** Which block of the Plan an account's windows are drawn in. The groups do
    not establish current availability: a report can be old,
    and an uncapped or unclassified window may not describe availability. *)
type plan_section =
  | At_limit_or_exhausted
      (** Windows at their limit, and the gating or unclassified windows of an
          account the catalogue observed exhausted. *)
  | Other_windows  (** Every other reported window. *)
  | No_windows
      (** Accounts with no window to show: nothing heard since the server
          started, or an explicit report with no windows. *)

type plan_entry = {
  pe_account : Masc.Tui_decode_usage.provider_usage_account;
  pe_observed : observed;
  pe_windows : Masc.Tui_decode_usage.provider_usage_window list;
      (** The account's windows that belong to this section, in draw order.
          Empty when the account has no window to show. *)
}

type plan_group = {
  pg_section : plan_section;
  pg_entries : plan_entry list;
}

val plan :
  now:float ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  Masc.Tui_decode_usage.provider_usage_account list ->
  plan_group list
(** Sections in the order [At_limit_or_exhausted], [Other_windows], [No_windows]; a section
    with no entry is absent. An account whose windows differ in state has an
    entry in each section it has a window in. An account the catalogue
    observed exhausted always has an [At_limit_or_exhausted] entry.

    - [At_limit_or_exhausted]: the account with the longest wait for a reset first,
      where a window with no reset time waits longest and a reset time that
      has passed waits least; an account's wait is its longest. Its windows
      are in the same order. An account with no window to show uses the
      catalogue's reopen time. An account with a window does not: the
      catalogue's time is not that window's reset, so a window with no reset
      time waits longest whatever the catalogue says. Ties go by account name.
    - [Other_windows]: the account whose most used gating window is the most used
      first; windows that gate nothing and amounts with no cap come last. Its
      windows are in the same order. Ties go by account name.
    - [No_windows]: by account name.

    Windows that tie keep the server's order. *)

val drawn_observation : plan_section -> observed -> observed
(** The catalogue observation an entry in this section draws. Only
    [At_limit_or_exhausted] draws it, so an account split across sections says it once.
    The other sections draw [Not_observed_exhausted]. *)

(** The header's [Exhausted (observed)] value. A catalogue that was not read or
    failed does not make the count zero. *)
type exhausted_count =
  | Exhausted_unknown
  | Exhausted_accounts of int

(** The header's numbers. *)
type counts = {
  accounts : int;
  reporting : int;  (** Accounts that sent a report, with or without windows. *)
  at_limit : int;  (** Accounts with a {!window_at_limit} window. *)
  exhausted : exhausted_count;
}

val counts :
  runtimes:Masc_tui_types.overview_quota_reading ->
  Masc.Tui_decode_usage.provider_usage_account list ->
  counts

val scope_id : Masc.Tui_decode_usage.provider_usage_account -> string
(** The server's id for the scope, as its usage history names it. *)

val scope_id_cells : int
(** How much of a scope id a row draws to tell scopes apart. *)

val scope_name : Masc.Tui_decode_usage.provider_usage_account -> string

val minutes_label : int -> string
(** Format a reported duration in whole days, hours, or minutes. *)

val account_email :
  account_emails:Masc_tui_types.overview_account_emails_reading ->
  Masc.Tui_decode_usage.provider_usage_account -> string option
(** Login identity for the exact quota scope, when the source reported it. *)

val section :
  providers:Masc_tui_types.overview_providers_reading ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  account_emails:Masc_tui_types.overview_account_emails_reading ->
  now:float ->
  show_limit_exhausted:bool ->
  width:int ->
  rows:int ->
  section option
(** [None] before the first read. Every known account is drawn under a
    section heading with its count, including an explicit state when no usage
    has been reported. Empty and failed reads keep their explicit source states.
    Every row fits [width] terminal cells. On a narrow screen the bar shrinks
    first, then a row drops its reset clock and keeps the countdown, and only
    then does a detail move to a row of its own. Emails and catalogue observations are rows
    under their account. Window roles still decide which full values are
    alarms. When [show_limit_exhausted] is [false] the
    [At_limit_or_exhausted] block collapses to its heading with a hidden note;
    the header counts still cover every account. *)

val section_cards :
  providers:Masc_tui_types.overview_providers_reading ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  account_emails:Masc_tui_types.overview_account_emails_reading ->
  now:float ->
  show_limit_exhausted:bool ->
  width:int ->
  rows:int ->
  section option
(** {!section} with each account drawn as a card, two to a row, when [width]
    holds two columns of them; below that it uses unboxed rows. A card is
    titled with the account's name and holds its windows, an observed
    exhaustion and its email, with the bars sized to the card. Every card in
    one section shares the same label, gauge and percent column measurement,
    computed at the narrowest paired card's content width, so neighbouring
    accounts read on the same axes. Labels larger
    than the viewport described by [width] and [rows] retain the ends where
    their boundaries are known and mark omissions instead of expanding an
    unbounded number of rows. Below 20 columns, the label bound uses 20 columns
    while layout uses the actual width. The two
    accounts of a row end on the same line. The headings, the summary and the
    notes are the same lines either way, and every row fits [width]. *)

val cards_fit : width:int -> bool
(** Whether {!section_cards} draws cards at [width]. *)

val clock_text : now:float -> float -> string
(** A time of day in the terminal's zone; a time on another day than [now]
    carries its month and day. *)

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

val bar_cells_min : int
(** Minimum preferred width of a comparison meter before moving it to another row. *)

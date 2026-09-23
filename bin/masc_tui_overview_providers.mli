(** The Overview's Providers section: one strip per provider account, the way
    a mixer shows one channel strip per input. Each strip says how full the
    account's usage windows are, when they reset, and how long ago the
    provider said so.

    Every value is the provider's own report, as
    [GET /api/v1/runtime/resolved] carries it. Nothing here guesses a
    threshold: a meter is drawn in the exhausted style only when the reported
    value is at or past the full value of its own unit. The one other fact
    drawn is the runtime catalogue's [quota_exhausted], as an
    [exhausted (observed)] tag on the account whose quota scope it names.

    Pure apart from reading the terminal's local zone for clock times. *)

type section = {
  title : string;
  lines : string list;
      (** The section's rows in draw order: reported accounts first, then by
          account name. A budget shorter than this list cuts from the
          bottom. *)
}

val section :
  providers:Masc_tui_types.overview_providers_reading ->
  runtimes:Masc_tui_types.overview_quota_reading ->
  now:float ->
  width:int ->
  section option
(** [None] before the first read. A failed read is one line,
    ["providers unavailable: <reason>"]. [width] is the cells a row may use;
    the meters take what the other columns leave. *)

val meter : cells:int -> float -> string
(** A meter [cells] cells wide filled to the given share of full, drawn with
    eighth-block glyphs so the fill moves by an eighth of a cell. The share is
    held to [0, 1] for drawing only; a share that is not a number draws an
    empty meter, and the row's value text still prints it as reported. *)

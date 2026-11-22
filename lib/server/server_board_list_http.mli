(** The page [GET /api/v1/board] answers on HTTP/1 and HTTP/2. *)

val signal_scan_cap : int
(** Upper bound on raw posts scanned per request when [?signal_only=true]
    expands its fetch window to fill [offset + limit + 1] signal posts
    (currently [2000], raised to [offset + limit + 1] when a higher offset is
    requested). When the cap is reached without exhausting the store or filling
    [offset + limit + 1] signal posts, the response sets
    [signal_scan_truncated = true]. *)

val chain_scan_cap : int
(** Maximum readable board posts inspected to construct the full-board
    succession graph ([2_000], matching {!signal_scan_cap} so signal-page
    expansion and succession resolution share one bounded read budget). When
    the readable board fits within this cap, the response reports
    [succession_chain_scope = "full"]; otherwise ["bounded"]. *)

type succession_chain_scope =
  | Chain_scope_full
  | Chain_scope_bounded

val succession_chain_scope_to_string : succession_chain_scope -> string

val succession_chains_cache_key :
  reader:Masc_board_handlers.Board_access.reader ->
  base_path:string option ->
  string
(** Shared {!Dashboard_cache} key (prefix ["board:chains:"]) for the
    succession-chain graph of [reader] in [base_path], independent of page
    [offset]/[limit] and list filters. Invalidated alongside ["board:list:"]
    by {!Server_dashboard_http_core_cache.invalidate_board_projections}. *)

val cached_succession_chains :
  ?scan_cap:int ->
  ?fetch:(int -> Board.post list) ->
  reader:Masc_board_handlers.Board_access.reader ->
  base_path:string option ->
  unit ->
  succession_chain_scope * (string, string * int) Hashtbl.t
(** Compute or reuse the cached full-board succession graph under
    {!succession_chains_cache_key} for the realtime TTL. Inspects at most
    [scan_cap + 1] posts (default {!chain_scan_cap}) to distinguish
    [Chain_scope_full] from [Chain_scope_bounded]. *)

val is_signal_post : Board.post -> bool
(** [true] when [post] is substantive signal (not [Board.System_post] and not
    verification noise such as [Verify:] / verification-metadata posts). Used by
    [?signal_only=true]. *)

type signal_page =
  { paged : Board.post list
  ; filtered_out_count : int
  ; has_more : bool
  ; signal_scan_truncated : bool
  }

val scan_signal_page :
  ?scan_cap:int ->
  exclude_automation:bool ->
  offset:int ->
  limit:int ->
  (int -> Board.post list) ->
  signal_page
(** Scan with an expanding bounded window (starting at
    [min cap ((offset + limit + 1) * 2)] and doubling up to [cap]) until
    [offset + limit + 1] signal posts are collected, the store is exhausted
    ([List.length raw < scan_limit]), or [cap] is reached. Returns the exact
    [drop offset |> take limit] page of signal posts alongside
    [filtered_out_count] over the scanned window, [has_more], and
    [signal_scan_truncated]. *)

val compute_succession_chains :
  Board.post list -> (string, string * int) Hashtbl.t
(** Map each post ID participating in a [closed.successor_id] chain to
    [(succession_chain_root_id, chain_depth)] where the root has depth [0],
    its direct successor has depth [1], and so on. Cycle-safe. Posts that are
    not part of any succession chain are absent from the table. *)

val payload :
  ?config:Workspace.config ->
  reader:Masc_board_handlers.Board_access.reader ->
  reaction_actor:string option ->
  Httpun.Request.t ->
  Dashboard_cache.cached_payload
(** The page for the request's query ([hearth], [sort_by], [exclude_system],
    [exclude_automation], [signal_only], [author], [limit], [offset], [voter])
    and the authenticated [reaction_actor]; a blank [hearth] or [author] is no
    filter.
    - When [signal_only=true], {!scan_signal_page} expands its bounded scan up
      to [max signal_scan_cap (offset + limit + 1)] so pages return full signal
      counts past interleaved noise and paginate consistently across offsets;
      response JSON includes [filtered_out_count], [has_more], and
      [signal_scan_truncated].
    - Succession-chain metadata ([succession_chain_root_id], [chain_depth]) is
      computed across the full readable board up to {!chain_scan_cap} posts via
      the shared {!succession_chains_cache_key} cache entry (independent of
      page [offset]/[limit] or list filters), and response JSON reports
      [succession_chain_scope] (["full"] or ["bounded"]).
    It is kept with its serialized body and entity tag for the realtime TTL,
    after which the dashboard cache serves it stale while it recomputes. A board
    write that raises a board event drops every [board:list:] and
    [board:chains:] entry sooner.
    [origin] is [Timeout] when the page could not be computed in time; the body
    is then the cache's timeout envelope. *)

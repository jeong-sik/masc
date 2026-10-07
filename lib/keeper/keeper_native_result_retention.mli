(** Check canonical results against this API call's transcript only. Results
    before the exact admitted seed cannot discharge later invocations, and
    each retained occurrence can discharge at most one canonical result.
    An empty result set imposes no transcript constraint; the caller owns
    separate seed/history admission rules for calls with tool attempts. *)
val retains :
  seed:Agent_core.Types.message list ->
  messages:Agent_core.Types.message list ->
  results:Agent_core.Types.content_block list -> bool

(** Sender-side mention dedup (RFC-0040).

    Suppresses duplicate broadcasts where the sender mentions the same
    target with the same content within a short TTL window. Pull-model
    keepers (see [keeper_prompt.ml:16] [Mention.any_mentioned]) re-read
    the board on every turn, so a sender resending the same
    [@target topic] message every cycle floods the recipient's inbox
    even though no new information was added.

    Scope: only the broadcast path through [coord_broadcast.ml broadcast]
    is covered. eio/grpc broadcast variants ([coord_eio.ml],
    [masc_grpc_client.ml]) are NOT covered — see RFC-0040 §5.1.

    State: in-process Hashtbl keyed by
    [(from_agent, target, content_hash)]. RAM only — server restart
    resets dedup state, which is intended (one mention per restart is
    acceptable). *)

(** Default dedup TTL window in seconds. Read from env
    [MASC_MENTION_DEDUP_TTL_S]; falls back to 300.0s (5min). *)
val default_ttl_seconds : float

(** [should_skip ~from_agent ~target ~content_hash ~now] returns
    [true] if a broadcast with the same triple was observed within
    [default_ttl_seconds] of [now]. Otherwise it records [now] as the
    last_seen for this triple and returns [false].

    Side effects:
    - Updates the in-process Hashtbl entry for the triple to [now].
    - Increments the
      [masc_mention_dedup_decisions_total]{outcome=skipped|passed}
      Prometheus counter.

    Thread safety: caller-side mutex; safe for concurrent fibers. *)
val should_skip :
  from_agent:string ->
  target:string ->
  content_hash:string ->
  now:float ->
  bool

(** Stable SHA1 of [String.lowercase_ascii (String.trim content)]. *)
val content_topic_hash : string -> string

(** Test-only: clears the in-process Hashtbl. Not exported in
    production wiring — only [test/test_mention_dedup.ml] should
    call this. *)
val reset_for_test : unit -> unit

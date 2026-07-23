(** Board_addressing — the shared @-mention addressing grammar parsed at
    the Board and Keeper write boundaries (issue #25601).

    This leaf owns exactly one thing: turning free text into raw address
    tokens.  It exists because [board_audience] and
    [keeper_lane_mentions] each carried a private clone of the same
    grammar (token edge trimming, whitespace splitting, [@@] broadcast
    selectors, [@] direct targets) and the clones had already drifted —
    the Keeper copy case-folded the whole content before tokenizing while
    the Board copy preserved target case.

    Case policy (the unification): the grammar is case-preserving.
    Content is NOT lowercased before tokenization, and target candidates
    keep the author's casing.  Case normalization is an identity concern
    owned by each caller's id type:
    - Keeper mints candidates through [Keeper_identity.Keeper_id.of_string],
      whose documented contract case-folds and canonicalizes
      (["@ALPHA"] and ["@alpha"] mint the same keeper id).
    - Board validates candidates through [Board_types.Agent_id.of_string],
      which is case-sensitive (["@MiXeD-Agent"] stays ["MiXeD-Agent"]).
    Only [@@] selector {e comparison} is case-insensitive here
    (["@@ALL"] is [Broadcast_all] on both sides, as both legacy copies
    already behaved), and unsupported selectors are reported lowercased,
    matching both legacy copies. *)

val target_prefix : string
(** ["@"] — the single-at direct-target prefix. *)

val broadcast_selector_prefix : string
(** ["@@"] — the double-at broadcast selector prefix. *)

val broadcast_all_selector : string
(** ["all"] — the only universally supported broadcast selector. *)

val trim_token_edges : string -> string
(** Trim non-word characters from both ends of a token, keeping internal
    ones.  Word chars are [A-Za-z0-9@_-]; ['.'] is NOT a word char, so
    ["@alice."] trims to ["@alice"] while the internal ['.'] in
    ["email@alice.com"] is preserved (the whole token stays
    ["email@alice.com"] and never equals ["@alice"]). *)

val tokens_of_text : string -> string list
(** Whitespace-split (['\t'], ['\n'], ['\r'] fold to [' ']) and edge-trim
    the text into non-empty tokens.  Case is preserved. *)

type raw_address =
  | No_explicit_address  (** No [@]- or [@@]-tokens at all. *)
  | Raw_targets of string list
      (** Direct-address candidate names (leading ['@'] stripped), in
          token order, case preserved, not yet validated or deduplicated.
          A bare ["@"] yields the empty candidate; whether that is
          malformed or simply not an id is the caller id type's call. *)
  | Broadcast_all  (** Every [@@] selector was [all] (case-insensitive). *)
  | Unsupported_broadcast of string list
      (** At least one [@@] selector was not [all].  Selectors are
          lowercased, sorted, and deduplicated. *)

val parse : string -> raw_address
(** Classify the address tokens of a text.  Broadcast selectors win over
    direct targets: a line that mixes valid [@name] targets with any
    [@@] selector is treated as a broadcast address, never as a partial
    direct address.  When the selector is not [@@all] the result is
    [Unsupported_broadcast] and the caller fails closed, dropping the
    whole signal — the otherwise-valid direct targets are deliberately
    NOT surfaced, because partially routing an ambiguous address would
    silently reinterpret the author's intent. *)

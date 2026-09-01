(** Nonce fact injection + recall scoring for the keeper canary harness.

    Values are deterministic given [seed] (the caller's run id), not
    process-global randomness: the same run id always reproduces the exact
    same facts, and evidence never carries a wall-clock-derived value that
    would make two runs of the same run id diverge. Cross-run collision
    protection falls on the caller picking a fresh run id per invocation.

    Nine categories mirror PR #28743's manually-established set exactly, so
    {!generate} automates that protocol rather than inventing a new one. *)

type fact = {
  category : string;
  statement : string;  (** what turn i says to the keeper *)
  value : string;  (** the nonce string the keeper must recall verbatim *)
}

val category_names : string list
(** The nine fixed categories, in canonical injection order. *)

val generate : seed:string -> count:int -> fact list
(** [generate ~seed ~count] returns up to [count] facts drawn from
    {!category_names} in order. [count] is capped at
    [List.length category_names]. Every value is derived solely from
    [seed] (via SHA-256 digests keyed per value, no PRNG) — calling this twice with the same
    [seed] and [count] always returns an identical list. *)

val recall_prompt : unit -> string
(** The fixed final-turn prompt asking the keeper to list every established
    fact, in order, without tool use. *)

type turn_plan_entry = { index : int; category : string option; message : string }

val plan : facts:fact list -> turn_plan_entry list
(** The pure turn sequence a run sends: [facts] in order as 1-indexed
    fact-injection turns ([category = Some _]), then one recall turn at
    [List.length facts + 1] ([category = None], [message = recall_prompt ()]). *)

type recall_result = {
  category : string;
  value : string;
  recalled : bool;
  first_index : int option;
      (** Byte offset of [value]'s first case-insensitive occurrence in the
          reply, for order checking. [None] when not recalled. *)
}

type score = {
  facts_total : int;
  facts_recalled : int;
  order_matches : bool;
      (** [true] only when every recalled fact's first occurrence in the
          reply is strictly after the previous recalled fact's — a partial
          recall (some facts missing) can still have [order_matches = true]
          for the facts it did recall. *)
  recalled_categories : string list;
  missing_categories : string list;
  per_fact : recall_result list;
}

val score : facts:fact list -> reply:string -> score
(** Case-insensitive substring search for each fact's [value] in [reply],
    plus an order check over the facts that were found. A raw deterministic
    signal, not the canary's pass/fail judgment — see
    {!Keeper_canary_evidence.run_evidence.judgment}. *)

val interval_for_wall_clock : gaps:int -> target_s:float -> float
(** Even spacing for a wall-clock target: [target_s /. gaps]. A plan of N
    fact turns plus one recall has N gaps. [0.] when [gaps <= 0] — a plan
    with nothing to space out has no interval, not an error. *)

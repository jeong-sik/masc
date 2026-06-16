(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files. *)

open Keeper_memory_os_types

let default_max_facts = 8
let default_max_episodes = 2

(* RFC-0244 Tier 2: how many shared-semantic facts to append after the keeper's
   own (private-precedence) facts. Kept small so the communal tier informs
   without crowding out keeper-local memory. *)
let default_max_shared_facts = 4
let fact_tail_scan = 64
let max_fact_text_len = 260
let max_episode_text_len = 360
let max_atom_len = 48

let prompt_injection_prefixes =
  [ "ignore previous instructions"
  ; "ignore all previous instructions"
  ; "ignore prior instructions"
  ; "ignore all prior instructions"
  ; "disregard previous instructions"
  ; "disregard prior instructions"
  ; "forget previous instructions"
  ; "system prompt:"
  ; "system:"
  ; "developer:"
  ; "assistant:"
  ; "user:"
  ]
;;

let rec take n xs =
  if n <= 0
  then []
  else (
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest)
;;

let truncate ~max_len s =
  if max_len <= 0
  then ""
  else if String.length s <= max_len
  then s
  else String.sub s 0 (max 0 (max_len - 3)) ^ "..."
;;

let strip_prompt_injection_prefix line =
  let trimmed = String.trim line in
  let lower = String.lowercase_ascii trimmed in
  match
    List.find_opt
      (fun prefix -> String.starts_with ~prefix lower)
      prompt_injection_prefixes
  with
  | None -> None
  | Some prefix ->
    let prefix_len = String.length prefix in
    Some (String.sub trimmed prefix_len (String.length trimmed - prefix_len) |> String.trim)
;;

let rec strip_prompt_injection_prefixes ?(remaining = 8) line =
  if remaining <= 0
  then line
  else (
    match strip_prompt_injection_prefix line with
    | None -> line
    | Some stripped -> strip_prompt_injection_prefixes ~remaining:(remaining - 1) stripped)
;;

let sanitize_text ~max_len text =
  text
  |> Inference_utils.sanitize_text_utf8
  |> String.split_on_char '\n'
  |> List.map strip_prompt_injection_prefixes
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> String.concat " "
  |> truncate ~max_len
;;

let sanitize_atom text =
  sanitize_text ~max_len:max_atom_len text
  |> String.map (function
    | '\t' | '\r' | '\n' -> ' '
    | c -> c)
;;

let fact_is_current ~now fact =
  match fact.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

let render_fact ~now ?(seed_tokens = []) fact =
  let score = Keeper_memory_os_policy.score_fact ~seed_tokens ~now fact in
  let source = fact.source in
  Printf.sprintf
    "- [category=%s confidence=%.2f stale=%.2f score=%.3f turn=%d] %s"
    (sanitize_atom (category_to_string fact.category))
    fact.confidence
    fact.stale_factor
    score
    source.turn
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;

(* RFC-0244 Tier 2: a shared fact is rendered with its provenance (the distinct
   keepers that corroborated it) so it is never silently merged into the keeper's
   own knowledge — the reader can see it is cross-keeper consensus. *)
let render_shared_fact ~now ?(seed_tokens = []) fact =
  let score = Keeper_memory_os_policy.score_fact ~seed_tokens ~now fact in
  let provenance =
    match fact.observed_by with
    | [] -> "shared"
    | keepers -> "shared via " ^ String.concat "," (List.map sanitize_atom keepers)
  in
  Printf.sprintf
    "- [%s category=%s confidence=%.2f score=%.3f] %s"
    provenance
    (sanitize_atom (category_to_string fact.category))
    fact.confidence
    score
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;

let render_episode episode =
  Printf.sprintf
    "- [%s g%04d] %s"
    (sanitize_atom episode.trace_id)
    episode.generation
    (sanitize_text ~max_len:max_episode_text_len episode.episode_summary)
;;

let render_prompt_template key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text -> Ok (String.trim text)
  | Error msg -> Error (Printf.sprintf "%s: %s" key msg)
;;

let render_nonempty_section key variable lines =
  match lines with
  | [] -> Ok ""
  | _ -> render_prompt_template key [ variable, String.concat "\n" lines ]
;;

let render_recall_context ~fact_lines ~episode_lines =
  match
    render_nonempty_section
      Keeper_prompt_names.memory_os_recall_facts_section
      "facts"
      fact_lines
  with
  | Error msg -> Error msg
  | Ok facts_section ->
    (match
       render_nonempty_section
         Keeper_prompt_names.memory_os_recall_episodes_section
         "episodes"
         episode_lines
     with
     | Error msg -> Error msg
     | Ok episodes_section ->
       render_prompt_template
         Keeper_prompt_names.memory_os_recall_context
         [ "facts_section", facts_section; "episodes_section", episodes_section ])
;;

(* RFC-0239 R2 / RFC-0243: recall-time dedup keys on the shared
   [Keeper_memory_os_types.normalize_claim] SSOT (was a local copy; RFC-0243
   lifted it so the write-time upsert keys identically). Since RFC-0243 makes the
   librarian write path upsert-by-claim, the store no longer accumulates fresh
   duplicates; this read-time dedup remains as defense-in-depth for legacy rows
   written before the upsert landed. *)
let dedup_by_claim scored =
  let seen = Hashtbl.create 32 in
  List.filter
    (fun (_score, fact) ->
      let key = normalize_claim fact.claim in
      if Hashtbl.mem seen key then false else (Hashtbl.add seen key (); true))
    scored
;;

(* Score, filter to current, rank, and dedup — retaining the score so the
   spreading-activation step can boost from neighbour scores before the score is
   dropped. *)
let score_facts_ranked ~now ?(seed_tokens = []) facts =
  facts
  |> List.filter (fact_is_current ~now)
  |> List.map (fun fact -> Keeper_memory_os_policy.score_fact ~seed_tokens ~now fact, fact)
  |> List.sort (fun (a, _) (b, _) -> compare b a)
  |> dedup_by_claim
;;

let scored_facts ~now ?(seed_tokens = []) facts =
  score_facts_ranked ~now ~seed_tokens facts |> List.map snd
;;

(* Re-rank [scored] by adding each fact's spreading-activation boost. With
   [alpha] <= 0 (or no associations) this is the identity, preserving the exact
   RFC-0244 order and values. *)
let activate ~alpha ~associations scored =
  if alpha <= 0.0
  then scored
  else (
    let base = List.map (fun (s, fact) -> normalize_claim fact.claim, s) scored in
    let boosts = Keeper_memory_os_edges.activation_boosts ~alpha ~associations ~base in
    let boost_tbl = Hashtbl.create (List.length boosts * 2 + 1) in
    List.iter (fun (k, b) -> Hashtbl.replace boost_tbl k b) boosts;
    scored
    |> List.map (fun (s, fact) ->
      let boost =
        match Hashtbl.find_opt boost_tbl (normalize_claim fact.claim) with
        | Some b -> b
        | None -> 0.0
      in
      s +. boost, fact)
    |> List.sort (fun (a, _) (b, _) -> compare b a))
;;

let render_context_exn ~keeper_id ~now ~max_facts ~max_episodes ?(seed_tokens = []) () =
  let max_facts = max 0 max_facts in
  let max_episodes = max 0 max_episodes in
  (* RFC-0246 §2.7 (P2a-2): read associations only when activation is enabled, so
     the default (alpha = 0) path does no extra IO and stays byte-identical. *)
  let alpha = Keeper_memory_os_edges.activation_alpha () in
  let associations =
    if alpha <= 0.0 then [] else Keeper_memory_os_io.read_associations ~keeper_id
  in
  let facts =
    (* RFC-0239 Q4: read up to the bounded recall window (the retention sweep
       caps the store to this many facts), so score ranking selects the
       globally best facts rather than only the most recent [fact_tail_scan].
       RFC-0244: [seed_tokens] (current turn) reranks via lexical relevance; an
       empty seed leaves the ranking unchanged. RFC-0246: spreading activation
       then lifts facts linked to the recalled set (identity when alpha = 0). *)
    Keeper_memory_os_io.read_facts_tail
      ~keeper_id
      ~n:(max fact_tail_scan Keeper_memory_os_io.fact_recall_window)
    |> score_facts_ranked ~now ~seed_tokens
    |> activate ~alpha ~associations
    |> List.map snd
    |> take max_facts
  in
  (* RFC-0244 Tier 2: append shared-semantic facts after the keeper's own, with
     private precedence — a claim already surfaced from this keeper's store is not
     repeated from the shared store. The shared store is read under the reserved
     [shared_store_id]; reading it for the shared store itself is a no-op guard. *)
  let private_keys = List.map (fun f -> normalize_claim f.claim) facts in
  let shared_facts =
    if String.equal keeper_id shared_store_id
    then []
    else
      Keeper_memory_os_io.read_facts_tail
        ~keeper_id:shared_store_id
        ~n:Keeper_memory_os_io.fact_recall_window
      |> scored_facts ~now ~seed_tokens
      |> List.filter (fun f -> not (List.mem (normalize_claim f.claim) private_keys))
      |> take default_max_shared_facts
  in
  let episodes = Keeper_memory_os_io.read_episodes_tail ~keeper_id ~n:max_episodes in
  match facts, shared_facts, episodes with
  | [], [], [] -> ""
  | _ ->
    let fact_lines =
      List.map (render_fact ~now ~seed_tokens) facts
      @ List.map (render_shared_fact ~now ~seed_tokens) shared_facts
    in
    let episode_lines = List.map render_episode episodes in
    (match render_recall_context ~fact_lines ~episode_lines with
     | Ok context -> context
     | Error msg ->
       Log.Keeper.warn "memory os recall prompt unavailable keeper=%s: %s" keeper_id msg;
       "")
;;

let render_context
      ~keeper_id
      ~now
      ?(max_facts = default_max_facts)
      ?(max_episodes = default_max_episodes)
      ?seed
      ()
  =
  let seed_tokens =
    match seed with
    | None -> []
    | Some s -> Keeper_memory_os_policy.tokenize s
  in
  try render_context_exn ~keeper_id ~now ~max_facts ~max_episodes ~seed_tokens () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "memory os recall unavailable keeper=%s: %s"
      keeper_id
      (Printexc.to_string exn);
    ""
;;

let enabled () =
  (* Default on, mirroring the librarian (write side): persisted memory
     that never reaches a prompt is dead weight. Env var = kill switch. *)
  Keeper_memory_bank_env.memory_env_bool_logged
    "MASC_KEEPER_MEMORY_OS_RECALL"
    ~default:true
;;

let render_if_enabled ~keeper_id ~now ?seed () =
  if not (enabled ())
  then None
  else (
    match String.trim (render_context ~keeper_id ~now ?seed ()) with
    | "" -> None
    | block -> Some block)
;;

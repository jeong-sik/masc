(** Keeper_memory_os_grounding — RFC-0259 P2: observe-only grounding reconciler.

    For a fact whose claim names verifiable external state (an [external_ref] from
    P1), this re-checks the PR/issue against GitHub and produces a PROVISIONAL,
    log-only verdict. It performs NO writes: it never mutates a fact, never
    advances [last_verified_at], never retracts. Its sole output is an
    [observation] the maintenance fiber logs, so an operator can measure how often
    the cheap deterministic predicate disagrees with reality before P3 trusts it to
    retract (RFC-0259 §3.3 dry-run-before-enable discipline).

    Boundary (RFC-0247/0259): no importance/effectiveness SCORE is computed — the
    fetched state is a closed enum and the verdict a closed 3-valued sum, both
    typed observations, not numbers. Any uncertainty (no token, HTTP 401/403/404,
    GraphQL errors, missing node, timeout, or a [Task] ref with no GitHub analogue)
    yields [Indeterminate]; a false [Confirmed]/[Contradicted_candidate] is never
    produced (CLAUDE.md anti-pattern #2: unknown -> Unknown, not a permissive
    default). *)

open Keeper_memory_os_types

(* RFC-0259 P2: re-checked external state. Closed sum (mirrors [external_ref_kind])
   so a future state forces a compile-time decision. *)
type fetched_state =
  | Open
  | Closed
  | Merged
  | Not_found

let fetched_state_to_string = function
  | Open -> "open"
  | Closed -> "closed"
  | Merged -> "merged"
  | Not_found -> "not_found"
;;

(* Abstention-biased: only [Confirmed]/[Contradicted_candidate] carry signal, and
   [Contradicted_candidate] is a LOGGED HYPOTHESIS for P3 review, not grounds to
   retract. Everything uncertain collapses to [Indeterminate]. *)
type provisional_verdict =
  | Confirmed
  | Contradicted_candidate
  | Indeterminate

let provisional_verdict_to_string = function
  | Confirmed -> "confirmed"
  | Contradicted_candidate -> "contradicted_candidate"
  | Indeterminate -> "indeterminate"
;;

(* Injected so tests drive verdicts with a fake and no network (mirrors
   [Keeper_librarian_runtime]'s [complete_fn] seam). [Ok state] = determined;
   [Error reason] = could not determine, which the caller maps to [Indeterminate]. *)
type verify_external = external_ref -> (fetched_state, string) result

(* Pure classification of the re-checked state into a provisional verdict.
   CONSERVATIVE and measurement-only: a non-terminal [Open] state leaves an ongoing
   claim [Confirmed]; a terminal [Closed]/[Merged] marks the volatile claim a
   [Contradicted_candidate] for P3 to weigh — it may be a TRUE "was merged" claim,
   which is exactly the disagreement the dry-run exists to measure; [Not_found] is
   [Indeterminate]. This is NOT a retraction rule (P3 decides retraction using the
   dry-run log this produces), and it reads no claim text — claim-aware refinement
   is deferred to P3. *)
let classify_state = function
  | Open -> Confirmed
  | Closed | Merged -> Contradicted_candidate
  | Not_found -> Indeterminate
;;

type observation =
  { keeper_id : string
  ; ref_kind : external_ref_kind
  ; ref_id : string
  ; normalized_claim : string
  ; first_seen : float
  ; last_verified_at : float option
  ; age_seconds : float
  ; fetched : (fetched_state, string) result
  ; verdict : provisional_verdict
  }

(* A volatile claim becomes eligible for re-grounding once its truth anchor is
   older than this horizon. Same shape as the P1 volatile TTL (a TIME, not a
   score). *)
let default_grounding_horizon_seconds = volatile_external_ttl_seconds

(* Default GitHub coordinates; the fiber may override via env. *)
let default_owner = "jeong-sik"
let default_repo = "masc"

let fact_age ~now (f : fact) =
  let anchor =
    match f.last_verified_at with
    | Some t -> t
    | None -> f.first_seen
  in
  now -. anchor
;;

(* Pure given [verify_external]: scan a keeper's facts, re-check each volatile
   claim past the horizon, and return one observation per checked fact. Performs
   NO writes — the module has no fact-store write dependency at all. *)
let grounding_pass ~verify_external ~now ~grounding_horizon ~keeper_id (facts : fact list) =
  List.filter_map
    (fun (f : fact) ->
      match f.external_ref with
      | None -> None
      | Some ref ->
        let age = fact_age ~now f in
        if age < grounding_horizon
        then None
        else (
          let fetched = verify_external ref in
          let verdict =
            match fetched with
            | Ok state -> classify_state state
            | Error _ -> Indeterminate
          in
          Some
            { keeper_id
            ; ref_kind = ref.kind
            ; ref_id = ref.id
            ; normalized_claim = normalize_claim f.claim
            ; first_seen = f.first_seen
            ; last_verified_at = f.last_verified_at
            ; age_seconds = age
            ; fetched
            ; verdict
            }))
    facts
;;

(* Single-line log record for the maintenance fiber. Carries the fields P3 needs
   to reproduce the verdict offline and measure the per-claim-shape disagreement
   rate: keeper, ref, normalized claim (P3 retraction keys on it), age, fetched
   state (or the error that forced Indeterminate), and the verdict. *)
let observation_log_line o =
  let fetched_str =
    match o.fetched with
    | Ok s -> fetched_state_to_string s
    | Error e -> "indeterminate(" ^ e ^ ")"
  in
  Printf.sprintf
    "keeper=%s ref=%s#%s state=%s verdict=%s age=%.0fs claim=%S"
    o.keeper_id
    (external_ref_kind_to_string o.ref_kind)
    o.ref_id
    fetched_str
    (provisional_verdict_to_string o.verdict)
    o.age_seconds
    o.normalized_claim
;;

(* ---------- Real verify_external on the GitHub GraphQL API ---------- *)

(* Parse a GitHub GraphQL response body into a [fetched_state]. Any shape we do
   not positively recognize (parse error, top-level [errors], null node, missing
   or unknown state string) is an [Error] -> [Indeterminate]; only an explicit
   OPEN/CLOSED/MERGED maps to a state. *)
let parse_state_response ~(kind : external_ref_kind) (body : string) : (fetched_state, string) result =
  match Yojson.Safe.from_string body with
  | exception _ -> Error "unparseable response"
  | json ->
    (try
       let open Yojson.Safe.Util in
       match member "errors" json with
       | `List (_ :: _) -> Error "graphql errors"
       | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List [] | `Null | `String _ ->
         let node_field =
           match kind with
           | Pr -> "pullRequest"
           | Issue -> "issue"
           (* Task is short-circuited before parsing; map defensively. *)
           | Task -> "issue"
         in
         let node = json |> member "data" |> member "repository" |> member node_field in
         (match node with
          | `Null -> Ok Not_found
          | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `String _ ->
            (match member "state" node with
             | `String "OPEN" -> Ok Open
             | `String "CLOSED" -> Ok Closed
             | `String "MERGED" -> Ok Merged
             | `String other -> Error ("unknown state " ^ other)
             | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null ->
               Error "missing state"))
     with
     | _ -> Error "unexpected response shape")
;;

(* The injected [verify_external] backed by a real GitHub GraphQL call. Returns
   [Error] (-> [Indeterminate]) on every failure path; never a false verdict.
   [timeout_sec] MUST be > 0 so a hung connection cannot stall the reconciler
   fiber (Masc_http_client races the call against the clock). *)
let github_verify ~token ~clock ~timeout_sec ~owner ~repo : verify_external =
  fun ref ->
  match ref.kind with
  | Task -> Error "no github analogue for task ref"
  | Pr | Issue ->
    (match int_of_string_opt ref.id with
     | None -> Error ("non-numeric ref id: " ^ ref.id)
     | Some number ->
       let node =
         match ref.kind with
         | Pr -> Printf.sprintf "pullRequest(number:%d){state}" number
         | Issue -> Printf.sprintf "issue(number:%d){state}" number
         (* Unreachable: the outer match excludes Task. *)
         | Task -> assert false
       in
       let query =
         Printf.sprintf "query{repository(owner:%S,name:%S){%s}}" owner repo node
       in
       let body = `Assoc [ "query", `String query ] |> Yojson.Safe.to_string in
       (match
          Masc_http_client.post_sync
            ~clock
            ~timeout_sec
            ~url:"https://api.github.com/graphql"
            ~headers:
              [ "Authorization", "bearer " ^ token
              ; "Accept", "application/vnd.github+json"
              ; (* GitHub rejects GraphQL/REST without a User-Agent (HTTP 403). *)
                "User-Agent", "masc-grounding-reconciler"
              ; "Content-Type", "application/json"
              ]
            ~body
            ()
        with
        | Error e -> Error e
        | Ok (code, resp) ->
          if code < 200 || code >= 300
          then Error (Printf.sprintf "http %d" code)
          else parse_state_response ~kind:ref.kind resp))
;;

(* The degenerate verify_external used when no token is provisioned: every ref is
   Indeterminate. Lets the fiber run harmlessly (log-only) without GitHub access. *)
let no_token_verify : verify_external =
  fun _ref -> Error "no MASC_GROUNDING_GITHUB_TOKEN"
;;

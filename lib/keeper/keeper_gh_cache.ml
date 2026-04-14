(** See [keeper_gh_cache.mli] for the public interface rationale. *)

type entity_kind = PR | Issue

type validation_result =
  [ `Valid
  | `Invalid of int list
  | `Unknown
  ]

type cache_entry = {
  numbers : int list;
  fetched_at : float;
  populated : bool;
      (** [true] when a fetch succeeded and returned a list (possibly empty).
          [false] marks a failed fetch so the caller can fallthrough without
          caching the failure forever. *)
}

(* ------------------------------------------------------------------ *)
(* Tuning constants — SSOT for keeper_gh_cache behavior.               *)
(* If these need to vary at runtime, migrate to                        *)
(* Keeper_tool_policy_config.t ([gh_cache] section in tool_policy.toml)*)
(* following the pr_create_timeout_sec pattern.                        *)
(* ------------------------------------------------------------------ *)

(** Time-to-live for cached PR/issue number lists.
    120 s keeps entries fresh enough that newly-created PRs appear within
    ~2 minutes, while avoiding a subprocess per validation call. *)
let cache_ttl_sec = 120.0

(** Page size for the [gh api repos/.../pulls|issues?per_page=N] REST
    call. Repos with >100 open PRs will miss older numbers — those
    fall to [`Unknown] (fail-open), which is safer than a hard rejection. *)
let fetch_page_size = 100

(** Subprocess timeout for the [gh api] fetch call.
    Must be long enough for a cold gh-cli invocation behind a network
    proxy, short enough that a stalled gh process doesn't block keeper
    turns. 10 s matches the preflight-check timeout in
    Keeper_exec_preflight. *)
let fetch_timeout_sec = 10.0

let kind_path = function PR -> "pulls" | Issue -> "issues"

(** Cache keyed by (repo_slug, entity_kind). Module-level so all keepers
    share a single table -- one keeper's populate benefits all of them. *)
let cache : (string * entity_kind, cache_entry) Hashtbl.t = Hashtbl.create 8

let cache_lock = Eio.Mutex.create ()

(* Metrics counters. Atomic.int used instead of ref-with-mutex so callers
   of [metrics] don't need to grab the cache lock. *)
let counter_hits = Atomic.make 0
let counter_misses = Atomic.make 0
let counter_bypasses = Atomic.make 0
let counter_fetch_errors = Atomic.make 0

(* ------------------------------------------------------------------ *)
(* REST-based number fetch. qa-king observed that [gh pr view] via
   GraphQL returns false negatives ("Could not resolve" for real PRs),
   so we use the REST endpoint directly: it returns exactly what exists. *)
(* ------------------------------------------------------------------ *)

let parse_numbers_from_jq_output (out : string) : int list =
  (* Output is one integer per line, possibly trailing newline. *)
  out
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         let s = String.trim line in
         if s = "" then None
         else
           match int_of_string_opt s with
           | Some n when n > 0 -> Some n
           | _ -> None)

(** GitHub's [/repos/{slug}/issues] endpoint returns both issues AND PRs
    (PRs are a subtype of issues in the REST API). For the Issue kind
    we filter out entries where [pull_request] is set, leaving only
    genuine issues. For PR kind the [/pulls] endpoint needs no filter. *)
let jq_filter = function
  | PR -> ".[] | .number"
  | Issue -> ".[] | select(.pull_request == null) | .number"

let fetch_numbers ~(config : Room.config) ~(repo_slug : string) ~(kind : entity_kind)
    : int list option
  =
  let endpoint =
    Printf.sprintf "repos/%s/%s?state=all&per_page=%d"
      repo_slug (kind_path kind) fetch_page_size
  in
  let raw =
    Printf.sprintf "gh api %s --jq %s"
      (Filename.quote endpoint)
      (Filename.quote (jq_filter kind))
  in
  let scoped = Keeper_gh_env.with_env config raw in
  let shell = Printf.sprintf "%s 2>/dev/null" scoped in
  match
    Process_eio.run_argv_with_status
      ~timeout_sec:fetch_timeout_sec
      [ "/bin/zsh"; "-lc"; shell ]
  with
  | Unix.WEXITED 0, out -> Some (parse_numbers_from_jq_output out)
  | _ ->
    Atomic.incr counter_fetch_errors;
    None

(* ------------------------------------------------------------------ *)
(* Cache lookup with TTL + lazy population *)
(* ------------------------------------------------------------------ *)

let now () = Unix.gettimeofday ()

let entry_is_fresh entry =
  entry.populated && now () -. entry.fetched_at < cache_ttl_sec

(** Read or populate the entry for [(repo_slug, kind)].
    Returns the entry; [populated=false] means fetch failed. *)
let get_or_populate ~config ~repo_slug ~kind : cache_entry =
  Eio.Mutex.use_rw ~protect:true cache_lock (fun () ->
    let key = (repo_slug, kind) in
    match Hashtbl.find_opt cache key with
    | Some entry when entry_is_fresh entry -> entry
    | _ ->
      let entry =
        match fetch_numbers ~config ~repo_slug ~kind with
        | Some numbers ->
          { numbers; fetched_at = now (); populated = true }
        | None ->
          (* Fetch failed: record a short-lived empty entry so we don't
             retry the subprocess on every validation call in a burst. *)
          { numbers = []; fetched_at = now (); populated = false }
      in
      Hashtbl.replace cache key entry;
      entry)

let validate_number ~config ~repo_slug ~kind ~number : validation_result =
  if number <= 0 then `Unknown
  else if repo_slug = "" then `Unknown
  else
    let entry = get_or_populate ~config ~repo_slug ~kind in
    if not entry.populated then begin
      Atomic.incr counter_bypasses;
      `Unknown
    end
    else if List.mem number entry.numbers then begin
      Atomic.incr counter_hits;
      `Valid
    end
    else begin
      Atomic.incr counter_misses;
      `Invalid entry.numbers
    end

let invalidate ~repo_slug ~kind =
  Eio.Mutex.use_rw ~protect:true cache_lock (fun () ->
    Hashtbl.remove cache (repo_slug, kind))

let metrics () : (string * int) list =
  [ "hits", Atomic.get counter_hits
  ; "misses", Atomic.get counter_misses
  ; "bypasses", Atomic.get counter_bypasses
  ; "fetch_errors", Atomic.get counter_fetch_errors
  ]


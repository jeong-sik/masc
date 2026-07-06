(* Keeper_memory_bank_selection — candidate selection pipeline, dedup,
   consensus detection, placeholder filtering, and snapshot extraction.
   Extracted from keeper_memory_bank.ml during godfile decomposition. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_memory_policy

let with_stdlib_mutex mutex f =
  Stdlib.Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) f
;;

let memory_bank_locks_mu = Stdlib.Mutex.create ()
let memory_bank_locks : (string, Stdlib.Mutex.t) Hashtbl.t = Hashtbl.create 64

let memory_bank_lock_for path =
  with_stdlib_mutex memory_bank_locks_mu (fun () ->
    match Hashtbl.find_opt memory_bank_locks path with
    | Some mutex -> mutex
    | None ->
      let mutex = Stdlib.Mutex.create () in
      Hashtbl.add memory_bank_locks path mutex;
      mutex)
;;

let with_memory_bank_lock path f =
  let mutex = memory_bank_lock_for path in
  with_stdlib_mutex mutex f
;;

type candidate_selection_result = {
  selected: (string * string * int) list;
  dropped_by_kind: (string * int) list;
  dropped_by_total_cap: int;
  suppressed_synthetic_candidates: int;
}

let empty_candidate_selection =
  {
    selected = [];
    dropped_by_kind = [];
    dropped_by_total_cap = 0;
    suppressed_synthetic_candidates = 0;
  }

let select_memory_candidates
    (rows : (string * string * int) list) : candidate_selection_result =
  let total_cap = total_cap () in
  let kind_caps = kind_caps () in
  let used_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let dropped_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let rec go acc dropped_total rest =
    match rest with
    | [] ->
        {
          selected = List.rev acc;
          dropped_by_kind =
            Hashtbl.to_seq dropped_by_kind
            |> List.of_seq
            |> List.sort (fun (a, _) (b, _) -> String.compare a b);
          dropped_by_total_cap = dropped_total;
          suppressed_synthetic_candidates = 0;
        }
    | _ when List.length acc >= total_cap ->
        {
          selected = List.rev acc;
          dropped_by_kind =
            Hashtbl.to_seq dropped_by_kind
            |> List.of_seq
            |> List.sort (fun (a, _) (b, _) -> String.compare a b);
          dropped_by_total_cap = dropped_total + List.length rest;
          suppressed_synthetic_candidates = 0;
        }
    | (kind, text, pr) :: rest' ->
        let cap = cap_for_kind kind_caps kind in
        let used = Option.value ~default:0 (Hashtbl.find_opt used_by_kind kind) in
        if cap <= 0 || used >= cap then begin
          let cur =
            Option.value ~default:0 (Hashtbl.find_opt dropped_by_kind kind)
          in
          Hashtbl.replace dropped_by_kind kind (cur + 1);
          go acc dropped_total rest'
        end else begin
          Hashtbl.replace used_by_kind kind (used + 1);
          go ((kind, text, pr) :: acc) dropped_total rest'
        end
  in
  go [] 0 rows

(** Filter a list to unique items by a key function.
    Empty keys are skipped (treated as duplicates). *)
let dedup_by_key (key_of : 'a -> string) (items : 'a list) : 'a list =
  let module SS = Set_util.StringSet in
  let rec go seen acc = function
    | [] -> List.rev acc
    | item :: rest ->
      let key = key_of item in
      if key = "" || SS.mem key seen then go seen acc rest
      else go (SS.add key seen) (item :: acc) rest
  in
  go SS.empty [] items

let jaccard_similarity = Text_similarity.jaccard_similarity

(* Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_KEEPER_MEMORY_DEDUP_SIMILARITY_THRESHOLD]: hyperparameters
   belong in code, not in [Sys.getenv_opt]. *)
let semantic_dedup_similarity_threshold () = 0.85

let dedup_memory_candidates
    (items : (string * string * int) list) : (string * string * int) list =
  let exact =
    dedup_by_key
      (fun (kind, text, _) ->
        String.lowercase_ascii (String.trim kind ^ ":" ^ String.trim text))
      items
  in
  let threshold = semantic_dedup_similarity_threshold () in
  if threshold >= 1.0 then exact
  else
    let rec go kept = function
      | [] -> List.rev kept
      | (kind, text, pr) :: rest ->
          let is_dup =
            List.exists
              (fun (_, kept_text, _) ->
                jaccard_similarity text kept_text >= threshold)
              kept
          in
          if is_dup then go kept rest
          else go ((kind, text, pr) :: kept) rest
    in
    go [] exact

(* Punctuation strip used by the dedup key — fully static, hoist to
   module level so the DFA is built once per process. *)
let normalize_punct_re =
  Re.Pcre.re {re|[ \t\n\r!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~]+|re} |> Re.compile

let normalize_memory_text_key (s : string) : string =
  s
  |> String.trim
  |> String.lowercase_ascii
  |> Re.replace_string normalize_punct_re ~by:""

(* Consensus marker: cache the compiled regex without using [Lazy.force].
   OCaml 5 documents Lazy as not concurrency-safe across fibers, systhreads,
   or domains.  This path can be reached from runtime/dashboard domains, so
   protect the tiny cache with a Stdlib mutex.  Keep the env-derived cache key
   so tests and operators that change the pattern in-process get a fresh
   compiled regex without paying the compile cost on every memory row. *)
let consensus_default_re = Re.Pcre.re {|\d{6,}ep\+?|} |> Re.compile

(* Stdlib.Mutex: this process-global cache is also forced from tests and
   runtime/dashboard domains outside an Eio context.  The critical section does
   not perform Eio I/O or yield, so a plain mutex is sufficient and avoids
   poisoning when first forced by multiple domains. *)
let consensus_re_mu = Stdlib.Mutex.create ()
let consensus_re_cached : (string * Re.re) option ref = ref None

let memory_env_opt = Keeper_memory_bank_env.memory_env_opt
let memory_env_int_logged = Keeper_memory_bank_env.memory_env_int_logged
let memory_env_bool_logged = Keeper_memory_bank_env.memory_env_bool_logged
let memory_llm_summary_enabled = Keeper_memory_bank_env.memory_llm_summary_enabled

let consensus_pattern_key () =
  match memory_env_opt "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" with
  | None -> ""
  | Some raw -> raw

let compile_consensus_re pattern =
  if pattern = "" then consensus_default_re
  else
    try Re.Pcre.re pattern |> Re.compile
    with exn ->
      Log.Keeper.warn
        "invalid MASC_KEEPER_MEMORY_CONSENSUS_PATTERN=%S: %s; using default"
        pattern (Printexc.to_string exn);
      consensus_default_re

let consensus_re () =
  let pattern = consensus_pattern_key () in
  Stdlib.Mutex.protect consensus_re_mu (fun () ->
    match !consensus_re_cached with
    | Some (cached_pattern, re) when String.equal cached_pattern pattern ->
        re
    | _ ->
        let re = compile_consensus_re pattern in
        consensus_re_cached := Some (pattern, re);
        re)

let has_inflated_consensus_marker (s : string) : bool =
  Re.execp (consensus_re ()) s

let memory_placeholders () =
  let base =
    [
      "";
      "none";
      "null";
      "na";
      "nil";
      "없음";
      "없다";
      "없어요";
      "없습니다";
      "해당없음";
      "해당 사항 없음";
      "모르겠음";
      "무";
      "미정";
    ]
  in
  match memory_env_opt "MASC_KEEPER_MEMORY_PLACEHOLDERS" with
  | None -> base
  | Some raw ->
      let extra =
        String.split_on_char ',' raw
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
      in
      base @ extra

let max_memory_text_length = Keeper_memory_bank_env.max_memory_text_length

let is_meaningful_memory_text (s : string) : bool =
  let key = normalize_memory_text_key s in
  let placeholders = memory_placeholders () in
  not (List.mem key placeholders)
  && not (Keeper_synthetic_marker.contains_marker s)
  && not (has_inflated_consensus_marker s)
  && not (String_util.contains_substring s "[turn budget exhausted")
  && String.length s <= max_memory_text_length ()

let memory_candidates_from_snapshot
    (snapshot : keeper_state_snapshot) : candidate_selection_result =
  let add_opt kind value acc =
    match value with
    | None -> acc
    | Some text ->
        let text = String.trim text in
        if text = "" || not (is_meaningful_memory_text text) then acc
        else
          let priority =
            match snapshot.priority with
            | Some p -> max 1 (min 100 p)
            | None -> tuned_priority_for_candidate ~kind ~text
          in
          ( kind,
            text,
            priority )
          :: acc
  in
  let add_list kind values acc =
    List.fold_left
      (fun acc item ->
        let item = String.trim item in
        if item = "" || not (is_meaningful_memory_text item) then acc
        else
          let priority =
            match snapshot.priority with
            | Some p -> max 1 (min 100 p)
            | None -> tuned_priority_for_candidate ~kind ~text:item
          in
          ( kind,
            item,
            priority )
          :: acc)
      acc values
  in
  let raw =
    []
    |> add_opt "goal" snapshot.goal
    |> add_opt "progress" snapshot.progress
    |> add_opt "progress" snapshot.done_summary
    |> add_opt "next" snapshot.next_summary
    |> add_list "next" snapshot.next_items
    |> add_list "decision" snapshot.decisions
    |> add_list "open_question" snapshot.open_questions
    |> add_list "constraints" snapshot.constraints
    |> dedup_memory_candidates
    |> List.sort (fun (_, ta, pa) (_, tb, pb) ->
         let c = compare pb pa in
         if c <> 0 then c else String.compare ta tb)
  in
  select_memory_candidates raw

let memory_candidates_from_snapshot_gated ~is_synthetic snapshot =
  if is_synthetic
  then
    let ungated = memory_candidates_from_snapshot snapshot in
    let dropped_by_kind =
      List.fold_left
        (fun total (_, count) -> total + count)
        0
        ungated.dropped_by_kind
    in
    {
      empty_candidate_selection with
      suppressed_synthetic_candidates =
        List.length ungated.selected + ungated.dropped_by_total_cap + dropped_by_kind;
    }
  else memory_candidates_from_snapshot snapshot

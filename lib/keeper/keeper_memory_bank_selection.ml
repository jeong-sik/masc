(* Keeper_memory_bank_selection -- lock management, deduplication,
   consensus detection, and durable-memory text validation. *)

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

(** RFC-0327 §A1 — Remove rows that are similarity-duplicates of earlier rows.

    For each row, compare its text against all preceding rows.  When the
    jaccard similarity is >= [threshold], the later row is considered a
    duplicate and is dropped.  Returns the filtered list together with
    the count of dropped rows and a mapping from dropped-row identities
    to the identity of the surviving (earlier) row.

    This is intentionally separate from [dedup_by_key]: key-based dedup
    catches exact matches cheaply; similarity dedup catches paraphrase
    duplicates that share enough tokens. *)
let similarity_dedup
    ~(threshold : float)
    ~(key_of : 'a -> string)
    ~(text_of : 'a -> string)
    (items : 'a list)
  : 'a list * int * (string * string) list =
  let n = List.length items in
  if n <= 1 then (items, 0, [])
  else
    let arr = Array.of_list items in
    let alive = Array.make n true in
    let merge_map : (string * string) list ref = ref [] in
    let drop_count = ref 0 in
    for i = 1 to n - 1 do
      if alive.(i) then begin
        let ti = text_of arr.(i) in
        let dominated = ref false in
        for j = 0 to i - 1 do
          if alive.(j) && not !dominated then begin
            let tj = text_of arr.(j) in
            let sim = jaccard_similarity ti tj in
            if Float.compare sim threshold >= 0 then begin
              dominated := true;
              alive.(i) <- false;
              incr drop_count;
              merge_map :=
                (key_of arr.(i), key_of arr.(j)) :: !merge_map
            end
          end
        done
      end
    done;
    let result =
      Array.to_list arr
      |> List.mapi (fun idx item -> (alive.(idx), item))
      |> List.filter_map (fun (keep, item) -> if keep then Some item else None)
    in
    (result, !drop_count, List.rev !merge_map)

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

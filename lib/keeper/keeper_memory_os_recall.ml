(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files. *)

open Keeper_memory_os_types

let default_max_facts = 8
let default_max_episodes = 2
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

let render_fact ~now fact =
  let score = Keeper_memory_os_policy.score_fact ~now fact in
  let source = fact.source in
  Printf.sprintf
    "- [category=%s confidence=%.2f score=%.3f turn=%d] %s"
    (sanitize_atom fact.category)
    fact.confidence
    score
    source.turn
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

let scored_facts ~now facts =
  facts
  |> List.filter (fact_is_current ~now)
  |> List.map (fun fact -> Keeper_memory_os_policy.score_fact ~now fact, fact)
  |> List.sort (fun (a, _) (b, _) -> compare b a)
  |> List.map snd
;;

let render_context_exn ~keeper_id ~now ~max_facts ~max_episodes () =
  let max_facts = max 0 max_facts in
  let max_episodes = max 0 max_episodes in
  let facts =
    Keeper_memory_os_io.read_facts_tail ~keeper_id ~n:(max fact_tail_scan max_facts)
    |> scored_facts ~now
    |> take max_facts
  in
  let episodes = Keeper_memory_os_io.read_episodes_tail ~keeper_id ~n:max_episodes in
  match facts, episodes with
  | [], [] -> ""
  | _ ->
    let fact_lines = List.map (render_fact ~now) facts in
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
      ()
  =
  try render_context_exn ~keeper_id ~now ~max_facts ~max_episodes () with
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

let render_if_enabled ~keeper_id ~now () =
  if not (enabled ())
  then None
  else (
    match String.trim (render_context ~keeper_id ~now ()) with
    | "" -> None
    | block -> Some block)
;;

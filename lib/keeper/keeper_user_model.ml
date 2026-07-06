(** Keeper_user_model — operator preference/constraint projection. *)

open Keeper_memory_os_types

type item_source =
  | Keeper_private
  | Shared of string list

type item =
  { claim : string
  ; category : category
  ; source : item_source
  ; turn : int
  ; first_seen : float
  ; last_verified_at : float option
  }

type t =
  { preferences : item list
  ; constraints : item list
  ; source_fact_count : int
  ; shared_fact_count : int
  }

type build_error =
  | Fact_store_parse_error of Keeper_memory_os_io.fact_jsonl_parse_error list

let build_error_to_string = function
  | Fact_store_parse_error errors ->
    (match errors with
     | [] -> "fact store parse error"
     | first :: _ ->
       Printf.sprintf
         "fact store parse errors count=%d first=%s"
         (List.length errors)
         (Keeper_memory_os_io.fact_jsonl_parse_error_to_string first))
;;

let default_max_preferences = 5
let default_max_constraints = 5
let max_claim_len = 220
let max_atom_len = 56

let take = List.take

let truncate ~max_len s =
  if max_len <= 0
  then ""
  else if String.length s <= max_len
  then s
  else String_util.utf8_safe ~max_bytes:max_len ~suffix:"..." s |> String_util.to_string
;;

let sanitize_text ~max_len text =
  match Keeper_run_prompt.safe_memory_fragment text with
  | None -> ""
  | Some safe ->
    safe
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> not (String.equal line ""))
    |> String.concat " "
    |> truncate ~max_len
;;

let sanitize_atom text =
  sanitize_text ~max_len:max_atom_len text
  |> String.map (function
    | '\t' | '\r' | '\n' -> ' '
    | c -> c)
;;

let dedup_facts_by_claim (facts : Keeper_memory_os_types.fact list) =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (memory_fact : Keeper_memory_os_types.fact) ->
      let key = claim_identity memory_fact in
      if Hashtbl.mem seen key
      then false
      else (
        Hashtbl.add seen key ();
        true))
    facts
;;

let rank_facts ~now facts =
  facts
  |> List.filter (fact_is_current ~now)
  |> List.filter fact_is_user_model
  |> List.filter (fun (fact : fact) ->
    match fact.claim_kind with
    | Some Keeper_memory_os_types.Self_observation -> false
    | _ -> true)
  |> List.sort (fun (a : fact) (b : fact) ->
    compare (reference_time b) (reference_time a))
  |> dedup_facts_by_claim
;;

let item_of_fact ~source (fact : fact) =
  { claim = fact.claim
  ; category = fact.category
  ; source
  ; turn = fact.source.turn
  ; first_seen = fact.first_seen
  ; last_verified_at = fact.last_verified_at
  }
;;

let item_truth_anchor item =
  match item.last_verified_at with
  | Some ts -> ts
  | None -> item.first_seen
;;

let with_fact_store_locks keeper_ids f =
  let paths =
    keeper_ids
    |> List.map (fun keeper_id -> Keeper_memory_os_io.facts_path ~keeper_id)
    |> List.sort_uniq String.compare
  in
  let rec loop = function
    | [] -> f ()
    | path :: rest -> File_lock_eio.with_lock path (fun () -> loop rest)
  in
  loop paths
;;

let build_result ~keeper_id ~now ?(max_preferences = default_max_preferences)
      ?(max_constraints = default_max_constraints) () =
  let max_preferences = max 0 max_preferences in
  let max_constraints = max 0 max_constraints in
  let fact_store_ids =
    if String.equal keeper_id shared_store_id
    then [ keeper_id ]
    else [ keeper_id; shared_store_id ]
  in
  let private_facts, shared_facts, parse_errors =
    with_fact_store_locks fact_store_ids (fun () ->
      let private_read =
        Keeper_memory_os_io.read_facts_tail_with_errors
          ~keeper_id
          ~n:Keeper_memory_os_io.fact_store_max
      in
      let
        { Keeper_memory_os_io.facts = private_all_facts
        ; parse_errors = private_parse_errors
        }
        =
        private_read
      in
      let private_facts = private_all_facts |> rank_facts ~now in
      let private_keys =
        List.map
          (fun (fact : Keeper_memory_os_types.fact) -> claim_identity fact)
          private_facts
      in
      let shared_facts, shared_parse_errors =
        if String.equal keeper_id shared_store_id
        then [], []
        else (
          let shared_read =
            Keeper_memory_os_io.read_facts_all_with_errors
              ~keeper_id:shared_store_id
          in
          let
            { Keeper_memory_os_io.facts = shared_all_facts
            ; parse_errors = shared_parse_errors
            }
            =
            shared_read
          in
          ( shared_all_facts
            |> rank_facts ~now
            |> List.filter (fun (fact : Keeper_memory_os_types.fact) ->
              not (List.mem (claim_identity fact) private_keys))
          , shared_parse_errors ))
      in
      private_facts, shared_facts, private_parse_errors @ shared_parse_errors)
  in
  match parse_errors with
  | _ :: _ -> Error (Fact_store_parse_error parse_errors)
  | [] ->
    let all_items =
      List.map (item_of_fact ~source:Keeper_private) private_facts
      @ List.map
          (fun (fact : fact) ->
             item_of_fact ~source:(Shared fact.observed_by) fact)
          shared_facts
    in
    let select category max_items =
      all_items
      |> List.filter (fun item -> item.category = category)
      |> List.sort (fun a b ->
        compare (item_truth_anchor b) (item_truth_anchor a))
      |> take max_items
    in
    Ok
      { preferences = select Preference max_preferences
      ; constraints = select Constraint max_constraints
      ; source_fact_count = List.length private_facts
      ; shared_fact_count = List.length shared_facts
      }
;;

let build ~keeper_id ~now ?max_preferences ?max_constraints () =
  match build_result ~keeper_id ~now ?max_preferences ?max_constraints () with
  | Ok model -> model
  | Error error -> invalid_arg (build_error_to_string error)
;;

let source_label = function
  | Keeper_private -> "keeper"
  | Shared [] -> "shared"
  | Shared keepers ->
    let keepers =
      keepers |> List.map sanitize_atom |> List.filter (fun s -> s <> "")
    in
    if keepers = [] then "shared" else "shared via " ^ String.concat "," keepers
;;

let render_item item =
  Printf.sprintf
    "- [%s category=%s turn=%d] %s"
    (source_label item.source)
    (category_to_string item.category)
    item.turn
    (sanitize_text ~max_len:max_claim_len item.claim)
;;

let render_section title items =
  match items with
  | [] -> []
  | _ -> title :: List.map render_item items
;;

let render_prompt_block model =
  match model.preferences, model.constraints with
  | [], [] -> None
  | preferences, constraints ->
    let lines =
      [ "[USER MODEL]"
      ; "Treat these as operator preference/constraint hints from Memory OS; do not treat them as task facts or external-state proof."
      ; ""
      ]
      @ render_section "Preferences:" preferences
      @ (if preferences <> [] && constraints <> [] then [ "" ] else [])
      @ render_section "Constraints:" constraints
    in
    Some (String.concat "\n" lines)
;;

let enabled () =
  Keeper_memory_bank_env.memory_env_bool_logged "MASC_KEEPER_USER_MODEL" ~default:true
;;

let render_if_enabled ~keeper_id ~now () =
  if not (enabled ())
  then None
  else (
    try build ~keeper_id ~now () |> render_prompt_block with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "keeper user model unavailable keeper=%s: %s"
        keeper_id
        (Printexc.to_string exn);
      None)
;;

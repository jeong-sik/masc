(** Keeper_tool_observation - runtime tool-call observation and surface
    reconciliation. *)

let keeper_tool_usage_snapshot ~base_path ~keeper_name : (string * int) list =
  Keeper_registry.tool_usage_of ~base_path keeper_name
  |> List.map (fun (tool_name, entry) -> tool_name, entry.Keeper_types.count)
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let tool_usage_delta ~(before : (string * int) list) ~(after : (string * int) list)
  : string list
  =
  let before_counts = Hashtbl.create 16 in
  List.iter
    (fun (tool_name, count) -> Hashtbl.replace before_counts tool_name count)
    before;
  after
  |> List.concat_map (fun (tool_name, after_count) ->
    let before_count =
      Option.value ~default:0 (Hashtbl.find_opt before_counts tool_name)
    in
    List.init (max 0 (after_count - before_count)) (fun _ -> tool_name))
;;

let merge_observed_tool_names
      ~(registry_observed_tool_names : string list)
      ~(hook_observed_tool_names : string list)
  : string list
  =
  let hook_counts = Hashtbl.create 16 in
  List.iter
    (fun tool_name ->
       let count = Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name) in
       Hashtbl.replace hook_counts tool_name (count + 1))
    hook_observed_tool_names;
  let emitted_extra = Hashtbl.create 16 in
  hook_observed_tool_names
  @ List.filter
      (fun tool_name ->
         let hook_count =
           Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name)
         in
         let already_emitted =
           Option.value ~default:0 (Hashtbl.find_opt emitted_extra tool_name)
         in
         if already_emitted < hook_count
         then (
           Hashtbl.replace emitted_extra tool_name (already_emitted + 1);
           false)
         else true)
      registry_observed_tool_names
;;

let merge_reported_and_observed_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
  : string list
  =
  match observed_tool_names with
  | [] -> reported_tool_names
  | _ ->
    let observed = Hashtbl.create 16 in
    List.iter (fun tool_name -> Hashtbl.replace observed tool_name ()) observed_tool_names;
    observed_tool_names
    @ List.filter
        (fun tool_name -> not (Hashtbl.mem observed tool_name))
        reported_tool_names
;;

let final_keeper_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
      ~(allowed_tool_names : string list)
  : string list
  =
  let allowed_tool_names =
    allowed_tool_names
    |> List.map Keeper_tool_resolution.canonical_tool_name
    |> Keeper_types.dedupe_keep_order
  in
  let allowed = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun tool_name -> Hashtbl.replace allowed tool_name ()) allowed_tool_names;
  let reported_tool_names =
    List.map Keeper_tool_resolution.canonical_tool_name reported_tool_names
  in
  let observed_tool_names =
    List.map Keeper_tool_resolution.canonical_tool_name observed_tool_names
  in
  let tool_names =
    match observed_tool_names with
    | [] -> reported_tool_names
    | _ :: _ ->
      let observed = Hashtbl.create (List.length observed_tool_names) in
      List.iter
        (fun tool_name -> Hashtbl.replace observed tool_name ())
        observed_tool_names;
      observed_tool_names
      @ List.filter
          (fun tool_name -> not (Hashtbl.mem observed tool_name))
          reported_tool_names
  in
  tool_names |> List.filter (fun tool_name -> Hashtbl.mem allowed tool_name)
;;

let result_text_for_progress_check output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let tool_result_has_material_progress ~(tool_name : string) ~(output_text : string)
  : bool
  =
  let tool_name = Keeper_tool_resolution.canonical_tool_name tool_name in
  let output_text = result_text_for_progress_check output_text |> String.trim in
  let idempotent_worktree_noop =
    String.equal tool_name "tool_execute"
    && String.starts_with ~prefix:"Worktree already exists:" output_text
  in
  (not (String.equal output_text "")) && not idempotent_worktree_noop
;;

let unexpected_tool_names ~(allowed_tool_names : string list) ~(tool_names : string list)
  : string list
  =
  let allowed_tool_names =
    allowed_tool_names
    |> List.map Keeper_tool_resolution.canonical_tool_name
    |> Keeper_types.dedupe_keep_order
  in
  let allowed = Hashtbl.create (List.length allowed_tool_names) in
  let seen = Hashtbl.create (List.length tool_names) in
  List.iter
    (fun tool_name ->
       Hashtbl.replace
         allowed
         (Keeper_tool_resolution.canonical_tool_name tool_name)
         ())
    allowed_tool_names;
  tool_names
  |> List.filter (fun tool_name ->
    let canonical = Keeper_tool_resolution.canonical_tool_name tool_name in
    if Hashtbl.mem allowed canonical || Hashtbl.mem seen canonical
    then false
    else (
      Hashtbl.replace seen canonical ();
      true))
;;

(** [has_valid_tool_call ~unexpected_tool_names ~tool_names] returns true iff
    at least one name in [tool_names] is absent from [unexpected_tool_names] -
    i.e. at least one call is on the keeper surface. Used by
    [Keeper_agent_run] (#8471) to decide whether a turn mixing unknown tools
    with valid ones should hard-fail or continue with a partial-tolerance WARN. *)
let has_valid_tool_call ~(unexpected_tool_names : string list) ~(tool_names : string list)
  : bool
  =
  let unexpected = Hashtbl.create (List.length unexpected_tool_names) in
  List.iter (fun n -> Hashtbl.replace unexpected n ()) unexpected_tool_names;
  List.exists (fun n -> not (Hashtbl.mem unexpected n)) tool_names
;;

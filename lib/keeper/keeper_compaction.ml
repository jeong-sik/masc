(** Keeper-private compaction: lossy fold for completed subtask turns.

    Compresses older turn groups into structured stubs that preserve
    task description, outcome, and tool artifact counts.
    More informative than SummarizeOld's first-sentence summaries.

    @since keeper-lossy-fold *)

(** Extract first sentence from a string (up to 120 chars). *)
let first_sentence (s : string) : string =
  let s = String.trim s in
  let max_len = 120 in
  let cut_at =
    let period = try Some (String.index s '.') with Not_found -> None in
    let newline = try Some (String.index s '\n') with Not_found -> None in
    match period, newline with
    | Some p, Some n -> Some (min p n + 1)
    | Some p, None -> Some (p + 1)
    | None, Some n -> Some n
    | None, None -> None
  in
  match cut_at with
  | Some pos when pos <= max_len -> String.sub s 0 pos
  | _ ->
    if String.length s > max_len then String.sub s 0 max_len ^ "..."
    else s

(** Extract task description from the first User message in a turn group. *)
let task_of_turn (msgs : Agent_sdk.Types.message list) : string =
  let rec find = function
    | [] -> "(no description)"
    | (m : Agent_sdk.Types.message) :: rest ->
      if m.role = Agent_sdk.Types.User then
        let text = Agent_sdk.Types.text_of_message m in
        if text = "" then find rest
        else first_sentence text
      else find rest
  in
  find msgs

(** Determine outcome from the last Assistant message in a turn group.
    "success" if it contains Text content, "partial" if only tool calls. *)
let outcome_of_turn (msgs : Agent_sdk.Types.message list) : string =
  let rec find_last_assistant = function
    | [] -> None
    | (m : Agent_sdk.Types.message) :: rest ->
      let later = find_last_assistant rest in
      if Option.is_some later then later
      else if m.role = Agent_sdk.Types.Assistant then Some m
      else None
  in
  match find_last_assistant msgs with
  | None -> "partial"
  | Some m ->
    let has_text = List.exists (function
      | Agent_sdk.Types.Text s -> String.trim s <> ""
      | _ -> false
    ) m.content in
    if has_text then "success" else "partial"

(** Count tool calls by name across all messages in a turn group. *)
let artifacts_of_turn (msgs : Agent_sdk.Types.message list) : (string * int) list =
  let tbl = Hashtbl.create 8 in
  List.iter (fun (m : Agent_sdk.Types.message) ->
    List.iter (function
      | Agent_sdk.Types.ToolUse { name; _ } ->
        let cur = try Hashtbl.find tbl name with Not_found -> 0 in
        Hashtbl.replace tbl name (cur + 1)
      | _ -> ()
    ) m.content
  ) msgs;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(** Format artifact counts as "name(N calls), ..." *)
let format_artifacts (arts : (string * int) list) : string =
  match arts with
  | [] -> "none"
  | _ ->
    arts
    |> List.map (fun (name, count) ->
      Printf.sprintf "%s(%d calls)" name count)
    |> String.concat ", "

(** Build a fold stub message for a group of turns. *)
let fold_stub_of_turns (turns : Agent_sdk.Types.message list list)
    : Agent_sdk.Types.message =
  let all_msgs = List.concat turns in
  let task = task_of_turn all_msgs in
  let outcome = outcome_of_turn all_msgs in
  let artifacts = artifacts_of_turn all_msgs in
  let n_turns = List.length turns in
  let stub_text = Printf.sprintf
    "[Folded: %s | %d turns]\nOutcome: %s\nArtifacts: %s"
    task n_turns outcome (format_artifacts artifacts)
  in
  { Agent_sdk.Types.role = Agent_sdk.Types.User;
    content = [Agent_sdk.Types.Text stub_text];
    name = None;
    tool_call_id = None }

(** The fold compaction function.

    Groups messages into turns via OAS [group_into_turns], preserves
    the last [keep_recent] turns, and folds the rest into a single
    structured stub. Only complete turns are folded — ToolUse/ToolResult
    pairs are never split because [group_into_turns] respects turn
    boundaries. *)
let fold_completed ~(keep_recent : int)
    (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let turns = Agent_sdk.Context_reducer.group_into_turns msgs in
  let total = List.length turns in
  if total <= keep_recent then msgs
  else
    let old_count = total - keep_recent in
    let rec split_at n acc = function
      | [] -> (List.rev acc, [])
      | x :: rest ->
        if n <= 0 then (List.rev acc, x :: rest)
        else split_at (n - 1) (x :: acc) rest
    in
    let old_turns, recent_turns = split_at old_count [] turns in
    match old_turns with
    | [] -> msgs
    | _ ->
      let stub = fold_stub_of_turns old_turns in
      stub :: List.concat recent_turns

let fold_completed_strategy ?(keep_recent = 10) () : Agent_sdk.Context_reducer.t =
  Agent_sdk.Context_reducer.custom (fold_completed ~keep_recent)

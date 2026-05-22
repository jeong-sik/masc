(** Completion contract — required-tool-use gating for keeper turns.

    Two-state typed contract:
    [Allow_text_or_tool] (default) — the turn may end with either text
    or a tool call.
    [Require_tool_use] — the turn MUST emit at least one tool call;
    a text-only completion violates the contract and the keeper turn
    is failed.

    The contract is derived from the [Agent_sdk.Types.tool_choice]
    option via [completion_contract_of_tool_choice] (exhaustive
    against the SDK variants per #8696, so future SDK constructors
    force a compile error rather than silent degradation), then
    progressively *tightened* across the turn by [merge_completion_
    contract] (Require dominates) and [run_completion_contract]
    (observed tool-use latches Require).

    Validation: [validate_completion_contract_presence] checks the
    boolean flag at observation time; [validate_completion_contract]
    checks the list of emitted tool names at finalization time.

    Verbatim extract from [Keeper_tool_disclosure]; the parent
    retains transparent type alias + 5 value aliases. *)

type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

let merge_completion_contract
      ~(previous : completion_contract)
      ~(current : completion_contract)
  : completion_contract
  =
  match previous, current with
  | Require_tool_use, _ | _, Require_tool_use -> Require_tool_use
  | Allow_text_or_tool, Allow_text_or_tool -> Allow_text_or_tool
;;

(** Issue #8696: exhaustive match against [Agent_sdk.Types.tool_choice].
    Previous catch-all silently mapped any future SDK constructor to
    [Allow_text_or_tool]; on an OAS pin bump that adds a constructor
    (e.g. requiring tool use under new conditions) the keeper would
    silently degrade. Listing every variant turns SDK drift into a
    compile error here so it is reviewed at the boundary. *)
let completion_contract_of_tool_choice (tool_choice : Agent_sdk.Types.tool_choice option)
  : completion_contract
  =
  match tool_choice with
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> Require_tool_use
  | Some (Agent_sdk.Types.Auto | Agent_sdk.Types.None_) -> Allow_text_or_tool
  | None -> Allow_text_or_tool
;;

let run_completion_contract
      ~(turn_contract : completion_contract)
      ~(required_tool_use_seen : bool)
  : completion_contract
  =
  if required_tool_use_seen then Require_tool_use else turn_contract
;;

let validate_completion_contract_presence
      ~(contract : completion_contract)
      ~(tool_present : bool)
  : (unit, string) result
  =
  match contract with
  | Allow_text_or_tool -> Ok ()
  | Require_tool_use ->
    if tool_present
    then Ok ()
    else
      Error
        "keeper turn violated required tool contract: no keeper-surface tools were called"
;;

let validate_completion_contract
      ~(contract : completion_contract)
      ~(tool_names : string list)
      ()
  : (unit, string) result
  =
  match contract with
  | Allow_text_or_tool -> Ok ()
  | Require_tool_use ->
    (match tool_names with
     | _ :: _ -> Ok ()
     | [] -> Error "keeper turn violated required tool contract: no tools were called")
;;

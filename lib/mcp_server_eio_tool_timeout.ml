(** Per-tool timeout policy for MCP [tools/call]. *)

type resolved_tool_timeout =
  { timeout_sec : float
  ; source_env : string option
  }

let tool_timeout_default_env = "MASC_TOOL_TIMEOUT_DEFAULT_SEC"
let tool_timeout_board_env = "MASC_TOOL_TIMEOUT_BOARD_SEC"
let tool_timeout_persona_generate_source = "internal:masc_persona_generate_oas_budget"

let default_tool_timeout_sec () = Env_config_runtime.Tools.timeout_default_sec ()

let board_write_tool_timeout_sec () =
  Env_config_runtime.Tools.board_write_timeout_sec ()
;;

(* SSOT for which board tools mutate state lives in [Tool_board]'s
   [tool_required_permission]: CanBroadcast (post/comment/vote/comment_vote/
   reaction/curation_submit) and CanAdmin (delete/cleanup) are all writes.
   Reads (list/get/stats/search/profile/hearths/curation_read) keep the global
   default timeout. Keep this list in sync when new mutating board tools are
   added. *)
let is_board_write_tool_name = function
  | "keeper_board_post"
  | "keeper_board_comment"
  | "keeper_board_vote"
  | "keeper_board_comment_vote"
  | "keeper_board_curation_submit"
  | "keeper_board_delete"
  | "keeper_board_cleanup"
  | "masc_board_post"
  | "masc_board_comment"
  | "masc_board_vote"
  | "masc_board_comment_vote"
  | "masc_board_delete"
  | "masc_board_cleanup"
  | "masc_board_reaction"
  | "masc_board_curation_submit" -> true
  | _ -> false
;;

let tool_timeout ~(tool_name : string) ~(_arguments : Yojson.Safe.t) :
  resolved_tool_timeout option
  =
  match tool_name with
  | "masc_keeper_msg" ->
    (* No fixed timeout for keeper_msg. Keeper has its own internal limits
       (max_turns, max_cost_usd, max_tokens) that control call duration.
       A fixed external timeout conflicts with multi-turn tool-use loops. *)
    None
  | "masc_transition" ->
    (* Transition can trigger anti-rationalization review on completion
       paths. A fixed timeout can report a false error while the state
       mutation continues in the background, leaving caller-visible status
       out of sync with persisted task state. *)
    None
  | "masc_persona_generate" ->
    (* Persona generation runs an OAS worker with its own 120s budget. Keep
       the outer MCP tools/call timeout above that budget so callers see the
       generation result or the OAS error instead of a premature MCP timeout. *)
    Some { timeout_sec = 150.0; source_env = Some tool_timeout_persona_generate_source }
  | name when is_board_write_tool_name name ->
    (* #10569: board writes can queue behind the JSONL persist mutex. Keep
       them bounded, but avoid forcing them through the generic 60s budget
       while persist-lock histograms identify queueing vs disk stall. *)
    Some
      { timeout_sec = board_write_tool_timeout_sec ()
      ; source_env = Some tool_timeout_board_env
      }
  | _ ->
    Some
      { timeout_sec = default_tool_timeout_sec ()
      ; source_env = Some tool_timeout_default_env
      }
;;

let tool_timeout_sec_opt ~(tool_name : string) ~(_arguments : Yojson.Safe.t) :
  float option
  =
  tool_timeout ~tool_name ~_arguments
  |> Option.map (fun timeout -> timeout.timeout_sec)
;;

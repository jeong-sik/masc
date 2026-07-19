module Sset = Set.Make (String)

(* [ToolUse] (assistant tool_calls) legitimately appear only on [Assistant]
   messages. [ToolResult] blocks are carried on [Tool]-role messages (OpenAI
   wire format) and on [User]-role messages (Anthropic wire format puts
   tool_result blocks in a user turn). Scoping by role stops a malformed
   [ToolUse] or [ToolResult] on a role that never carries it from being treated
   as a call or an answer, while still counting both legitimate answer carriers
   so an Anthropic-format result is not mistaken for a missing answer. *)

let is_assistant (m : Agent_sdk.Types.message) =
  match m.role with
  | Agent_sdk.Types.Assistant -> true
  | Agent_sdk.Types.System | Agent_sdk.Types.User | Agent_sdk.Types.Tool -> false
;;

let carries_answers (m : Agent_sdk.Types.message) =
  match m.role with
  | Agent_sdk.Types.Tool | Agent_sdk.Types.User -> true
  | Agent_sdk.Types.System | Agent_sdk.Types.Assistant -> false
;;

(* Result ids on this message that answer a call. Only [Tool]/[User]-role
   messages carry answers; a [ToolResult] on a System or Assistant message is
   malformed and does not count. *)
let answer_ids (m : Agent_sdk.Types.message) : Sset.t =
  if not (carries_answers m)
  then Sset.empty
  else
    List.fold_left
      (fun acc block ->
         match block with
         | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Sset.add tool_use_id acc
         | _ -> acc)
      Sset.empty
      m.content
;;

(* An assistant [ToolUse id] is orphaned iff no [ToolResult] with the same id
   appears on a later [Tool] message. [answered_after] holds result ids seen at
   strictly later positions (right-to-left scan), so a result that *precedes* its
   call does not rescue it — matching the provider rule that each tool_call must
   be followed by its result. *)
let is_orphan_call answered_after block =
  match block with
  | Agent_sdk.Types.ToolUse { id; _ } -> not (Sset.mem id answered_after)
  | _ -> false
;;

let drop (msgs : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  (* Right-to-left scan via [rev] + [fold_left] (both tail-recursive; a plain
     [fold_right] would risk stack overflow on long histories). *)
  let rev = List.rev msgs in
  (* Pass 1: does any assistant message hold an orphaned ToolUse? Answers are
     accumulated from strictly-later positions as we move leftward. *)
  let _, has_orphan =
    List.fold_left
      (fun (answered_after, found) (m : Agent_sdk.Types.message) ->
         let found =
           found
           || (is_assistant m && List.exists (is_orphan_call answered_after) m.content)
         in
         (Sset.union answered_after (answer_ids m), found))
      (Sset.empty, false)
      rev
  in
  if not has_orphan
  then msgs (* no orphan: return the input list physically unchanged *)
  else begin
    (* Pass 2: drop orphaned assistant ToolUse blocks and any message emptied by
       the removal. Only assistant ToolUse blocks are ever removed, so this only
       affects assistant turns. The [= []] / [<> []] tests are nil-constructor
       checks, not structural block comparisons. [fold_left] over [rev] rebuilds
       in original order (last processed first, prepended). *)
    let _, rebuilt =
      List.fold_left
        (fun (answered_after, acc) (m : Agent_sdk.Types.message) ->
           let m_out =
             if not (is_assistant m)
             then Some m
             else begin
               let content =
                 List.filter
                   (fun block -> not (is_orphan_call answered_after block))
                   m.content
               in
               let emptied_by_removal = content = [] && m.content <> [] in
               if emptied_by_removal then None else Some { m with content }
             end
           in
           let acc =
             match m_out with
             | Some m -> m :: acc
             | None -> acc
           in
           (Sset.union answered_after (answer_ids m), acc))
        (Sset.empty, [])
        rev
    in
    rebuilt
  end
;;

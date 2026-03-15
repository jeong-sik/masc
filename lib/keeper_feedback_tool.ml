(** Keeper_feedback_tool — MCP tool handler for human feedback on deliberation decisions. *)

open Tool_args
open Keeper_types

type tool_result = Keeper_types.tool_result

let handle_keeper_feedback_record (_ctx : _ context) args : tool_result =
  let keeper_name = get_string args "keeper_name" "" in
  let decision_id = get_string args "decision_id" "" |> String.trim in
  let score = get_float args "score" 0.0 in
  let comment = get_string args "comment" "" |> String.trim in
  if not (validate_name keeper_name) then
    (false, "invalid keeper name")
  else if decision_id = "" then
    (false, "decision_id is required")
  else if score < -1.0 || score > 1.0 then
    (false,
     Printf.sprintf "score must be between -1.0 and 1.0, got %.2f" score)
  else
    let config = _ctx.config in
    (* Verify the decision exists *)
    let all =
      Keeper_learning.read_decisions config ~keeper_name ~limit:0
    in
    let found =
      List.exists (fun (r : Keeper_learning.decision_record) -> r.id = decision_id) all
    in
    if not found then
      (false,
       Printf.sprintf "decision %s not found for keeper %s" decision_id
         keeper_name)
    else begin
      Keeper_learning.record_feedback config ~keeper_name ~decision_id ~score
        ~comment;
      let result_json =
        `Assoc
          [
            ("status", `String "ok");
            ("keeper_name", `String keeper_name);
            ("decision_id", `String decision_id);
            ("score", `Float score);
            ("comment", `String comment);
          ]
      in
      (true, Yojson.Safe.pretty_to_string result_json)
    end

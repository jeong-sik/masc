type t =
  | Recorded of
      { execution_id : string
      ; disposition : (unit, unit, unit) Tool_result.disposition
      }
  | Unrecorded
  | Unavailable of string

let of_retained_rows ~keeper_name ~rows
    (activation : Keeper_skill_activation_ledger.activation) =
  let module Ledger = Keeper_skill_activation_ledger in
  match activation.invocation with
  | Ledger.Instruction_invocation _ | Ledger.Nested_composition_invocation _ -> Unrecorded
  | Ledger.Composition_invocation { tool_name; execution_id; _ } ->
    let execution_id = Ids.Execution_id.to_string execution_id in
    let evidence = List.filter (fun row ->
      Json_util.get_string row "execution_id" = Some execution_id) rows in
    (match evidence with
     | [] -> Unrecorded
     | [ row ] ->
       let str = Json_util.get_string row in
       let int = Json_util.get_int row in
       if not (str "record_kind" = Some "tool_call"
         && str "keeper" = Some keeper_name
         && str "trace_id" = Some (Ids.Turn_ref.trace_id activation.turn_ref)
         && str "session_id" = Some (Ids.Turn_ref.trace_id activation.turn_ref)
         && int "keeper_turn_id" = Some (Ids.Turn_ref.absolute_turn activation.turn_ref)
         && int "turn" = Some activation.agent_core_turn
         && str "tool_use_id" = Some activation.skill_tool_use_id
         && str "tool" = Some tool_name) then
         Unavailable "Composition execution source differs from its activation"
       else
         (match row with
          | `Assoc fields ->
            (match List.assoc_opt "disposition" fields with
             | None -> Unrecorded
             | Some (`String raw) ->
               (match Tool_result.unit_disposition_of_string raw with
                | Ok disposition -> Recorded { execution_id; disposition }
                | Error detail -> Unavailable detail)
             | Some _ -> Unavailable "Composition disposition is malformed")
          | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
            Unavailable "Composition execution is malformed")
     | _ :: _ :: _ -> Unavailable "Composition execution evidence is ambiguous")

let of_rows ~keeper_name ~rows activation =
  match rows with
  | Ok rows -> of_retained_rows ~keeper_name ~rows activation
  | Error detail -> Unavailable detail

let to_yojson = function
  | Recorded { execution_id; disposition } ->
    `Assoc [ "status", `String (Tool_result.string_of_disposition disposition)
           ; "execution_id", `String execution_id ]
  | Unrecorded -> `Assoc [ "status", `String "unrecorded" ]
  | Unavailable detail ->
    `Assoc [ "status", `String "unavailable"; "detail", `String detail ]

let of_yojson json =
  match Json_util.get_string json "status" with
  | Some "unrecorded" -> Ok Unrecorded
  | Some "unavailable" ->
    (match Json_util.get_string_nonempty json "detail" with
     | Some detail -> Ok (Unavailable detail)
     | None -> Error "Composition execution evidence has no detail")
  | Some ("completed" | "deferred" | "failed" as status) ->
    (match Json_util.get_string_nonempty json "execution_id" with
     | None -> Error "Composition execution has no exact execution ID"
     | Some execution_id ->
       Tool_result.unit_disposition_of_string status
       |> Result.map (fun disposition -> Recorded { execution_id; disposition }))
  | Some _ | None -> Error "Composition execution outcome is unknown"

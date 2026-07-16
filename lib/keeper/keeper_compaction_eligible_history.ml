module T = Agent_sdk.Types
module Unit = Keeper_compaction_unit
module Int_map = Map.Make (Int)

module Summary = struct
  type t = string
  type error = Empty

  let create value = if String.equal value "" then Error Empty else Ok value
  let to_string value = value
end

type eligible_role =
  | User
  | Assistant

type eligible_unit =
  { index : int
  ; role : eligible_role
  ; message : T.message
  ; text_blocks : string list
  }

type classified_unit =
  | Eligible of eligible_unit
  | Protected of Unit.closed_unit

type t =
  { units : classified_unit list
  ; protected_suffix : T.message list
  }

type action =
  | Keep
  | Drop
  | Summarize of Summary.t

type decision =
  { unit : eligible_unit
  ; action : action
  }

type apply_error =
  | Unknown_unit of int
  | Unit_source_mismatch of int
  | Duplicate_decision of int
  | Missing_decisions of int list

type outcome =
  | No_compaction of T.message list
  | Compacted of T.message list

let eligible_role = function
  | T.User -> Some User
  | T.Assistant -> Some Assistant
  | T.System | T.Tool -> None
;;

let pure_text_blocks = function
  | [] -> None
  | blocks ->
    let rec collect texts = function
      | [] -> Some (List.rev texts)
      | T.Text text :: rest -> collect (text :: texts) rest
      | ( T.Thinking _
        | T.ReasoningDetails _
        | T.RedactedThinking _
        | T.Image _
        | T.Document _
        | T.Audio _
        | T.ToolUse _
        | T.ToolResult _ )
        :: _ ->
        None
    in
    collect [] blocks
;;

let classify index = function
  | Unit.Closed_tool_cycle _ as unit -> Protected unit
  | Unit.Ordinary_message message as unit ->
    (match
       ( eligible_role message.role
       , message.tool_call_id
       , message.metadata
       , pure_text_blocks message.content )
     with
     | Some role, None, [], Some text_blocks ->
       Eligible { index; role; message; text_blocks }
     | _ -> Protected unit)
;;

let of_messages messages =
  Unit.partition messages
  |> Result.map (fun (partition : Unit.partition) ->
    { units = List.mapi classify partition.closed_prefix
    ; protected_suffix = partition.protected_suffix
    })
;;

let eligible_units source =
  List.filter_map
    (function
      | Eligible unit -> Some unit
      | Protected _ -> None)
    source.units
;;

let unit_index unit = unit.index
let unit_role unit = unit.role
let unit_message unit = unit.message
let unit_text_blocks unit = unit.text_blocks
let keep unit = { unit; action = Keep }
let drop unit = { unit; action = Drop }
let summarize unit summary = { unit; action = Summarize summary }

let expected_units source =
  List.fold_left
    (fun units unit -> Int_map.add unit.index unit units)
    Int_map.empty
    (eligible_units source)
;;

let bind_decisions source decisions =
  let expected = expected_units source in
  let rec bind bound = function
    | [] ->
      let missing =
        Int_map.fold
          (fun index _ missing ->
             if Int_map.mem index bound then missing else index :: missing)
          expected
          []
        |> List.rev
      in
      if missing = [] then Ok bound else Error (Missing_decisions missing)
    | decision :: rest ->
      let index = decision.unit.index in
      (match Int_map.find_opt index expected with
       | None -> Error (Unknown_unit index)
       | Some expected_unit when expected_unit <> decision.unit ->
         Error (Unit_source_mismatch index)
       | Some _ when Int_map.mem index bound -> Error (Duplicate_decision index)
       | Some _ -> bind (Int_map.add index decision.action bound) rest)
  in
  bind Int_map.empty decisions
;;

let messages_of_closed_unit = function
  | Unit.Ordinary_message message -> [ message ]
  | Unit.Closed_tool_cycle messages -> messages
;;

let apply source decisions =
  bind_decisions source decisions
  |> Result.map (fun actions ->
    let changed, chunks_rev =
      List.fold_left
        (fun (changed, chunks) -> function
           | Protected unit ->
             changed, messages_of_closed_unit unit :: chunks
           | Eligible unit ->
             (match Int_map.find unit.index actions with
              | Keep -> changed, [ unit.message ] :: chunks
              | Drop -> true, [] :: chunks
              | Summarize summary ->
                let summarized =
                  { unit.message with
                    content = [ T.Text (Summary.to_string summary) ]
                  }
                in
                changed || summarized <> unit.message, [ summarized ] :: chunks))
        (false, [])
        source.units
    in
    let messages = List.concat (List.rev chunks_rev) @ source.protected_suffix in
    if changed then Compacted messages else No_compaction messages)
;;

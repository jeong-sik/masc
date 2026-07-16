module T = Agent_sdk.Types
module Unit = Keeper_compaction_unit
module Schema = Keeper_structured_output_schema
module Int_map = Map.Make (Int)
module String_set = Set.Make (String)

type decision =
  | Keep
  | Drop
  | Summarize of string

type planned_unit =
  | Kept of Unit.closed_unit
  | Dropped
  | Summarized of string

type observation =
  { summarized_units : int
  ; summarized_source_messages : int
  ; emitted_summary_messages : int
  ; dropped_units : int
  ; dropped_source_messages : int
  }

type t =
  { source : Unit.partition
  ; units : planned_unit list
  ; observation : observation
  }

type decode_error =
  | Expected_object
  | Missing_field of string
  | Duplicate_field of string
  | Expected_array of string
  | Expected_integer of string
  | Expected_string of string
  | Unknown_field of string
  | Blank_summary of int
  | Index_out_of_range of
      { index : int
      ; unit_count : int
      }
  | Duplicate_decision of int
  | Missing_decision of int
  | No_compaction
[@@deriving show]

let ( let* ) = Result.bind

let exact_object ~allowed = function
  | `Assoc fields as json ->
    let allowed = String_set.of_list allowed in
    let rec check seen = function
      | [] -> Ok json
      | (key, _) :: rest ->
        if not (String_set.mem key allowed)
        then Error (Unknown_field key)
        else if String_set.mem key seen
        then Error (Duplicate_field key)
        else check (String_set.add key seen) rest
    in
    check String_set.empty fields
  | _ -> Error Expected_object
;;

let field key = function
  | `Assoc fields ->
    (match
       List.filter_map
         (fun (candidate, value) ->
            if String.equal key candidate then Some value else None)
         fields
     with
     | [ value ] -> Ok value
     | [] -> Error (Missing_field key)
     | _ -> Error (Duplicate_field key))
  | _ -> Error Expected_object
;;

let rec map_result f = function
  | [] -> Ok []
  | value :: rest ->
    let* value = f value in
    let* rest = map_result f rest in
    Ok (value :: rest)
;;

let list_field key parse json =
  let* value = field key json in
  match value with
  | `List values -> map_result parse values
  | _ -> Error (Expected_array key)
;;

let int_list_field key =
  list_field key (function
    | `Int value -> Ok value
    | _ -> Error (Expected_integer key))
;;

let summarized_entry json =
  let index_key = Schema.compaction_unit_plan_field_unit_index in
  let summary_key = Schema.compaction_unit_plan_field_unit_summary in
  let* json = exact_object ~allowed:[ index_key; summary_key ] json in
  let* index_json = field index_key json in
  let* summary_json = field summary_key json in
  let* index =
    match index_json with
    | `Int value -> Ok value
    | _ -> Error (Expected_integer index_key)
  in
  match summary_json with
  | `String value when String.trim value <> "" -> Ok (index, value)
  | `String _ -> Error (Blank_summary index)
  | _ -> Error (Expected_string summary_key)
;;

let unit_to_json index = function
  | Unit.Ordinary_message message ->
    `Assoc
      [ "unit_index", `Int index
      ; "unit_type", `String "ordinary_message"
      ; "messages", `List [ Keeper_context_core.message_to_json message ]
      ]
  | Unit.Closed_tool_cycle messages ->
    `Assoc
      [ "unit_index", `Int index
      ; "unit_type", `String "closed_tool_cycle"
      ; "messages", `List (List.map Keeper_context_core.message_to_json messages)
      ]
;;

let input_json source =
  `Assoc
    [ "unit_count", `Int (List.length source.Unit.closed_prefix)
    ; "units", `List (List.mapi unit_to_json source.closed_prefix)
    ]
;;

let add_decision ~unit_count decisions index decision =
  if index < 0 || index >= unit_count
  then Error (Index_out_of_range { index; unit_count })
  else if Int_map.mem index decisions
  then Error (Duplicate_decision index)
  else Ok (Int_map.add index decision decisions)
;;

let rec add_indices ~unit_count decision decisions = function
  | [] -> Ok decisions
  | index :: rest ->
    let* decisions = add_decision ~unit_count decisions index decision in
    add_indices ~unit_count decision decisions rest
;;

let rec add_summaries ~unit_count decisions = function
  | [] -> Ok decisions
  | (index, summary) :: rest ->
    let* decisions =
      add_decision ~unit_count decisions index (Summarize summary)
    in
    add_summaries ~unit_count decisions rest
;;

let decode ~source json =
  let unit_count = List.length source.Unit.closed_prefix in
  let* json =
    exact_object
      ~allowed:
        [ Schema.compaction_unit_plan_field_kept_indices
        ; Schema.compaction_unit_plan_field_dropped_indices
        ; Schema.compaction_unit_plan_field_summarized_units
        ]
      json
  in
  let* kept =
    int_list_field Schema.compaction_unit_plan_field_kept_indices json
  in
  let* dropped =
    int_list_field Schema.compaction_unit_plan_field_dropped_indices json
  in
  let* summarized =
    list_field
      Schema.compaction_unit_plan_field_summarized_units
      summarized_entry
      json
  in
  let* decisions = add_indices ~unit_count Keep Int_map.empty kept in
  let* decisions = add_indices ~unit_count Drop decisions dropped in
  let* decisions = add_summaries ~unit_count decisions summarized in
  let unit_message_count = function
    | Unit.Ordinary_message _ -> 1
    | Unit.Closed_tool_cycle messages -> List.length messages
  in
  let rec bind index units_rev observation = function
    | [] ->
      if observation.summarized_units = 0 && observation.dropped_units = 0
      then Error No_compaction
      else Ok { source; units = List.rev units_rev; observation }
    | unit :: rest ->
      (match Int_map.find_opt index decisions with
       | None -> Error (Missing_decision index)
       | Some Keep ->
         bind (index + 1) (Kept unit :: units_rev) observation rest
       | Some Drop ->
         let observation =
           { observation with
             dropped_units = observation.dropped_units + 1
           ; dropped_source_messages =
               observation.dropped_source_messages + unit_message_count unit
           }
         in
         bind (index + 1) (Dropped :: units_rev) observation rest
       | Some (Summarize summary) ->
         let observation =
           { observation with
             summarized_units = observation.summarized_units + 1
           ; summarized_source_messages =
               observation.summarized_source_messages + unit_message_count unit
           ; emitted_summary_messages = observation.emitted_summary_messages + 1
           }
         in
         bind (index + 1) (Summarized summary :: units_rev) observation rest)
  in
  bind 0 []
    { summarized_units = 0
    ; summarized_source_messages = 0
    ; emitted_summary_messages = 0
    ; dropped_units = 0
    ; dropped_source_messages = 0
    }
    source.closed_prefix
;;

let apply plan =
  let messages = function
    | Kept (Unit.Ordinary_message message) -> [ message ]
    | Kept (Unit.Closed_tool_cycle messages) -> messages
    | Dropped -> []
    | Summarized summary -> [ T.text_message T.Assistant summary ]
  in
  List.concat_map messages plan.units @ plan.source.protected_suffix
;;

let observation plan = plan.observation

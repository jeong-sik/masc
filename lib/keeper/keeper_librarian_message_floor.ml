module Current = Keeper_memory_os_current
module Plan = Keeper_librarian_memory_plan
module Runtime = Keeper_librarian_runtime
module Unread = Keeper_librarian_unread
module H = Keeper_librarian_task_context
open Result.Syntax

type prepared =
  { anchor : Current.program_anchor
  ; program : Keeper_memory_os_program.t
  ; working_state : string option
  ; served_by : Runtime.served_slot option
  }

type error = { detail : string; reports : Runtime.not_committed list }

let lift result = Result.map_error (fun detail -> {detail;reports=[]}) result
let refused detail reports = Error {detail;reports}

type coordinate =
  | Atom_coordinate of string * int * int * int
  | Official_coordinate of string * int * int

module Coordinates = Set.Make (struct type t = coordinate let compare = compare end)

let coordinate = function
  | Unread.Atom {trace_id;history_start_boundary_line;atom;message_in_atom;_} ->
    Atom_coordinate (trace_id,history_start_boundary_line,atom,message_in_atom)
  | Unread.Official_turn {turn_ref;boundary_line;message_in_turn;_} ->
    Official_coordinate (Ids.Turn_ref.to_string turn_ref,boundary_line,message_in_turn)

let source_digest = function
  | Unread.Atom {message_sha256;_} | Unread.Official_turn {message_sha256;_} -> message_sha256

let validate_manifest sources (input : Keeper_librarian.input) =
  let* () = if sources=[] then Error "message floor requires a nonempty original source manifest"
    else Ok () in
  let rec bind seen sources messages = match sources,messages with
    | [], [] -> Ok ()
    | source::sources, message::messages ->
      let* _ = Unread.source_of_json (Unread.source_to_json source) in
      let key = coordinate source in
      if Coordinates.mem key seen then Error "duplicate message floor source coordinate"
      else if source_digest source <> Unread.message_digest message then
        Error "message floor source hash differs from its original message"
      else bind (Coordinates.add key seen) sources messages
    | [], _::_ | _::_, [] -> Error "message floor differs from its original source manifest" in
  let* () = bind Coordinates.empty sources input.messages in
  let message_count = List.length input.messages in
  let tool_count = List.length input.tool_observations in
  if List.for_all (fun (context : H.t) ->
    context.first_message >= 0 && context.first_message <= context.after_message
    && context.after_message <= message_count
    && context.first_tool_observation >= 0
    && context.first_tool_observation <= context.after_tool_observation
    && context.after_tool_observation <= tool_count) input.historical_task_contexts
  then Ok () else Error "message floor attribution is outside its original input"

(* Pending tool observations retain their original joined outcomes and vector
   offsets. Only the conversation slice moves to a one-message input. A tool
   from another source span must not acquire this message's attribution. *)
let contexts_for_input ~position ~pending_tools contexts =
  List.filter_map (fun (context : H.t) ->
    let selected = match position with
      | None -> false
      | Some position -> context.first_message <= position && position < context.after_message in
    let first_tool_observation,after_tool_observation =
      if pending_tools then context.first_tool_observation,context.after_tool_observation else 0,0 in
    if selected || first_tool_observation < after_tool_observation then
      Some {context with first_message=0;after_message=(if selected then 1 else 0);
        first_tool_observation;after_tool_observation}
    else None) contexts

let infer ?cli_runner ~base_path ~keepers_dir ~keeper_name ~sources ~unread_message
    ~previous_state ~unread_messages (input : Keeper_librarian.input) =
  let* () = validate_manifest sources input |> lift in
  let* () =
    if Keeper_identity.Keeper_id.to_string input.keeper_id = keeper_name then Ok ()
    else refused "message floor Keeper differs from its Memory store" [] in
  let* unread_messages = Unread.merge unread_messages [] |> lift in
  let* anchor = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name) |> lift in
  let initial = Current.program_anchor_snapshot anchor in
  let* plan = Plan.create ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref ~snapshot:initial
    |> Result.map_error Plan.error_to_string |> lift in
  let original_sources = sources in
  let rec read plan state served position holes steps reports_rev tools counterparts sources messages =
    let* current_unread = Unread.merge unread_messages holes |> lift in
    match sources,messages with
    | [], [] when tools<>[] || counterparts<>[] ->
      let historical_task_contexts = contexts_for_input ~position:None
        ~pending_tools:(tools<>[]) input.historical_task_contexts in
      let observations = {input with current=Plan.current plan;messages=[];
        historical_task_contexts;tool_observations=tools;counterpart_observations=counterparts} in
      (match Runtime.infer_memory_step ?cli_runner ~base_path ~keepers_dir ~keeper_id:keeper_name
         ~previous_state:state ~unread_messages:current_unread observations with
       | Runtime.Memory_inferred {step;served_by} ->
         let* plan = Plan.append plan step |> Result.map_error Plan.error_to_string |> lift in
         read plan (Some step.working_state) (Some served_by) position holes
           (([],step)::steps) reports_rev [] [] [] []
       | Runtime.Memory_not_inferred failure ->
         refused "host observations were not read" (List.rev_append reports_rev failure.reports))
    | [], [] ->
      let* program = Keeper_librarian_memory_program.create
        ~transaction_id:(Random_id.prefixed ~prefix:"librarian-floor-" ~bytes:16)
        ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref ~sources:original_sources
        ~unread:holes
        ~initial_current:(Option.map (fun (snapshot : Current.t) -> snapshot.facts) initial)
        ~steps:(List.rev steps) |> lift in
      Ok {anchor;program;working_state=state;served_by=served}
    | source::sources, message::messages ->
      let historical_task_contexts = contexts_for_input ~position:(Some position)
        ~pending_tools:(tools<>[]) input.historical_task_contexts in
      let one = {input with current=Plan.current plan;messages=[message];
        historical_task_contexts;tool_observations=tools;counterpart_observations=counterparts} in
      (match Runtime.infer_memory_step ?cli_runner ~base_path ~keepers_dir ~keeper_id:keeper_name
         ~previous_state:state ~unread_messages:current_unread one with
       | Runtime.Memory_inferred {step;served_by} ->
         let* plan = Plan.append plan step |> Result.map_error Plan.error_to_string |> lift in
         read plan (Some step.working_state) (Some served_by) (position+1) holes
           (([source],step)::steps) reports_rev [] [] sources messages
       | Runtime.Memory_not_inferred failure ->
         (match failure.exhausted_input_refusals with
          | Some (_::_ as reasons) ->
            let* hole = unread_message source ~reasons |> lift in
            let* () =
              if hole.Unread.source=source
                 && hole.reasons=Keeper_librarian_input_refusal.union reasons [] then Ok ()
              else refused "message floor unread callback changed its source or refusal causes" [] in
            let* holes = Unread.merge holes [hole] |> lift in
            read plan state served (position+1) holes steps
              (List.rev_append failure.reports reports_rev) tools counterparts sources messages
          | None | Some [] -> refused (Printf.sprintf "message %d was not read" position)
              (List.rev_append reports_rev failure.reports)))
    | [], _::_ | _::_, [] -> refused "message floor differs from its original source manifest" []
  in
  read plan previous_state None 0 [] [] [] input.tool_observations
    input.counterpart_observations sources input.messages

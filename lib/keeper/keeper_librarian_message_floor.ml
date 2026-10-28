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

module Machine = struct
  type question =
    { position : int
    ; input : Keeper_librarian.input
    ; sources : Unread.source list
    ; previous_state : string option
    ; unread_messages : Unread.t list
    }

  type finished =
    { program : Keeper_memory_os_program.t
    ; working_state : string option
    ; served_by : Runtime.served_slot option
    }

  type next = Ask of question | Finished of finished

  type read =
    { input : Keeper_librarian.input
    ; sources : Unread.source list
    ; unread : Unread.t list
    ; previous_state : string option
    }

  type t =
    { read : read
    ; transaction_id : string
    ; plan : Plan.t
    ; initial_current : Keeper_memory_os_types.fact list option
    ; state : string option
    ; served : Runtime.served_slot option
    ; position : int
    ; holes : Unread.t list
    ; steps_rev : (Unread.source list * Runtime.memory_step) list
    ; tools : Keeper_librarian.tool_observation list
    ; counterparts : Keeper_counterpart_observation.t list
    ; sources : Unread.source list
    ; messages : Agent_core.Types.message list
    }

  let read ~keeper_name ~sources ~unread_messages ~previous_state (input : Keeper_librarian.input) =
    let* () = validate_manifest sources input in
    let* () =
      if Keeper_identity.Keeper_id.to_string input.keeper_id = keeper_name then Ok ()
      else Error "message floor Keeper differs from its Memory store" in
    let* unread = Unread.merge unread_messages [] in
    Ok {input; sources; unread; previous_state}

  let start ~transaction_id ~plan (read : read) =
    if Plan.stages plan <> [] then Error "message floor must start from a plan with no staged decision"
    else
      Ok { read
         ; transaction_id
         ; plan
         ; initial_current =
             Option.map (fun (current : Keeper_librarian.current_selection) -> current.facts)
               (Plan.current plan)
         ; state = read.previous_state
         ; served = None
         ; position = 0
         ; holes = []
         ; steps_rev = []
         ; tools = read.input.tool_observations
         ; counterparts = read.input.counterpart_observations
         ; sources = read.sources
         ; messages = read.input.messages
         }

  let next t =
    let* unread_messages = Unread.merge t.read.unread t.holes in
    let base = t.read.input in
    let ask ~input ~sources =
      Ok (Ask {position = t.position; input; sources; previous_state = t.state; unread_messages}) in
    match t.sources, t.messages with
    | [], [] when t.tools <> [] || t.counterparts <> [] ->
      let historical_task_contexts = contexts_for_input ~position:None
        ~pending_tools:(t.tools <> []) base.historical_task_contexts in
      ask ~sources:[]
        ~input:{base with current = Plan.current t.plan; messages = []; historical_task_contexts;
                          tool_observations = t.tools; counterpart_observations = t.counterparts}
    | [], [] ->
      let* program = Keeper_librarian_memory_program.create ~transaction_id:t.transaction_id
        ~keeper_id:base.keeper_id ~turn_ref:base.turn_ref ~sources:t.read.sources ~unread:t.holes
        ~initial_current:t.initial_current ~steps:(List.rev t.steps_rev) in
      Ok (Finished {program; working_state = t.state; served_by = t.served})
    | source :: _, message :: _ ->
      let historical_task_contexts = contexts_for_input ~position:(Some t.position)
        ~pending_tools:(t.tools <> []) base.historical_task_contexts in
      ask ~sources:[source]
        ~input:{base with current = Plan.current t.plan; messages = [message]; historical_task_contexts;
                          tool_observations = t.tools; counterpart_observations = t.counterparts}
    | [], _ :: _ | _ :: _, [] -> Error "message floor differs from its original source manifest"

  let stage t ~served_by (step : Runtime.memory_step) =
    let* plan = Plan.append t.plan step |> Result.map_error Plan.error_to_string in
    Ok {t with plan; state = Some step.working_state; served = served_by;
               tools = []; counterparts = []}

  let answered t ?served_by step =
    match t.sources, t.messages with
    | source :: sources, _ :: messages ->
      let* staged = stage t ~served_by step in
      Ok {staged with position = t.position + 1; sources; messages;
                      steps_rev = ([source], step) :: t.steps_rev}
    | [], [] when t.tools <> [] || t.counterparts <> [] ->
      let* staged = stage t ~served_by step in
      Ok {staged with steps_rev = ([], step) :: t.steps_rev}
    | [], [] -> Error "message floor has no question left to answer"
    | [], _ :: _ | _ :: _, [] -> Error "message floor differs from its original source manifest"

  let unreadable t ~reasons ~(hole : Unread.t) =
    match t.sources, t.messages with
    | source :: sources, _ :: messages ->
      let* () =
        if hole.source = source && hole.reasons = Keeper_librarian_input_refusal.union reasons [] then Ok ()
        else Error "message floor unread callback changed its source or refusal causes" in
      let* holes = Unread.merge t.holes [hole] in
      Ok {t with holes; position = t.position + 1; sources; messages}
    | [], [] -> Error "host observations cannot become an unread message"
    | [], _ :: _ | _ :: _, [] -> Error "message floor differs from its original source manifest"
end

let infer ?cli_runner ~base_path ~keepers_dir ~keeper_name ~sources ~unread_message
    ~previous_state ~unread_messages (input : Keeper_librarian.input) =
  let* read = Machine.read ~keeper_name ~sources ~unread_messages ~previous_state input |> lift in
  let* anchor = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name) |> lift in
  let initial = Current.program_anchor_snapshot anchor in
  let* plan = Plan.create ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref ~snapshot:initial
    |> Result.map_error Plan.error_to_string |> lift in
  let* machine = Machine.start
    ~transaction_id:(Random_id.prefixed ~prefix:"librarian-floor-" ~bytes:16) ~plan read |> lift in
  let rec drive machine reports_rev =
    let* next = Machine.next machine |> lift in
    match next with
    | Machine.Finished {program; working_state; served_by} ->
      Ok {anchor; program; working_state; served_by}
    | Machine.Ask question ->
      (match Runtime.infer_memory_step ?cli_runner ~base_path ~keepers_dir ~keeper_id:keeper_name
         ~previous_state:question.previous_state ~unread_messages:question.unread_messages
         question.input with
       | Runtime.Memory_inferred {step; served_by} ->
         let* machine = Machine.answered machine ~served_by step |> lift in
         drive machine reports_rev
       | Runtime.Memory_not_inferred failure ->
         (match question.sources with
          | [] -> refused "host observations were not read" (List.rev_append reports_rev failure.reports)
          | [source] ->
            (match failure.exhausted_input_refusals with
             | Some (_::_ as reasons) ->
               let* hole = unread_message source ~reasons |> lift in
               let* machine = Machine.unreadable machine ~reasons ~hole |> lift in
               drive machine (List.rev_append failure.reports reports_rev)
             | None | Some [] ->
               refused (Printf.sprintf "message %d was not read" question.position)
                 (List.rev_append reports_rev failure.reports))
          | _ :: _ :: _ -> refused "message floor asked about more than one message" []))
  in
  drive machine []

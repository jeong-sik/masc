module Turn = Keeper_memory_recall_turn
module Candidates = Keeper_memory_recall_candidates
module Codec = Keeper_memory_recall_jev_codec
module Render = Keeper_memory_recall_render

type t =
  { status : string
  ; body : string option
  }

let prompt_blocks { status; body } =
  (Prompt_block_id.Recalled_memory_status, status)
  :: (match body with
      | Some body -> [ Prompt_block_id.Recalled_memory, body ]
      | None -> [])

let purpose ~current_input ~keeper_instructions ~turn_ref =
  `Assoc
    [ "current_input", `String current_input
    ; "keeper_instructions", `String keeper_instructions
    ; "turn_ref", Ids.Turn_ref.to_yojson turn_ref
    ]

let read_facts ~keepers_dir ~keeper_id =
  match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok (Some snapshot) -> Ok snapshot.facts
  | Ok None -> Ok []
  | Error detail -> Error detail

let describe_build_error = function
  | Codec.Duplicate_candidate_id id -> "two facts share the id " ^ id
  | Codec.Choice_set_invalid detail -> "the option set is invalid: " ^ detail

let is_judged = Keeper_memory_recall_standing.is_judged

type preparation_failure = Facts_unreadable | Request_not_built | Preparation_raised | Clock_unavailable

let failure_token = function
  | Facts_unreadable -> "facts_unreadable"
  | Request_not_built -> "request_not_built"
  | Preparation_raised -> "preparation_raised"
  | Clock_unavailable -> "clock_unavailable"

let unavailable ~keeper_id ~turn_ref ~memory_search_available failure =
  let reason = failure_token failure in
  Otel_metric_store.inc_counter Keeper_metrics.(to_string MemoryRecallPreparationFailures)
    ~labels:["keeper",keeper_id;"reason",reason] ();
  Some {status=Render.unavailable_status ~memory_search_available ~turn_ref ~reason;body=None}

(* The recall must not end the turn it is meant to help. Whatever raises in
   here (the store read and its lock, the IO pool job, the client, the
   renderer) reaches the turn through the hook and would end it, so the
   failure is logged and the turn receives only its unavailable status. A
   cancellation is the turn's own and passes. *)
let prepare_with ~judge ~read_facts ~keeper_id ~turn_ref ~memory_search_available =
  let unavailable = unavailable ~keeper_id ~turn_ref ~memory_search_available in
  if not (is_judged ~keeper_id)
  then None
  else
    try
      match read_facts () with
      | Error detail ->
        Log.Keeper.warn "memory recall facts could not be read keeper=%s: %s"
          keeper_id detail;
        unavailable Facts_unreadable
      | Ok facts ->
        (match judge (List.map Candidates.of_fact facts) with
         | Error build_error ->
           Log.Keeper.warn "memory recall request could not be built keeper=%s: %s"
             keeper_id (describe_build_error build_error);
           unavailable Request_not_built
         | Ok (Turn.Off _ | Turn.Nothing_to_judge) -> None
         | Ok (Turn.Judged judged) ->
           Some
             { status = Render.status ~memory_search_available ~turn_ref judged
             ; body = Render.body facts judged
             })
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Keeper.warn "memory recall preparation raised keeper=%s: %s"
        keeper_id (Printexc.to_string exn);
      unavailable Preparation_raised

(* The client puts a time limit on a request only with a clock. Without one a
   destination that accepts the connection and never answers would hold the
   turn's first model request, so a judged Keeper with no clock sends nothing. *)
let prepare ~memo ~config ~keepers_dir ~keeper_id ~turn_ref ~purpose ~memory_search_available =
  match Eio_context.get_clock_opt () with
  | None ->
    if is_judged ~keeper_id
    then (
      Log.Keeper.warn "memory recall has no clock to limit the request keeper=%s"
        keeper_id;
      unavailable ~keeper_id ~turn_ref ~memory_search_available Clock_unavailable)
    else None
  | Some clock ->
    prepare_with
      ~judge:(Turn.judge ~clock ~memo ~config ~keeper_id ~turn_ref ~purpose)
      ~read_facts:(fun () ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          read_facts ~keepers_dir ~keeper_id))
      ~keeper_id
      ~turn_ref
      ~memory_search_available

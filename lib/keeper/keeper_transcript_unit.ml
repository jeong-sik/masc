module T = Agent_core.Types
module Id_set = Set.Make (String)

type closed_unit =
  | Ordinary_message of T.message
  | Closed_tool_cycle of T.message list

type structural_error =
  | Empty_tool_use_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Empty_tool_result_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Message_tool_call_id_mismatch of
      { message_index : int
      ; message_tool_call_id : string
      ; content_tool_use_ids : string list
      }
  | Orphan_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Unknown_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_assistant_tool_use of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_use_id of
      { message_index : int
      ; tool_use_id : string
      }
  | Overlapping_tool_cycle of
      { message_index : int
      ; tool_use_id : string
      }
  | Tool_request_contains_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_result_tool_role of
      { message_index : int
      ; tool_use_id : string
      }
[@@deriving show]

type partition =
  { closed_prefix : closed_unit list
  ; protected_suffix : T.message list
  }

type provider_transcript_error =
  | Invalid_transcript_structure of structural_error
  | Unresolved_tool_results of { tool_use_ids : string list }
[@@deriving show]

type open_cycle =
  { expected : Id_set.t
  ; pending : Id_set.t
  ; messages_rev : T.message list
  }

let messages_of_closed_unit = function
  | Ordinary_message message -> [ message ]
  | Closed_tool_cycle messages -> messages
;;

(* Blank classification must not normalize the provider-owned identity used
   by cycle matching and persisted evidence. *)
let tool_id_is_blank tool_use_id = String.trim tool_use_id = ""

let top_level_anchors ~message_index blocks =
  let rec collect block_index uses results = function
    | [] -> Ok (List.rev uses, List.rev results)
    | T.ToolUse { id; _ } :: _ when tool_id_is_blank id ->
      Error
        (Empty_tool_use_id
           { message_index; block_index; tool_use_id = id })
    | T.ToolUse { id; _ } :: rest ->
      collect (block_index + 1) (id :: uses) results rest
    | T.ToolResult { tool_use_id; _ } :: _ when tool_id_is_blank tool_use_id ->
      Error
        (Empty_tool_result_id
           { message_index; block_index; tool_use_id })
    | T.ToolResult { tool_use_id; _ } :: rest ->
      collect (block_index + 1) uses (tool_use_id :: results) rest
    | (T.Text _
      | T.Thinking _
      | T.ReasoningDetails _
      | T.RedactedThinking _
      | T.Image _
      | T.Document _
      | T.Audio _)
      :: rest ->
      collect (block_index + 1) uses results rest
  in
  collect 0 [] [] blocks

let validate_message_tool_call_id ~message_index ~content_tool_use_ids = function
  | None -> Ok ()
  | Some message_tool_call_id ->
    (match content_tool_use_ids with
     | [ content_tool_use_id ]
       when String.equal message_tool_call_id content_tool_use_id ->
       Ok ()
     | content_tool_use_ids ->
       Error
         (Message_tool_call_id_mismatch
            { message_index; message_tool_call_id; content_tool_use_ids }))

let validated_top_level_anchors ~message_index (message : T.message) =
  match top_level_anchors ~message_index message.content with
  | Error _ as error -> error
  | Ok (tool_ids, result_ids) ->
    Result.map
      (fun () -> tool_ids, result_ids)
      (validate_message_tool_call_id
         ~message_index
         ~content_tool_use_ids:result_ids
         message.tool_call_id)

let rec add_tool_ids ~message_index seen = function
  | [] -> Ok seen
  | tool_use_id :: rest ->
      if Id_set.mem tool_use_id seen then
        Error (Duplicate_tool_use_id { message_index; tool_use_id })
      else add_tool_ids ~message_index (Id_set.add tool_use_id seen) rest

let rec consume_results ~message_index ~expected pending seen = function
  | [] -> Ok (pending, seen)
  | tool_use_id :: rest ->
      if Id_set.mem tool_use_id seen then
        Error (Duplicate_tool_result { message_index; tool_use_id })
      else if not (Id_set.mem tool_use_id expected) then
        Error (Unknown_tool_result { message_index; tool_use_id })
      else
        consume_results ~message_index ~expected
          (Id_set.remove tool_use_id pending)
          (Id_set.add tool_use_id seen) rest

let is_result_role = function
  | T.User | T.Tool -> true
  | T.System | T.Assistant -> false

(* [stop_with_units] freezes the valid closed units accumulated so far and moves
   the in-flight open tool cycle plus the offending message and everything after
   it into the protected suffix. Used only when [partition] runs in quarantine
   mode, so a single structural break compacts the valid prefix instead of
   rejecting the whole history. *)
let stop_with_units ~units_rev ~open_cycle ~message ~rest =
  let open_prefix =
    match open_cycle with None -> [] | Some cycle -> List.rev cycle.messages_rev
  in
  Ok
    { closed_prefix = List.rev units_rev
    ; protected_suffix = open_prefix @ (message :: rest)
    }

let partition ?(quarantine = false) messages =
  let rec loop index units_rev seen_tools seen_results open_cycle = function
    | [] ->
        let protected_suffix =
          match open_cycle with
          | None -> []
          | Some cycle -> List.rev cycle.messages_rev
        in
        Ok { closed_prefix = List.rev units_rev; protected_suffix }
    | (message : T.message) :: rest ->
        (match validated_top_level_anchors ~message_index:index message with
         | Error _ when quarantine ->
             stop_with_units ~units_rev ~open_cycle ~message ~rest
         | Error _ as error -> error
         | Ok (tool_ids, result_ids) ->
             (match message.role, tool_ids with
              | (T.System | T.User | T.Tool), tool_use_id :: _ ->
                  if quarantine then
                    stop_with_units ~units_rev ~open_cycle ~message ~rest
                  else
                    Error (Non_assistant_tool_use { message_index = index; tool_use_id })
              | _ ->
                  (match open_cycle, tool_ids, result_ids with
                   | Some _, tool_use_id :: _, _ ->
                       if quarantine then
                         stop_with_units ~units_rev ~open_cycle ~message ~rest
                       else
                         Error
                           (Overlapping_tool_cycle { message_index = index; tool_use_id })
                   | None, _, _ ->
                       (match add_tool_ids ~message_index:index Id_set.empty tool_ids with
                        | Error _ when quarantine ->
                            stop_with_units ~units_rev ~open_cycle ~message ~rest
                        | Error _ as error -> error
                        | Ok seen_tools ->
                            (match tool_ids, result_ids with
                             | [], tool_use_id :: _ ->
                                 if quarantine then
                                   stop_with_units ~units_rev ~open_cycle ~message ~rest
                                 else if Id_set.mem tool_use_id seen_results then
                                   Error
                                     (Duplicate_tool_result
                                        { message_index = index; tool_use_id })
                                 else
                                   Error
                                     (Orphan_tool_result
                                        { message_index = index; tool_use_id })
                             | [], [] ->
                                 loop (index + 1)
                                   (Ordinary_message message :: units_rev)
                                   seen_tools seen_results None rest
                             | tool_use_id :: _, _ :: _ ->
                                 if quarantine then
                                   stop_with_units ~units_rev ~open_cycle ~message ~rest
                                 else
                                   Error
                                     (Tool_request_contains_result
                                        { message_index = index; tool_use_id })
                             | _ :: _, [] ->
                                 let expected = Id_set.of_list tool_ids in
                                 loop (index + 1) units_rev seen_tools seen_results
                                   (Some
                                      { expected
                                      ; pending = expected
                                      ; messages_rev = [ message ]
                                      })
                                   rest))
                   | Some cycle, [], [] ->
                       loop (index + 1) units_rev seen_tools seen_results
                         (Some { cycle with messages_rev = message :: cycle.messages_rev })
                         rest
                   | Some _, [], tool_use_id :: _ when not (is_result_role message.role) ->
                       if quarantine then
                         stop_with_units ~units_rev ~open_cycle ~message ~rest
                       else
                         Error (Non_result_tool_role { message_index = index; tool_use_id })
                   | Some cycle, [], _ :: _ ->
                       (match
                          consume_results ~message_index:index ~expected:cycle.expected
                            cycle.pending seen_results result_ids
                        with
                        | Error _ when quarantine ->
                            stop_with_units ~units_rev ~open_cycle ~message ~rest
                        | Error _ as error -> error
                        | Ok (pending, seen_results) ->
                            let messages_rev = message :: cycle.messages_rev in
                            if Id_set.is_empty pending then
                              loop (index + 1)
                                (Closed_tool_cycle (List.rev messages_rev) :: units_rev)
                                Id_set.empty Id_set.empty None rest
                            else
                              loop (index + 1) units_rev seen_tools seen_results
                                (Some { cycle with pending; messages_rev })
                                rest))))
  in
  loop 0 [] Id_set.empty Id_set.empty None messages

let validate messages = Result.map (fun _partition -> ()) (partition messages)

let unresolved_tool_use_ids protected_suffix =
  let requested_rev, completed =
    List.fold_left
      (fun (requested_rev, completed) (message : T.message) ->
         List.fold_left
           (fun (requested_rev, completed) -> function
              | T.ToolUse { id; _ } -> id :: requested_rev, completed
              | T.ToolResult { tool_use_id; _ } ->
                requested_rev, Id_set.add tool_use_id completed
              | T.Text _
              | T.Thinking _
              | T.ReasoningDetails _
              | T.RedactedThinking _
              | T.Image _
              | T.Document _
              | T.Audio _ ->
                requested_rev, completed)
           (requested_rev, completed)
           message.content)
      ([], Id_set.empty)
      protected_suffix
  in
  requested_rev
  |> List.rev
  |> List.filter (fun tool_use_id -> not (Id_set.mem tool_use_id completed))
;;

let validate_provider_transcript messages =
  match partition messages with
  | Error error -> Error (Invalid_transcript_structure error)
  | Ok { protected_suffix = []; _ } -> Ok ()
  | Ok { protected_suffix; _ } ->
    Error
      (Unresolved_tool_results
         { tool_use_ids = unresolved_tool_use_ids protected_suffix })
;;

(* The content of a synthesized closer.  It states what is known (the call was
   issued, no result was recorded) and what is not (whether the call took
   effect), because masc has no durable per-tool-call effect receipt: the
   decision log's [tool_exec] record is written after execution and is lost
   with the unflushed buffer at exactly the crash this recovers from.  Claiming
   the tool failed would be a fabrication; claiming it succeeded would be
   worse. *)
let interrupted_tool_result_content =
  "interrupted: the server restarted before this tool result was recorded. The \
   call may or may not have taken effect. Verify current state before retrying."
;;

type tail_closure =
  { messages : T.message list
  ; closed_tool_use_ids : string list
  }

(* A tool cycle left open by process death is not corruption.  Checkpoint
   persistence stores it on purpose so recovery knows which calls were in
   flight — that is what [partition] returns as [protected_suffix], and why
   [validate] accepts it while [validate_provider_transcript] does not.  What
   was missing is the move that closes it: nothing appended the results, so the
   next dispatch rejected the transcript and the lane latched permanently.

   [close_open_tail] appends one [ToolResult] per unresolved [ToolUse] id, in
   the on-disk shape the rest of the history uses (role [Tool], one result per
   message, no message-level [tool_call_id]).  [Unattributed_tool_error] is the
   constructor for precisely this case — its own definition reads "a persisted
   failure whose original execution boundary did not record provenance" — and
   [Unknown] is the honest error class.

   A [structural_error] is passed through unchanged: a history that does not
   parse is genuine corruption and must keep latching. *)
(* The synthesized result a turn that never came back would have produced. *)
let interrupted_closer tool_use_id : T.message =
  { role = T.Tool
  ; content =
      [ T.ToolResult
          { tool_use_id
          ; content = interrupted_tool_result_content
          ; outcome =
              T.Tool_failed
                { failure_kind = T.Unattributed_tool_error; error_class = Some T.Unknown }
          ; json = None
          ; content_blocks = None
          }
      ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Close every open cycle where it sits, not only the one at the tail.

   [close_open_tail] repairs the shape an interruption leaves *if nothing has
   been appended since*. That is not the shape a keeper actually reaches. A
   turn dies mid-tool-call, the next turn appends its own request, and now the
   unclosed cycle is in the middle of the history: [partition] reports
   [Overlapping_tool_cycle] and rejects before any repair runs. The result is
   a keeper that fails at the same fixed [message_index] on every turn
   forever -- issue #31595, observed on one lab keeper (5+ turns), and again on
   2026-09-01 where one keeper went an hour without a single completed turn
   and another logged 585 of these in a day.

   The comment on [close_open_tail] said a structural break is corruption no
   synthesized result can repair. That is right for most of the family --
   [Orphan_tool_result] has no request to attach to, [Non_assistant_tool_use]
   puts a request in a role that cannot issue one -- but it is wrong for this
   member. [Overlapping_tool_cycle] means exactly one thing: a request whose
   results never arrived, and a later request that exposed it. That is the
   same missing result [close_open_tail] already synthesizes; only its
   position differs.

   So this walks the history and, wherever a request appears while a cycle is
   still open, inserts that cycle's closers immediately before it. Nothing is
   trimmed and nothing is reset: the history a keeper has already reasoned
   over stays, and the record now says the interrupted call failed rather than
   leaving a request the transcript never answers.

   A history that is broken some other way still latches. This closes cycles;
   it does not invent requests, and it cannot make an orphaned result belong
   to anything. *)
let close_open_cycles messages =
  let rec loop index acc_rev pending closed_rev = function
    | [] ->
      let closers = List.rev_map interrupted_closer pending in
      Ok
        { messages = List.rev_append acc_rev closers
        ; closed_tool_use_ids = List.rev closed_rev
        }
    | (message : T.message) :: rest ->
      (match validated_top_level_anchors ~message_index:index message with
       | Error _ as error -> error
       | Ok (tool_ids, result_ids) ->
         (* Results answer the open requests, whether or not the cycle is the
            one this pass opened. *)
         let pending =
           List.filter
             (fun id -> not (List.exists (String.equal id) result_ids))
             pending
         in
         (match tool_ids, pending with
          | _ :: _, _ :: _ ->
            (* A request while others are still unanswered: close them here,
               before this message, and carry on with this request open. *)
            let closers = List.rev_map interrupted_closer pending in
            loop
              (index + 1)
              (message :: List.rev_append (List.rev closers) acc_rev)
              tool_ids
              (List.rev_append pending closed_rev)
              rest
          | _ :: _, [] ->
            loop (index + 1) (message :: acc_rev) tool_ids closed_rev rest
          | [], _ -> loop (index + 1) (message :: acc_rev) pending closed_rev rest))
  in
  (* The walk above closes cycles; it does not judge the rest of the history.
     An orphaned result passes through it untouched, so the repair is checked
     rather than trusted: whatever [partition] still rejects is returned as
     the error it is. This is what makes the postcondition -- on [Ok],
     [validate_provider_transcript] returns [Ok ()] -- true by construction
     instead of by argument. *)
  match loop 0 [] [] [] messages with
  | Error _ as error -> error
  | Ok ({ messages = repaired; _ } as closure) ->
    (match partition repaired with
     | Ok _ -> Ok closure
     | Error _ as error -> error)
;;

let close_open_tail messages =
  match partition messages with
  | Error _ as error -> error
  | Ok { protected_suffix = []; _ } -> Ok { messages; closed_tool_use_ids = [] }
  | Ok { protected_suffix; _ } ->
    let closed_tool_use_ids = unresolved_tool_use_ids protected_suffix in
    let closer tool_use_id : T.message =
      { role = T.Tool
      ; content =
          [ T.ToolResult
              { tool_use_id
              ; content = interrupted_tool_result_content
              ; outcome =
                  T.Tool_failed
                    { failure_kind = T.Unattributed_tool_error
                    ; error_class = Some T.Unknown
                    }
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    in
    Ok
      { messages = messages @ List.map closer closed_tool_use_ids
      ; closed_tool_use_ids
      }
;;

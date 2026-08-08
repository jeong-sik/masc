open Result_syntax

type turn_authority =
  | Transient of int
  | Durable of Execution_agent_scope.turn

type t =
  { turn : turn_authority
  ; mutable provider : Execution_agent_scope.provider_attempt option
  }

let sdk_error error = Error.Internal (Execution_agent_scope.error_to_string error)

(* A [Closed Succeeded] turn/provider found at a resume ordinal under a still-open
   run: an idempotent completed boundary. [Settled_provider_closed] carries the
   still-open turn (window: crash inside [close_success] after the provider close
   but before the turn close) so the caller can finish that interrupted close;
   [Settled_turn_closed] needs no further journal write (window: crash after the
   turn close but before the root finish). *)
type settled_boundary =
  { provider : Execution_agent_scope.provider_attempt option
  ; turn_to_close : Execution_agent_scope.turn option
  }

type resumed =
  | Fresh
  | Active of t
  | Settled of settled_boundary

let open_turn scope ~ordinal =
  match scope with
  | None -> Ok { turn = Transient ordinal; provider = None }
  | Some scope ->
    (match Execution_agent_scope.resume_turn scope ~ordinal with
     | Error error -> Error (sdk_error error)
     | Ok (Resume_turn_open turn) -> Ok { turn = Durable turn; provider = None }
     | Ok Resume_turn_absent ->
       Execution_agent_scope.open_turn scope ~ordinal
       |> Result.map (fun turn -> { turn = Durable turn; provider = None })
       |> Result.map_error sdk_error
     | Ok (Resume_turn_settled _) ->
       (* A fresh turn ordinal must not already be a settled boundary; a collision
          is inconsistent topology rather than reopening durably-settled work. *)
       Error
         (sdk_error
            (Execution_agent_scope.Resume_topology_mismatch
               "fresh turn ordinal is already settled")))
;;

let resume_current scope =
  match scope with
  | None -> Ok Fresh
  | Some scope ->
    (match Execution_agent_scope.resume_current_turn scope with
     | Error error -> Error (sdk_error error)
     | Ok Resume_turn_absent -> Ok Fresh
     | Ok (Resume_turn_settled turn) ->
       (match Execution_agent_scope.resume_provider_attempt turn with
        | Error error -> Error (sdk_error error)
        | Ok Resume_provider_absent ->
          Error
            (sdk_error
               (Execution_agent_scope.Resume_topology_mismatch
                  "closed succeeded turn has no provider attempt authority"))
        | Ok (Resume_provider_settled provider) ->
          Ok (Settled { provider = Some provider; turn_to_close = None })
        | Ok (Resume_provider_open _) ->
          Error
            (sdk_error
               (Execution_agent_scope.Resume_topology_mismatch
                  "closed turn contains an open provider attempt")))
     | Ok (Resume_turn_open turn) ->
       (match Execution_agent_scope.resume_provider_attempt turn with
        | Error error -> Error (sdk_error error)
        | Ok Resume_provider_absent -> Ok Fresh
        | Ok (Resume_provider_settled provider) ->
          Ok (Settled { provider = Some provider; turn_to_close = Some turn })
        | Ok (Resume_provider_open provider) ->
          Ok (Active { turn = Durable turn; provider = Some provider })))
;;

let finalize_settled boundary =
  match boundary.turn_to_close with
  | None -> Ok ()
  | Some turn ->
    Execution_agent_scope.close_turn turn Execution_event.Succeeded
    |> Result.map_error sdk_error
;;

let turn_ordinal t =
  match t.turn with
  | Transient ordinal -> ordinal
  | Durable turn -> Execution_agent_scope.turn_ordinal turn
;;

let before_provider_attempt t binding =
  match t.turn with
  | Transient _ -> Ok ()
  | Durable turn ->
    Execution_agent_scope.open_provider_attempt turn ~ordinal:0 binding
    |> Result.map (fun provider -> t.provider <- Some provider)
    |> Result.map_error sdk_error
;;

let provider (t : t) = t.provider

let record_provider_response (t : t) response =
  match t.turn, t.provider with
  | Transient _, None -> Ok ()
  | Durable _, Some provider ->
    Execution_agent_scope.record_provider_response provider response
    |> Result.map_error sdk_error
  | Transient _, Some _ | Durable _, None ->
    Error
      (sdk_error
         (Execution_agent_scope.Resume_topology_mismatch
            "provider response has no matching provider attempt authority"))
;;

let provider_response (t : t) =
  match t.provider with
  | Some provider ->
    Execution_agent_scope.provider_response provider |> Result.map_error sdk_error
  | None ->
    Error
      (sdk_error
         (Execution_agent_scope.Resume_topology_mismatch
            "active execution has no provider response authority"))
;;

let invocations_settled (t : t) =
  match t.provider with
  | None -> Ok false
  | Some provider ->
    Execution_agent_scope.provider_invocations_settled provider
    |> Result.map_error sdk_error
;;

let invocations (t : t) =
  match t.provider with
  | None ->
    Error
      (sdk_error
         (Execution_agent_scope.Resume_topology_mismatch
            "active execution has no provider invocation authority"))
  | Some provider ->
    Execution_agent_scope.provider_invocations provider |> Result.map_error sdk_error
;;

let settled_invocations_with_results (t : t) =
  match t.provider with
  | None ->
    Error
      (sdk_error
         (Execution_agent_scope.Resume_topology_mismatch
            "active execution has no provider invocation authority"))
  | Some provider ->
    Execution_agent_scope.provider_settled_invocations provider
    |> Result.map_error sdk_error
;;

let settled_invocations boundary =
  match boundary.provider with
  | None -> Ok []
  | Some provider ->
    Execution_agent_scope.provider_invocations provider |> Result.map_error sdk_error
;;

let settled_response boundary =
  match boundary.provider with
  | Some provider ->
    Execution_agent_scope.provider_response provider |> Result.map_error sdk_error
  | None ->
    Error
      (sdk_error
         (Execution_agent_scope.Resume_topology_mismatch
            "settled execution has no provider response authority"))
;;

let close_success (t : t) =
  match t.provider, t.turn with
  | None, Transient _ -> Ok ()
  | Some provider, Durable turn ->
    let* () =
      Execution_agent_scope.close_provider_attempt provider Execution_event.Succeeded
      |> Result.map_error sdk_error
    in
    Execution_agent_scope.close_turn turn Execution_event.Succeeded
    |> Result.map_error sdk_error
  | None, Durable _ | Some _, Transient _ ->
    Error (sdk_error Execution_agent_scope.Invocation_locator_mismatch)
;;

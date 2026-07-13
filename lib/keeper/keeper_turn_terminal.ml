(** Structured terminal-reason surface for keeper turn ledgers.

    RFC-0047 PR-3:
    - [code: string] field removed; [disposition] is the SSOT.
    - [severity_of_code / summary_of_code / next_action_of_code]
      substring classifiers deleted; severity / summary / next_action
      are now derived via exhaustive matches on
      [Keeper_turn_disposition.t].
    - [normalize_code] retained as a producer-side string preprocessor
      until producers are themselves typed (out of scope for this RFC). *)

type severity = Keeper_turn_disposition.severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

type t =
  { disposition : Keeper_turn_disposition.t
  ; source : string
  ; severity : severity
  ; summary : string
  ; next_action : string option
  }

let code t = Keeper_turn_disposition.to_wire t.disposition

let severity_to_string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Bad -> "bad"
  | Unknown_bad -> "bad"
;;

let make_from_disposition ?(source = "typed") ?summary ?next_action disposition =
  let summary =
    Option.value ~default:(Keeper_turn_disposition.summary disposition) summary
  in
  let next_action =
    match next_action with
    | Some _ as value -> value
    | None -> Keeper_turn_disposition.next_action disposition
  in
  { disposition
  ; source
  ; severity = Keeper_turn_disposition.severity disposition
  ; summary
  ; next_action
  }
;;

let make ?(source = "typed") ?summary ?next_action code =
  let disposition = Keeper_turn_disposition.of_wire code in
  make_from_disposition ~source ?summary ?next_action disposition
;;

let of_disposition ?source ?summary ?next_action disposition =
  let source = Option.value ~default:"typed" source in
  make_from_disposition ~source ?summary ?next_action disposition
;;

let success () = make ~source:"turn_result" "success"
(* WORKAROUND removed: [contract_code_from_error_text] was a substring
   classifier emitting one of two wire strings. It had zero callers
   (verified by rg, 2026-06-28) and was a textbook anti-pattern #2
   (string classifier where typed variant is possible). Removed in
   commit 3 of the keeper typed-reason series. *)

let of_failure ?(tool_call_count = 0) ~raw_error err =
  match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Provider_timeout _) ->
      of_disposition
        ~source:"typed_error"
        (Keeper_turn_disposition.Provider_error
           (Keeper_turn_terminal_code.Provider_runtime_error "provider_timeout"))
    | Some (Keeper_turn_driver.Capacity_backpressure _) ->
      make ~source:"typed_error" "capacity_backpressure"
    | Some (Keeper_turn_driver.Runtime_exhausted _) ->
      of_disposition
        ~source:"typed_error"
        Keeper_turn_disposition.Runtime_attempts_exhausted
    | Some (Keeper_turn_driver.Turn_timeout _) ->
      make ~source:"typed_error" "turn_wall_clock_timeout"
    | Some
        ( Keeper_turn_driver.Resumable_cli_session _
        | Keeper_turn_driver.Accept_rejected _
        | Keeper_turn_driver.Internal_unhandled_exception _
        | Keeper_turn_driver.Internal_bridge_exception _
        | Keeper_turn_driver.Internal_contract_rejected _
        | Keeper_turn_driver.Receipt_persistence_failed _ ) ->
      of_disposition
        ~source:"typed_error"
        (Keeper_turn_disposition.Provider_error
           (Keeper_agent_error.terminal_reason_code_of_sdk_error_typed err))
    | None ->
      (* The driver classifier returned None, meaning err is a generic
         [Agent_sdk.Error.t] not in the masc_internal_error family.
         Route through the typed bridge instead of catching [_ ->
         ...] silently (anti-pattern #2). The bridge matches every
         [Agent_sdk.Error.t] variant exhaustively. *)
      of_disposition
        ~source:"typed_error"
        (Keeper_turn_disposition.Provider_error
           (Keeper_agent_error.terminal_reason_code_of_sdk_error_typed err))
;;

let of_code ?source ?summary ?next_action code =
  let source =
    match source with
    | Some source -> source
    | None -> "wire_code"
  in
  make ~source ?summary ?next_action code
;;

let to_json reason =
  `Assoc
    [ "code", `String (code reason)
    ; "disposition", `String (Keeper_turn_disposition.to_wire reason.disposition)
    ; "source", `String reason.source
    ; "severity", `String (severity_to_string reason.severity)
    ; "summary", `String reason.summary
    ; ( "next_action", Json_util.string_opt_to_json reason.next_action )
    ]
;;

let string_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) when String.trim value <> "" -> Some value
     | _ -> None)
  | _ -> None
;;

let of_json json =
  let source = string_member "source" json |> Option.value ~default:"decision_log" in
  let summary = string_member "summary" json in
  let next_action = string_member "next_action" json in
  match string_member "disposition" json with
  | Some wire ->
    let disposition = Keeper_turn_disposition.of_wire wire in
    Some (of_disposition ~source ?summary ?next_action disposition)
  | None ->
    (match string_member "code" json with
     | Some code -> Some (of_code ~source ?summary ?next_action code)
     | None -> None)
;;

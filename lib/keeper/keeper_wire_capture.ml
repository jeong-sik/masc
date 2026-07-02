(** See [keeper_wire_capture.mli]. *)

let enabled () = Env_config_keeper.KeeperWireCapture.enabled ()

let redact = Llm_provider.Secret_redactor.redact_string

(* Dated per-day store, mirroring the cost-ledger appender
   ([Keeper_hooks_oas_cost_events.emit_cost_event]); concurrent keepers
   serialise on a per-day file rather than one global blob. *)
let wire_capture_dir masc_root = Filename.concat masc_root "wire-capture"

let write_payload ~masc_root (payload : Yojson.Safe.t) =
  let max_bytes = Env_config_keeper.KeeperWireCapture.max_bytes () in
  let store =
    Dated_jsonl.create
      ~base_dir:(wire_capture_dir masc_root)
      ~retention_days:(Env_config_keeper.KeeperWireCapture.retention_days ())
      ~max_bytes
      ()
  in
  if
    not
      (Dated_jsonl.append_if_current_file_fits
         store
         ~max_current_file_bytes:max_bytes
         payload)
  then
    Log.Keeper.warn
      "keeper_wire_capture: skipped record because current day file would exceed %d \
       bytes under %s"
      max_bytes
      (Dated_jsonl.base_dir store)

let best_effort ~masc_root f =
  let base_dir = wire_capture_dir masc_root in
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error "keeper_wire_capture: write failed to %s: %s" base_dir
      (Printexc.to_string exn)

let json_string_opt = function
  | Some value -> `String (redact value)
  | None -> `Null

let capture_request ~masc_root ~keeper_name ~turn_id ~sdk_turn ~system_prompt
    ~extra_system_context ~user_message ~history_messages =
  if not (enabled ()) then ()
  else
    best_effort ~masc_root (fun () ->
      let history =
        List.map
          (fun (m : Agent_sdk.Types.message) ->
             `Assoc
               [ ("role", `String (Agent_sdk.Types.role_to_string m.role))
               ; ("text", `String (redact (Agent_sdk.Types.text_of_message m)))
               ])
          history_messages
      in
      let payload : Yojson.Safe.t =
        `Assoc
          [ ("ts", `String (Masc_domain.now_iso ()))
          ; ("kind", `String "request")
          ; ("keeper", `String keeper_name)
          ; ("turn_id", `Int turn_id)
          ; ("sdk_turn", `Int sdk_turn)
          ; ("system_prompt", `String (redact system_prompt))
          ; ("extra_system_context", json_string_opt extra_system_context)
          ; ( "extra_system_context_present"
            , `Bool (Option.is_some extra_system_context) )
          ; ("user_message", `String (redact user_message))
          ; ("history_message_count", `Int (List.length history_messages))
          ; ("history", `List history)
          ]
      in
      write_payload ~masc_root payload)

let capture_response ~masc_root ~keeper_name ~turn_id ~response_text =
  if not (enabled ()) then ()
  else
    best_effort ~masc_root (fun () ->
      let payload : Yojson.Safe.t =
        `Assoc
          [ ("ts", `String (Masc_domain.now_iso ()))
          ; ("kind", `String "response")
          ; ("keeper", `String keeper_name)
          ; ("turn_id", `Int turn_id)
          ; ("response_text", `String (redact response_text))
          ]
      in
      write_payload ~masc_root payload)

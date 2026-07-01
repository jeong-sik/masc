(** See [keeper_wire_capture.mli]. *)

let env_flag = "MASC_KEEPER_WIRE_CAPTURE"

let enabled () =
  match Sys.getenv_opt env_flag with
  | Some v -> (
      match String.lowercase_ascii (String.trim v) with
      | "1" | "true" | "yes" | "on" -> true
      | _ -> false)
  | None -> false

let redact = Llm_provider.Secret_redactor.redact_string

(* Dated per-day store, mirroring the cost-ledger appender
   ([Keeper_hooks_oas_cost_events.emit_cost_event]); concurrent keepers
   serialise on a per-day file rather than one global blob. *)
let wire_capture_dir base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "wire-capture"

let capture_request ~base_path ~keeper_name ~turn_id ~system_prompt
    ~user_message ~history_messages =
  if not (enabled ()) then ()
  else
    let history =
      List.map
        (fun m ->
          `Assoc
            [ ("text", `String (redact (Agent_sdk.Types.text_of_message m))) ])
        history_messages
    in
    let payload : Yojson.Safe.t =
      `Assoc
        [
          ("ts", `String (Masc_domain.now_iso ()));
          ("keeper", `String keeper_name);
          ("turn_id", `Int turn_id);
          ("system_prompt", `String (redact system_prompt));
          ("user_message", `String (redact user_message));
          ("history_message_count", `Int (List.length history_messages));
          ("history", `List history);
        ]
    in
    let store = Dated_jsonl.create ~base_dir:(wire_capture_dir base_path) () in
    try Dated_jsonl.append store payload with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Keeper.error "keeper_wire_capture: write failed to %s: %s"
          (Dated_jsonl.base_dir store) (Printexc.to_string exn)

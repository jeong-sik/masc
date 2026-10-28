(** Private browser-worker requests. This is a host transport contract, not a
    Keeper tool. HTTP authentication and host caller admission precede decoding;
    an incarnation binds every request to one live worker. No decoder dispatches
    a browser operation or supplies a fallback route. *)
val command_tool_name : string
(** Fixed browser-worker command tool name, shared by the advertisement and the
    host's match of each browser service to its own export. Callers cannot
    select another export on that worker. *)
type command =
  | Snapshot
  | Retire
(** Private lifecycle control. Retires admission and waits for owned backend
    cleanup; never export through ordinary browser ingress or model tools. *)
  | Upload_stage of { id:string; actor:string; route:Browser_lane.route; verb:Browser_lane.verb }
  | Upload_discard of string
(** Private host-authorized file preparation only. A stage receipt grants no
    browser input; the ordinary exported command must consume the exact grant. *)
  | Download_claim of { id:string; actor:string; route:Browser_lane.route; verb:Browser_lane.verb }
  | Download_commit of { id:string; actor:string; route:Browser_lane.route; verb:Browser_lane.verb; receipt:Yojson.Safe.t }
  | Download_release of { id:string; actor:string; route:Browser_lane.route; verb:Browser_lane.verb }
(** Private artifact transfer. Settlement of an exact existing claim remains
    available during retirement; it cannot admit another browser command. *)
  | Model_requests
  | Model_result of Yojson.Safe.t
  | Model_wait of { after : string option }
(** Private host broker ports. The long wait ends on a request-set change or
    retirement, independently of a browser command waiting on its model. *)
  | Extension of Browser_extension_protocol.command
(** Private trusted companion execution. Programs, credentials and replies never
    enter model request queues or ordinary browser tools. *)
  | Poll of { client : Browser_lane.client_info; window_sec : float }
  | Deliver of { client_id : Browser_lane.client_id; id : string; payload : Yojson.Safe.t }
  | Disconnect of Browser_lane.client_id
  | Issue of {
      route : Browser_lane.route;
      verb : Browser_lane.verb;
      actor : string option;
      timeout_sec : float;
      only_if_idle : bool;
    }
type request = { incarnation : string; command : command }
val ends_with_caller : command -> bool
(** Only selected live requests whose host waiter may be cancelled on caller
    departure. This does not cancel or undo an already delivered browser effect. *)
val changes_nothing : command -> bool
(** The worker answers the command by reading its own state: a snapshot, a
    model listing or wait, or an idle document read, which the worker refuses
    as busy or times out by itself. A lost or cancelled reply therefore leaves
    no browser effect whose outcome is unknown; only its reader learns that it
    failed. *)
val to_json : request -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (request, string) result
val verb_of_json : route:Browser_lane.route -> Yojson.Safe.t -> (Browser_lane.verb, string) result
(** Decode every existing closed browser verb, retaining document, viewport,
    frame, navigation and native-input guards. Unknown and duplicate fields are
    refused. A route is explicit and remains unchanged. *)
val selection_error_to_json : Browser_lane.selection_error -> Yojson.Safe.t
val selection_error_of_json : Yojson.Safe.t -> (Browser_lane.selection_error, string) result
val answer_to_json : (Browser_lane.answer, Browser_lane.selection_error) result -> Yojson.Safe.t
val answer_of_json : Yojson.Safe.t -> ((Browser_lane.answer, Browser_lane.selection_error) result, string) result
val client_to_json : Browser_lane.client_info -> Yojson.Safe.t
(** Strict client identity and Space context. [space] must name the bound Space
    for an Ego transport and must be null for other transports. Space names are
    observations, not connection identity or operator-control authority. *)
val client_of_json : Yojson.Safe.t -> (Browser_lane.client_info, string) result

type disposition = Not_started | Outcome_unknown
type reply =
  | Snapshot_result of Yojson.Safe.t
  | Model_reply of Yojson.Safe.t
  | Extension_reply of Yojson.Safe.t
  | Download_reply of Browser_addon_downloads.claim
  | Poll_result of { command : Browser_lane.issued option; state_id : string }
  | Receipt
  | Issue_result of (Browser_lane.answer, Browser_lane.selection_error) result
  | Service_refusal of { message : string; disposition : disposition }
val reply_to_json : reply -> Yojson.Safe.t
val reply_of_json : Yojson.Safe.t -> (reply, string) result

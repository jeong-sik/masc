(** Private browser-worker requests. This is a host transport contract, not a
    Keeper tool. HTTP authentication and host caller admission precede decoding;
    an incarnation binds every request to one live worker. No decoder dispatches
    a browser operation or supplies a fallback route. *)
type command =
  | Snapshot
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
val client_of_json : Yojson.Safe.t -> (Browser_lane.client_info, string) result

type disposition = Not_started | Outcome_unknown
type reply =
  | Snapshot_result of Yojson.Safe.t
  | Poll_result of Browser_lane.issued option
  | Receipt
  | Issue_result of (Browser_lane.answer, Browser_lane.selection_error) result
  | Service_refusal of { message : string; disposition : disposition }
val reply_to_json : reply -> Yojson.Safe.t
val reply_of_json : Yojson.Safe.t -> (reply, string) result

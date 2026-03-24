(** Tool_notifications — MCP tools for in-turn event polling.

    Allows agents to check/consume notifications from their session queue
    without maintaining an SSE connection. Three tools:
    - masc_notification_count  — Lightweight count of pending notifications
    - masc_check_notifications — Peek at pending notifications (non-destructive)
    - masc_consume_notifications — Pop and return notifications (destructive)

    @since 2.70.0 *)

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_notification_count";
    description = "Check how many unread notifications are pending in your session queue. \
Lightweight call that returns only the count, useful for deciding whether to fetch full notifications. \
Costs nothing to call frequently.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_check_notifications";
    description = "Peek at pending notifications without consuming them. \
Returns up to `limit` notifications from your session queue. \
The notifications remain in the queue for later consumption. \
Use masc_consume_notifications to actually remove them after processing.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of notifications to return (default: 10)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_consume_notifications";
    description = "Pop and return pending notifications, removing them from the queue. \
Returns up to `limit` notifications. Once consumed, they cannot be retrieved again. \
Use masc_check_notifications first if you want to preview before consuming.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of notifications to consume (default: 10)");
        ]);
      ]);
    ];
  };
]

open Tool_args

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

type result = bool * string

let handle_notification_count (registry : Session.registry) ~agent_name : result =
  let count = Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent_name with
    | Some session -> List.length session.message_queue
    | None -> 0
  ) in
  (true, Yojson.Safe.to_string (`Assoc [("count", `Int count)]))

let handle_check_notifications (registry : Session.registry) ~agent_name args : result =
  let limit = max 0 (get_int args "limit" 10) in
  let notifications = Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent_name with
    | Some session ->
        let rec take n lst = match n, lst with
          | 0, _ | _, [] -> []
          | n, x :: rest -> x :: take (n - 1) rest
        in
        take limit session.message_queue
    | None -> []
  ) in
  let json = `Assoc [
    ("count", `Int (List.length notifications));
    ("notifications", `List notifications);
  ] in
  (true, Yojson.Safe.to_string json)

let handle_consume_notifications (registry : Session.registry) ~agent_name args : result =
  let limit = max 0 (get_int args "limit" 10) in
  (* Single lock block: compute consumed + remaining atomically to avoid TOCTOU *)
  let (consumed, remaining_count) = Session.with_lock registry (fun () ->
    match Hashtbl.find_opt registry.sessions agent_name with
    | Some session ->
        let rec split n lst = match n, lst with
          | 0, rest | _, ([] as rest) -> ([], rest)
          | n, x :: rest ->
              let (taken, remaining) = split (n - 1) rest in
              (x :: taken, remaining)
        in
        let (taken, remaining) = split limit session.message_queue in
        session.message_queue <- remaining;
        (taken, List.length remaining)
    | None -> ([], 0)
  ) in
  let json = `Assoc [
    ("consumed", `Int (List.length consumed));
    ("remaining", `Int remaining_count);
    ("notifications", `List consumed);
  ] in
  (true, Yojson.Safe.to_string json)

(** Dispatch tool call by name *)
let dispatch registry ~agent_name ~name args : result option =
  match name with
  | "masc_notification_count" ->
      Some (handle_notification_count registry ~agent_name)
  | "masc_check_notifications" ->
      Some (handle_check_notifications registry ~agent_name args)
  | "masc_consume_notifications" ->
      Some (handle_consume_notifications registry ~agent_name args)
  | _ -> None

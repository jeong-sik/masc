module Schema = Graphql.Schema
module Arg = Schema.Arg
module Workspace = Workspace
module Workspace_utils = Workspace_utils
module Types = Masc_domain
open Masc_domain

type ctx = {
  workspace_config: Workspace_utils.config;
}

type response_status = [ `OK | `Bad_request ]

type response = {
  status: response_status;
  body: string;
}

type page_info = {
  has_next_page: bool;
  end_cursor: string option;
}

type 'a edge = {
  node: 'a;
  cursor: string;
}

type 'a connection = {
  edges: 'a edge list;
  page_info: page_info;
  total_count: int;
  read_errors: string list;
}

type task_status_info = {
  status: string;
  assignee: string option;
  claimed_at: string option;
  started_at: string option;
  completed_at: string option;
  notes: string option;
  cancelled_by: string option;
  cancelled_at: string option;
  reason: string option;
}

let max_first = 200
let default_first = 50

let encode_cursor ~kind value =
  Base64.encode_string (kind ^ ":" ^ value)

type cursor_decode_error =
  | Cursor_base64_decode_error of { kind : string; message : string }
  | Cursor_kind_mismatch of { expected_kind : string }

let cursor_decode_error_to_string = function
  | Cursor_base64_decode_error { kind; message } ->
      Printf.sprintf "invalid %s cursor: base64 decode failed: %s" kind message
  | Cursor_kind_mismatch { expected_kind } ->
      Printf.sprintf
        "invalid %s cursor: decoded cursor kind did not match expected kind"
        expected_kind

let decode_cursor_result ~kind cursor =
  match Base64.decode cursor with
  | Ok decoded ->
      let prefix = kind ^ ":" in
      let prefix_len = String.length prefix in
      if String.starts_with decoded ~prefix then
        Ok (String.sub decoded prefix_len (String.length decoded - prefix_len))
      else
        Error (Cursor_kind_mismatch { expected_kind = kind })
  | Error (`Msg message) -> Error (Cursor_base64_decode_error { kind; message })

let decode_cursor ~kind cursor =
  match decode_cursor_result ~kind cursor with
  | Ok value -> Some value
  | Error err ->
      Log.Misc.warn "graphql cursor decode failed: %s"
        (cursor_decode_error_to_string err);
      None

let clamp_first = function
  | None -> default_first
  | Some n -> max 0 (min n max_first)

let rec take n items =
  match items with
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs

let drop_after_id id_of items after_id =
  match after_id with
  | None -> items
  | Some target ->
      let rec loop = function
        | [] -> []
        | x :: xs when String.equal (id_of x) target -> xs
        | _ :: xs -> loop xs
      in
      loop items

let decode_after_cursor ~kind after =
  match after with
  | None -> (None, [])
  | Some cursor -> (
      match decode_cursor_result ~kind cursor with
      | Ok value -> (Some value, [])
      | Error err -> (None, [ cursor_decode_error_to_string err ]))

let decode_message_after_cursor after =
  match decode_after_cursor ~kind:"message" after with
  | None, errors -> (None, errors)
  | Some raw_seq, [] -> (
      match int_of_string_opt raw_seq with
      | Some seq when seq >= 0 -> (Some seq, [])
      | Some _ ->
          ( None
          , [ "invalid message cursor: decoded sequence must be non-negative" ] )
      | None ->
          (None, [ "invalid message cursor: decoded value must be an integer" ])
      )
  | Some _, errors -> (None, errors)

let task_status_info_of_task (task : Masc_domain.task) =
  let status = Masc_domain.task_status_to_string task.task_status in
  match task.task_status with
  | Masc_domain.Todo ->
      {
        status;
        assignee = None;
        claimed_at = None;
        started_at = None;
        completed_at = None;
        notes = None;
        cancelled_by = None;
        cancelled_at = None;
        reason = None;
      }
  | Masc_domain.Claimed { assignee; claimed_at } ->
      {
        status;
        assignee = Some assignee;
        claimed_at = Some claimed_at;
        started_at = None;
        completed_at = None;
        notes = None;
        cancelled_by = None;
        cancelled_at = None;
        reason = None;
      }
  | Masc_domain.InProgress { assignee; started_at } ->
      {
        status;
        assignee = Some assignee;
        claimed_at = None;
        started_at = Some started_at;
        completed_at = None;
        notes = None;
        cancelled_by = None;
        cancelled_at = None;
        reason = None;
      }
  | Masc_domain.Done { assignee; completed_at; notes } ->
      {
        status;
        assignee = Some assignee;
        claimed_at = None;
        started_at = None;
        completed_at = Some completed_at;
        notes;
        cancelled_by = None;
        cancelled_at = None;
        reason = None;
      }
  | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
      {
        status;
        assignee = None;
        claimed_at = None;
        started_at = None;
        completed_at = None;
        notes = None;
        cancelled_by = Some cancelled_by;
        cancelled_at = Some cancelled_at;
        reason;
      }
  | Masc_domain.AwaitingVerification { assignee; submitted_at; _ } ->
      {
        status;
        assignee = Some assignee;
        claimed_at = None;
        started_at = Some submitted_at;
        completed_at = None;
        notes = None;
        cancelled_by = None;
        cancelled_at = None;
        reason = None;
      }

let page_info_typ =
  Schema.obj "PageInfo"
    ~fields:[
      Schema.field "hasNextPage"
        ~typ:(Schema.non_null Schema.bool)
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.has_next_page);
      Schema.field "endCursor"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.end_cursor);
    ]

let task_status_typ =
  Schema.obj "TaskStatus"
    ~fields:[
      Schema.field "status"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.status);
      Schema.field "assignee"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.assignee);
      Schema.field "claimedAt"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.claimed_at);
      Schema.field "startedAt"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.started_at);
      Schema.field "completedAt"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.completed_at);
      Schema.field "notes"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.notes);
      Schema.field "cancelledBy"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.cancelled_by);
      Schema.field "cancelledAt"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.cancelled_at);
      Schema.field "reason"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ info -> info.reason);
    ]

let task_typ =
  Schema.obj "Task"
    ~fields:[
      Schema.field "id"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> encode_cursor ~kind:"task" task.id);
      Schema.field "title"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task.title);
      Schema.field "description"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task.description);
      Schema.field "priority"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task.priority);
      Schema.field "files"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null Schema.string)))
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task.files);
      Schema.field "createdAt"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task.created_at);
      Schema.field "status"
        ~typ:(Schema.non_null task_status_typ)
        ~args:Arg.[]
        ~resolve:(fun _ (task : Masc_domain.task) -> task_status_info_of_task task);
    ]

let agent_meta_typ =
  Schema.obj "AgentMeta"
    ~fields:[
      Schema.field "sessionId"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.session_id);
      Schema.field "agentType"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.agent_type);
      Schema.field "pid"
        ~typ:Schema.int
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.pid);
      Schema.field "hostname"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.hostname);
      Schema.field "tty"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.tty);
      Schema.field "parentTask"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (meta : Masc_domain.agent_meta) -> meta.parent_task);
    ]

let agent_typ =
  Schema.obj "Agent"
    ~fields:[
      Schema.field "id"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> encode_cursor ~kind:"agent" agent.name);
      Schema.field "name"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.name);
      Schema.field "agentType"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.agent_type);
      Schema.field "status"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> Masc_domain.agent_status_to_string agent.status);
      Schema.field "capabilities"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null Schema.string)))
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.capabilities);
      Schema.field "currentTask"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.current_task);
      Schema.field "sessionBoundAt"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.session_bound_at);
      Schema.field "lastSeen"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.last_seen);
      Schema.field "meta"
        ~typ:agent_meta_typ
        ~args:Arg.[]
        ~resolve:(fun _ (agent : Masc_domain.agent) -> agent.meta);
    ]

let message_typ =
  Schema.obj "Message"
    ~fields:[
      Schema.field "id"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> encode_cursor ~kind:"message" (string_of_int message.seq));
      Schema.field "seq"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.seq);
      Schema.field "from"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.from_agent);
      Schema.field "messageType"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.msg_type);
      Schema.field "content"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.content);
      Schema.field "mention"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.mention);
      Schema.field "timestamp"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.timestamp);
      Schema.field "expiresAt"
        ~typ:Schema.float
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.expires_at);
      Schema.field "relevance"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (message : Masc_domain.message) -> message.relevance);
    ]

let read_errors_field () =
  Schema.field "readErrors"
    ~typ:(Schema.non_null (Schema.list (Schema.non_null Schema.string)))
    ~args:Arg.[]
    ~resolve:(fun _ conn -> conn.read_errors)

let workspace_state_typ =
  Schema.obj "WorkspaceState"
    ~fields:[
      Schema.field "protocolVersion"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.protocol_version);
      Schema.field "project"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.project);
      Schema.field "startedAt"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.started_at);
      Schema.field "messageSeq"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.message_seq);
      Schema.field "activeAgents"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null Schema.string)))
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.active_agents);
      Schema.field "paused"
        ~typ:(Schema.non_null Schema.bool)
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.paused);
      Schema.field "pauseReason"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.pause_reason);
      Schema.field "pausedBy"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.paused_by);
      Schema.field "pausedAt"
        ~typ:Schema.string
        ~args:Arg.[]
        ~resolve:(fun _ (state : Masc_domain.workspace_state) -> state.paused_at);
    ]

let task_edge_typ =
  Schema.obj "TaskEdge"
    ~fields:[
      Schema.field "node"
        ~typ:(Schema.non_null task_typ)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.node);
      Schema.field "cursor"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.cursor);
    ]

let agent_edge_typ =
  Schema.obj "AgentEdge"
    ~fields:[
      Schema.field "node"
        ~typ:(Schema.non_null agent_typ)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.node);
      Schema.field "cursor"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.cursor);
    ]

let message_edge_typ =
  Schema.obj "MessageEdge"
    ~fields:[
      Schema.field "node"
        ~typ:(Schema.non_null message_typ)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.node);
      Schema.field "cursor"
        ~typ:(Schema.non_null Schema.string)
        ~args:Arg.[]
        ~resolve:(fun _ edge -> edge.cursor);
    ]

let task_connection_typ =
  Schema.obj "TaskConnection"
    ~fields:[
      Schema.field "edges"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null task_edge_typ)))
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.edges);
      Schema.field "pageInfo"
        ~typ:(Schema.non_null page_info_typ)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.page_info);
      Schema.field "totalCount"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.total_count);
      read_errors_field ();
    ]

let agent_connection_typ =
  Schema.obj "AgentConnection"
    ~fields:[
      Schema.field "edges"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null agent_edge_typ)))
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.edges);
      Schema.field "pageInfo"
        ~typ:(Schema.non_null page_info_typ)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.page_info);
      Schema.field "totalCount"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.total_count);
      read_errors_field ();
    ]

let message_connection_typ =
  Schema.obj "MessageConnection"
    ~fields:[
      Schema.field "edges"
        ~typ:(Schema.non_null (Schema.list (Schema.non_null message_edge_typ)))
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.edges);
      Schema.field "pageInfo"
        ~typ:(Schema.non_null page_info_typ)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.page_info);
      Schema.field "totalCount"
        ~typ:(Schema.non_null Schema.int)
        ~args:Arg.[]
        ~resolve:(fun _ conn -> conn.total_count);
      read_errors_field ();
    ]

let graphql_error message =
  Yojson.Basic.to_string
    (`Assoc [("errors", `List [`Assoc [("message", `String message)]])])

let rec const_value_of_yojson = function
  | `Null -> (`Null : Graphql_parser.const_value)
  | `Bool b -> `Bool b
  | `Int i -> `Int i
  | `Intlit s ->
      (match int_of_string_opt s with
       | Some i -> `Int i
       | None -> `String s)
  | `Float f -> `Float f
  | `Floatlit s ->
      (match float_of_string_opt s with
       | Some f -> `Float f
       | None -> `String s)
  | `String s -> `String s
  | `Assoc fields ->
      `Assoc (List.map (fun (k, v) -> (k, const_value_of_yojson v)) fields)
  | `List items ->
      `List (List.map const_value_of_yojson items)
  | `Tuple items ->
      `List (List.map const_value_of_yojson items)
  | `Variant (name, None) ->
      `Enum name
  | `Variant (name, Some value) ->
      `Assoc [("type", `Enum name); ("value", const_value_of_yojson value)]

let variables_of_yojson = function
  | None -> []
  | Some (`Null) -> []
  | Some (`Assoc fields) ->
      List.map (fun (k, v) -> (k, const_value_of_yojson v)) fields
  | Some _ -> []

let get_agents config : Masc_domain.agent list * string list =
  let dir = Workspace_utils.agents_dir config in
  match Workspace_utils.list_dir_result config dir with
  | Error err -> ([], [err])
  | Ok names ->
      let agents, errors =
        names
        |> List.filter (fun name -> Filename.check_suffix name ".json")
        |> List.sort String.compare
        |> List.fold_left
             (fun (agents, errors) name ->
                let path = Filename.concat dir name in
                match Workspace_utils.read_json_result config path with
                | Error err -> (agents, err :: errors)
                | Ok json ->
                    (match Masc_domain.agent_of_yojson json with
                     | Ok agent -> (agent :: agents, errors)
                     | Error err ->
                         ( agents
                         , Printf.sprintf "invalid agent file %s: %s" path err :: errors )))
             ([], [])
      in
      ( List.sort
          (fun (a : Masc_domain.agent) (b : Masc_domain.agent) ->
             String.compare a.name b.name)
          agents
      , List.rev errors )

let get_messages config : Masc_domain.message list * string list =
  let dir = Workspace_utils.messages_dir config in
  match Workspace_utils.list_dir_result config dir with
  | Error err -> ([], [err])
  | Ok names ->
      let messages, errors =
        names
        |> List.filter Workspace.is_valid_filename
        |> List.filter (fun name -> Filename.check_suffix name ".json")
        |> List.sort String.compare
        |> List.fold_left
             (fun (messages, errors) name ->
                let path = Filename.concat dir name in
                match Workspace_utils.read_json_result config path with
                | Error err -> (messages, err :: errors)
                | Ok json ->
                    (match Masc_domain.message_of_yojson json with
                     | Ok msg -> (msg :: messages, errors)
                     | Error err ->
                         ( messages
                         , Printf.sprintf "invalid message file %s: %s" path err :: errors )))
             ([], [])
      in
      ( List.sort
          (fun (a : Masc_domain.message) (b : Masc_domain.message) ->
             compare a.seq b.seq)
          messages
      , List.rev errors )

let tasks_connection config first after =
  let tasks : Masc_domain.task list =
    if Workspace_utils.is_initialized config then
      Workspace.get_tasks_raw config
    else
      []
  in
  let after_id, cursor_read_errors = decode_after_cursor ~kind:"task" after in
  let cursor_of (task : Masc_domain.task) = encode_cursor ~kind:"task" task.id in
  let items_after = drop_after_id (fun (t : Masc_domain.task) -> t.id) tasks after_id in
  let first = clamp_first first in
  let page_items = take first items_after in
  let edges = List.map (fun node -> { node; cursor = cursor_of node }) page_items in
  let has_next_page = List.length items_after > List.length page_items in
  let end_cursor =
    match List.rev edges with
    | [] -> None
    | edge :: _ -> Some edge.cursor
  in
  {
    edges;
    page_info = { has_next_page; end_cursor };
    total_count = List.length tasks;
    read_errors = cursor_read_errors;
  }

let agents_connection config first after =
  let agents, read_errors =
    if Workspace_utils.is_initialized config then
      get_agents config
    else
      ([], [])
  in
  let after_id, cursor_read_errors = decode_after_cursor ~kind:"agent" after in
  let cursor_of (agent : Masc_domain.agent) = encode_cursor ~kind:"agent" agent.name in
  let items_after = drop_after_id (fun (a : Masc_domain.agent) -> a.name) agents after_id in
  let first = clamp_first first in
  let page_items = take first items_after in
  let edges = List.map (fun node -> { node; cursor = cursor_of node }) page_items in
  let has_next_page = List.length items_after > List.length page_items in
  let end_cursor =
    match List.rev edges with
    | [] -> None
    | edge :: _ -> Some edge.cursor
  in
  {
    edges;
    page_info = { has_next_page; end_cursor };
    total_count = List.length agents;
    read_errors = read_errors @ cursor_read_errors;
  }

let messages_connection config first after =
  let messages, read_errors =
    if Workspace_utils.is_initialized config then
      get_messages config
    else
      ([], [])
  in
  let after_seq, cursor_read_errors = decode_message_after_cursor after in
  let messages_after =
    match after_seq with
    | None -> messages
    | Some seq -> List.filter (fun msg -> msg.seq > seq) messages
  in
  let first = clamp_first first in
  let page_items = take first messages_after in
  let edges =
    List.map (fun node ->
      { node; cursor = encode_cursor ~kind:"message" (string_of_int node.seq) })
      page_items
  in
  let has_next_page = List.length messages_after > List.length page_items in
  let end_cursor =
    match List.rev edges with
    | [] -> None
    | edge :: _ -> Some edge.cursor
  in
  {
    edges;
    page_info = { has_next_page; end_cursor };
    total_count = List.length messages;
    read_errors = read_errors @ cursor_read_errors;
  }

let schema =
  Schema.schema [
    Schema.field "status"
      ~typ:(Schema.non_null workspace_state_typ)
      ~args:Arg.[]
      ~resolve:(fun info () -> Workspace.read_state info.ctx.workspace_config);
    Schema.field "tasks"
      ~typ:(Schema.non_null task_connection_typ)
      ~args:Arg.[
        Arg.arg "first" ~typ:Arg.int;
        Arg.arg "after" ~typ:Arg.string;
      ]
      ~resolve:(fun info () first after ->
        tasks_connection info.ctx.workspace_config first after);
    Schema.field "agents"
      ~typ:(Schema.non_null agent_connection_typ)
      ~args:Arg.[
        Arg.arg "first" ~typ:Arg.int;
        Arg.arg "after" ~typ:Arg.string;
      ]
      ~resolve:(fun info () first after ->
        agents_connection info.ctx.workspace_config first after);
    Schema.field "messages"
      ~typ:(Schema.non_null message_connection_typ)
      ~args:Arg.[
        Arg.arg "first" ~typ:Arg.int;
        Arg.arg "after" ~typ:Arg.string;
      ]
      ~resolve:(fun info () first after ->
        messages_connection info.ctx.workspace_config first after);
  ]

let handle_request ~config body_str =
  let json = Safe_ops.parse_json_safe ~context:"graphql" body_str in
  match json with
  | Error msg ->
      { status = `Bad_request; body = graphql_error msg }
  | Ok payload ->
      let query = Json_util.get_string payload "query" in
      let variables_json =
        match Json_util.assoc_member_opt "variables" payload with
        | Some `Null -> None
        | opt -> opt
      in
      let operation_name = Json_util.get_string payload "operationName" in
      (match query with
       | None ->
           { status = `Bad_request; body = graphql_error "Missing query field" }
       | Some query_str ->
           match Graphql_parser.parse query_str with
           | Error err ->
               { status = `Bad_request; body = graphql_error err }
           | Ok doc ->
               let variables = variables_of_yojson variables_json in
               let ctx = { workspace_config = config } in
               let result =
                 if variables = [] then
                   Schema.execute schema ctx ?operation_name doc
                 else
                   Schema.execute schema ctx ~variables ?operation_name doc
               in
               match result with
               | Ok (`Response json) ->
                   { status = `OK; body = Yojson.Basic.to_string json }
               | Ok (`Stream _) ->
                   { status = `Bad_request; body = graphql_error "Subscriptions are not supported" }
               | Error err_json ->
                   { status = `OK; body = Yojson.Basic.to_string err_json })

(** Neo4j Client for MASC - Native Bolt Protocol via neo4j_bolt_eio

    Provides connection management and query execution using the native
    OCaml Neo4j Bolt driver. Replaces shell-based query execution.

    Features:
    - Connection pooling (single connection reuse)
    - Automatic reconnection on failure
    - JSON result conversion
    - Error handling with Result types

    Environment variables:
    - NEO4J_URI: Connection URI (e.g., bolt://host:7687)
    - NEO4J_USERNAME: Username (default: neo4j)
    - NEO4J_PASSWORD: Password

    @since 0.6.0 - MASC Social v4 Tier 2
*)

module Bolt = Neo4j_bolt_eio.Bolt

(** {1 Types} *)

type error =
  | ConnectionError of string
  | QueryError of string
  | Timeout
  | NotConnected

let error_to_string = function
  | ConnectionError msg -> Printf.sprintf "Neo4j connection error: %s" msg
  | QueryError msg -> Printf.sprintf "Neo4j query error: %s" msg
  | Timeout -> "Neo4j request timeout"
  | NotConnected -> "Not connected to Neo4j"

(** {1 Global Connection State} *)

type connection_state = {
  mutable conn: Bolt.socket_connection option;
  mutable last_used: float;
  mutable connect_attempts: int;
  mutex: Mutex.t;
}

let global_state = {
  conn = None;
  last_used = 0.0;
  connect_attempts = 0;
  mutex = Mutex.create ();
}

(** Connection idle timeout (seconds) - reconnect if idle longer *)
let idle_timeout = 300.0  (* 5 minutes *)

(** Max consecutive connection failures before backing off *)
let max_connect_failures = 3

(** {1 Configuration} *)

let get_config () =
  let uri = Sys.getenv_opt "NEO4J_URI"
    |> Option.value ~default:"bolt://turntable.proxy.rlwy.net:11490" in
  let username = Sys.getenv_opt "NEO4J_USERNAME"
    |> Option.value ~default:"neo4j" in
  let password = Sys.getenv_opt "NEO4J_PASSWORD"
    |> Option.value ~default:"" in
  Bolt.config_from_uri ~username ~password ~timeout_s:30.0 uri

(** {1 Connection Management} *)

(** Check if connection is still valid *)
let is_connection_valid () =
  match global_state.conn with
  | None -> false
  | Some _ ->
      let now = Unix.gettimeofday () in
      let idle_time = now -. global_state.last_used in
      idle_time < idle_timeout

(** Get or create connection (thread-safe) *)
let get_connection ~sw ~net ~clock () =
  Mutex.lock global_state.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock global_state.mutex) (fun () ->
    (* Check if existing connection is valid *)
    if is_connection_valid () then begin
      global_state.last_used <- Unix.gettimeofday ();
      match global_state.conn with
      | Some c -> Ok c
      | None -> Error NotConnected
    end else begin
      (* Close stale connection if exists *)
      (match global_state.conn with
       | Some c ->
           (try Bolt.close c with _ -> ());
           global_state.conn <- None
       | None -> ());

      (* Check backoff for repeated failures *)
      if global_state.connect_attempts >= max_connect_failures then begin
        global_state.connect_attempts <- 0;  (* Reset after backoff *)
        Error (ConnectionError "Too many connection failures, backing off")
      end else begin
        (* Attempt new connection *)
        let config = get_config () in
        match Bolt.connect ~sw ~net ~clock ~config () with
        | Ok c ->
            global_state.conn <- Some c;
            global_state.last_used <- Unix.gettimeofday ();
            global_state.connect_attempts <- 0;
            Log.Session.info "[Neo4j] Connected: %s" (Bolt.connection_info c);
            Ok c
        | Error e ->
            global_state.connect_attempts <- global_state.connect_attempts + 1;
            Log.Session.warn "[Neo4j] Connection failed (%d/%d): %s"
              global_state.connect_attempts max_connect_failures
              (Bolt.error_to_string e);
            Error (ConnectionError (Bolt.error_to_string e))
      end
    end
  )

(** Close global connection *)
let close_connection () =
  Mutex.lock global_state.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock global_state.mutex) (fun () ->
    match global_state.conn with
    | Some c ->
        (try Bolt.close c with _ -> ());
        global_state.conn <- None;
        Log.Session.info "[Neo4j] Connection closed"
    | None -> ()
  )

(** Reset connection (force reconnect on next use) *)
let reset_connection () =
  Mutex.lock global_state.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock global_state.mutex) (fun () ->
    match global_state.conn with
    | Some c ->
        (try Bolt.close c with _ -> ());
        global_state.conn <- None;
        global_state.connect_attempts <- 0
    | None -> ()
  )

(** {1 Query Execution} *)

(** Convert Bolt error to our error type *)
let convert_error = function
  | Bolt.ConnectionError msg -> ConnectionError msg
  | Bolt.HandshakeError msg -> ConnectionError msg
  | Bolt.AuthError msg -> ConnectionError ("Auth: " ^ msg)
  | Bolt.ProtocolError (code, msg) -> QueryError (Printf.sprintf "[%s] %s" code msg)
  | Bolt.Timeout -> Timeout

(** Execute a Cypher query and return JSON result *)
let query ~sw ~net ~clock ~cypher ?(params=`Assoc []) ()
    : (Yojson.Safe.t, error) result =
  match get_connection ~sw ~net ~clock () with
  | Error e -> Error e
  | Ok conn ->
      match Bolt.query ~clock conn ~cypher ~params () with
      | Ok json ->
          global_state.last_used <- Unix.gettimeofday ();
          Ok (json :> Yojson.Safe.t)
      | Error e ->
          (* Reset connection on protocol errors *)
          (match e with
           | Bolt.ProtocolError _ | Bolt.ConnectionError _ ->
               reset_connection ()
           | _ -> ());
          Error (convert_error e)

(** {1 Convenience Functions} *)

(** Test connection *)
let test_connection ~sw ~net ~clock () =
  match get_connection ~sw ~net ~clock () with
  | Error e -> Error e
  | Ok conn ->
      match Bolt.test_connection ~clock conn with
      | Ok true -> Ok true
      | Ok false -> Error (QueryError "Connection test returned false")
      | Error e -> Error (convert_error e)

(** Count nodes with a label *)
let count_nodes ~sw ~net ~clock ~label () =
  match get_connection ~sw ~net ~clock () with
  | Error e -> Error e
  | Ok conn ->
      match Bolt.count_nodes ~clock conn ~label with
      | Ok count -> Ok count
      | Error e -> Error (convert_error e)

(** {1 High-Level Query Helpers} *)

(** Execute query and extract first record as JSON *)
let query_single ~sw ~net ~clock ~cypher ?(params=`Assoc []) () =
  match query ~sw ~net ~clock ~cypher ~params () with
  | Error e -> Error e
  | Ok json ->
      let open Yojson.Safe.Util in
      try
        let records = json |> member "records" |> to_list in
        match records with
        | [] -> Ok `Null
        | first :: _ -> Ok first
      with _ -> Ok `Null

(** Execute query and check if any results exist *)
let query_exists ~sw ~net ~clock ~cypher ?(params=`Assoc []) () =
  match query ~sw ~net ~clock ~cypher ~params () with
  | Error e -> Error e
  | Ok json ->
      let open Yojson.Safe.Util in
      try
        let records = json |> member "records" |> to_list in
        Ok (List.length records > 0)
      with _ -> Ok false

(** Execute query and extract count from first field *)
let query_count ~sw ~net ~clock ~cypher ?(params=`Assoc []) () =
  match query ~sw ~net ~clock ~cypher ~params () with
  | Error e -> Error e
  | Ok json ->
      let open Yojson.Safe.Util in
      try
        let records = json |> member "records" |> to_list in
        match records with
        | [] -> Ok 0
        | first :: _ ->
            (match first with
             | `List [`Int n] -> Ok n
             | `List [`List [`Int n]] -> Ok n
             | _ -> Ok 0)
      with _ -> Ok 0

(** {1 Statistics} *)

type stats = {
  connected: bool;
  last_used: float;
  connect_attempts: int;
  connection_info: string option;
}

let get_stats () =
  Mutex.lock global_state.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock global_state.mutex) (fun () ->
    {
      connected = Option.is_some global_state.conn;
      last_used = global_state.last_used;
      connect_attempts = global_state.connect_attempts;
      connection_info = Option.map Bolt.connection_info global_state.conn;
    }
  )

let stats_to_json stats =
  `Assoc [
    ("connected", `Bool stats.connected);
    ("last_used", `Float stats.last_used);
    ("connect_attempts", `Int stats.connect_attempts);
    ("connection_info", match stats.connection_info with
      | Some s -> `String s
      | None -> `Null);
  ]

(** Neo4j Bolt Native Client (Eio-based)

    Provides a thin wrapper around neo4j_bolt_eio with:
    - Connection pooling (single connection reuse)
    - Idle timeout (300s)
    - Thread-safe Yojson result conversion
*)

module Bolt = Neo4j_bolt_eio.Bolt

type error =
  | Connection_failed of string
  | Query_failed of string
  | Timeout
  | Disconnected

let string_of_error = function
  | Connection_failed s -> Printf.sprintf "Connection failed: %s" s
  | Query_failed s -> Printf.sprintf "Query failed: %s" s
  | Timeout -> "Connection timeout"
  | Disconnected -> "Disconnected from Neo4j"

(** Connection state - existentially typed to hide polymorphic connection *)
type connection_box = Box : _ Bolt.connection -> connection_box

type connection_state = {
  mutable conn: connection_box option;
  mutable last_used: float;
  mutex: Eio.Mutex.t;
}

let global_state = {
  conn = None;
  last_used = 0.0;
  mutex = Eio.Mutex.create ();
}

(** Configuration *)
let idle_timeout_sec = 300.0

(** Get Neo4j URI from environment *)
let get_neo4j_uri () =
  match Sys.getenv_opt "NEO4J_URI" with
  | Some uri -> uri
  | None -> "bolt://localhost:7687"

let get_neo4j_user () =
  Sys.getenv_opt "NEO4J_USER" |> Option.value ~default:"neo4j"

(** Get Neo4j password from environment.
    Returns Error if NEO4J_PASSWORD is unset or empty.
    Fail-fast: no silent fallback to a dummy password. *)
let get_neo4j_password () : (string, string) result =
  match Sys.getenv_opt "NEO4J_PASSWORD" with
  | Some pw when String.trim pw <> "" -> Ok pw
  | Some _ -> Error "NEO4J_PASSWORD is set but empty"
  | None -> Error "NEO4J_PASSWORD environment variable not set"

(** Close existing connection if any *)
let close_connection () =
  match global_state.conn with
  | Some (Box conn) ->
      (try Bolt.close conn with exn ->
        Log.Misc.error "[neo4j] close failed: %s" (Printexc.to_string exn));
      global_state.conn <- None
  | None -> ()

(** Convert Bolt error to our error type *)
let convert_error (e : Bolt.error) : error =
  match e with
  | Bolt.ConnectionError s -> Connection_failed s
  | Bolt.HandshakeError s -> Connection_failed s
  | Bolt.AuthError s -> Connection_failed s
  | Bolt.ProtocolError (code, msg) -> Query_failed (Printf.sprintf "[%s] %s" code msg)
  | Bolt.Timeout -> Timeout

(** Get or create connection *)
let get_connection ~sw ~net ~clock () =
  Eio.Mutex.use_rw global_state.mutex ~protect:true (fun () ->
    let now = Eio.Time.now clock in
    (* Check if existing connection is still valid *)
    match global_state.conn with
    | Some (Box _conn) when now -. global_state.last_used < idle_timeout_sec ->
        Ok ()
    | Some _ ->
        (* Connection timed out, close and reconnect *)
        close_connection ();
        let uri = get_neo4j_uri () in
        let user = get_neo4j_user () in
        (match get_neo4j_password () with
         | Error msg -> Error (Connection_failed msg)
         | Ok password ->
        (match Bolt.connect_uri ~sw ~net ~clock ~uri ~username:user ~password () with
         | Ok conn ->
             global_state.conn <- Some (Box conn);
             global_state.last_used <- now;
             Ok ()
         | Error e ->
             Error (convert_error e)))
    | None ->
        (* No connection, create new *)
        let uri = get_neo4j_uri () in
        let user = get_neo4j_user () in
        (match get_neo4j_password () with
         | Error msg -> Error (Connection_failed msg)
         | Ok password ->
        (match Bolt.connect_uri ~sw ~net ~clock ~uri ~username:user ~password () with
         | Ok conn ->
             global_state.conn <- Some (Box conn);
             global_state.last_used <- now;
             Ok ()
         | Error e ->
             Error (convert_error e)))
  )

(** Execute a Cypher query and return JSON result *)
let query ~sw ~net ~clock ~cypher ?(params=`Assoc []) ()
    : (Yojson.Safe.t, error) result =
  match get_connection ~sw ~net ~clock () with
  | Error e -> Error e
  | Ok () ->
      match global_state.conn with
      | None -> Error Disconnected
      | Some (Box conn) ->
          match Bolt.query ~clock conn ~cypher ~params () with
          | Ok json ->
              global_state.last_used <- Eio.Time.now clock;
              Ok json
          | Error e ->
              (* On query error, close connection for next retry *)
              close_connection ();
              Error (convert_error e)

(** Execute a write query (CREATE, MERGE, SET, DELETE) *)
let execute ~sw ~net ~clock ~cypher ?(params=`Assoc []) ()
    : (unit, error) result =
  match query ~sw ~net ~clock ~cypher ~params () with
  | Ok _ -> Ok ()
  | Error e -> Error e

(** Check if connection is available *)
let is_connected () =
  match global_state.conn with
  | Some _ -> true
  | None -> false

(** Force disconnect *)
let disconnect () =
  Eio.Mutex.use_rw global_state.mutex ~protect:true (fun () ->
    close_connection ()
  )

(** Get connection stats *)
let stats () =
  let now = Time_compat.now () in
  `Assoc [
    ("connected", `Bool (is_connected ()));
    ("idle_seconds", `Float (if is_connected () then now -. global_state.last_used else 0.0));
    ("idle_timeout", `Float idle_timeout_sec);
  ]

(** LSP Message Router — route JSON-RPC messages between WebSocket clients
    and LSP server processes.

    Maintains ID mapping between client request IDs and server-side sequential
    IDs, and resolves [Eio.Promise.t] values when responses arrive. *)

type pending_request =
  { client_id : int
  ; method_ : string
  ; promise : (Yojson.Safe.t, string) result Eio.Promise.t
  ; resolver : (Yojson.Safe.t, string) result Eio.Promise.u
  }

type t =
  { next_server_id : int Atomic.t
  ; pending : (int, pending_request) Hashtbl.t
  ; mutex : Eio.Mutex.t
    (** Guards [pending]. [send_request], [resolve_pending], and [reject_all]
        may run on different Eio fibers, so every access to the hash table must
        be serialized. *)
  }

let create () : t =
  { next_server_id = Atomic.make 1
  ; pending = Hashtbl.create 16
  ; mutex = Eio.Mutex.create ()
  }
;;

(** Allocate a fresh server-side JSON-RPC ID. *)
let alloc_server_id (router : t) : int =
  Atomic.fetch_and_add router.next_server_id 1
;;

(** Build a JSON-RPC request object. *)
let build_request (id : int) (method_ : string) (params : Yojson.Safe.t) =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", `Int id
    ; "method", `String method_
    ; "params", params
    ]
;;

(** Build a JSON-RPC notification (no ID). *)
let build_notification (method_ : string) (params : Yojson.Safe.t) =
  `Assoc [ "jsonrpc", `String "2.0"; "method", `String method_; "params", params ]
;;

(** Send a JSON-RPC request to the LSP server process.
    Returns a [Promise.t] that resolves when the response arrives. *)
let send_request
      (router : t)
      (proc : Lsp_process_manager.lsp_process)
      ~method_
      ~params
      ~(client_id : int)
  : (Yojson.Safe.t, string) result Eio.Promise.t
  =
  let server_id = alloc_server_id router in
  let request_json = build_request server_id method_ params in
  let payload = Yojson.Safe.to_string request_json in
  let promise, resolver = Eio.Promise.create () in
  Eio.Mutex.use_rw ~protect:true router.mutex @@ fun () ->
  Hashtbl.add router.pending server_id { client_id; method_; promise; resolver };
  Lsp_process_manager.write_message proc payload;
  promise
;;

(** Send a JSON-RPC notification to the LSP server process.
    Notifications have no ID and expect no response. *)
let send_notification
      (router : t)
      (proc : Lsp_process_manager.lsp_process)
      ~method_
      ~params
  =
  let notif_json = build_notification method_ params in
  let payload = Yojson.Safe.to_string notif_json in
  Lsp_process_manager.write_message proc payload
;;

(** Resolve a pending request by server ID. *)
let resolve_pending
      (router : t)
      (server_id : int)
      (result : (Yojson.Safe.t, string) result)
  =
  Eio.Mutex.use_rw ~protect:true router.mutex @@ fun () ->
  match Hashtbl.find_opt router.pending server_id with
  | Some req ->
    Hashtbl.remove router.pending server_id;
    Eio.Promise.resolve req.resolver result
  | None -> Log.Server.warn "LSP router: response for unknown server_id %d" server_id
;;

(** Reject all pending requests with an error.
    Used when the LSP process crashes or the connection closes. *)
let reject_all (router : t) (reason : string) =
  Eio.Mutex.use_rw ~protect:true router.mutex @@ fun () ->
  Hashtbl.iter
    (fun server_id req ->
       Eio.Promise.resolve req.resolver (Error reason);
       Log.Server.debug
         "LSP router: rejecting pending %s (server_id=%d, client_id=%d)"
         req.method_
         server_id
         req.client_id)
    router.pending;
  Hashtbl.clear router.pending
;;

(** Parse a JSON-RPC response, extracting [id] and [result]/[error]. *)
let parse_response (json : Yojson.Safe.t) : (int * (Yojson.Safe.t, string) result) option =
  try
    let obj =
      match json with
      | `Assoc m -> m
      | _ -> raise Exit
    in
    let id =
      match List.assoc_opt "id" obj with
      | Some (`Int n) -> n
      | _ -> raise Exit
    in
    let result =
      match List.assoc_opt "result" obj with
      | Some v -> Ok v
      | None ->
        (match List.assoc_opt "error" obj with
         | Some (`Assoc err_fields) ->
           let msg =
             match List.assoc_opt "message" err_fields with
             | Some (`String s) -> s
             | _ -> "unknown LSP error"
           in
           Error (Printf.sprintf "LSP error for request %d: %s" id msg)
         | Some _ -> Error (Printf.sprintf "LSP error for request %d" id)
         | None -> Error (Printf.sprintf "LSP response missing result/error for %d" id))
    in
    Some (id, result)
  with
  | Exit -> None
;;

(** Parse a JSON-RPC notification from the server. *)
let parse_notification (json : Yojson.Safe.t) : (string * Yojson.Safe.t) option =
  try
    let obj =
      match json with
      | `Assoc m -> m
      | _ -> raise Exit
    in
    match List.assoc_opt "id" obj with
    | Some _ -> None (* has an ID, not a notification *)
    | None ->
      (match List.assoc_opt "method" obj with
       | Some (`String m) ->
         let params =
           match List.assoc_opt "params" obj with
           | Some p -> p
           | None -> `Null
         in
         Some (m, params)
       | _ -> None)
  with
  | Exit -> None
;;

(** Start a fiber that reads responses from the LSP process stdout,
    resolves pending request promises, and forwards notifications. *)
let start_response_reader
      ~sw
      (router : t)
      (proc : Lsp_process_manager.lsp_process)
      ?on_exit
      ~(on_notification : client_id:int -> method_:string -> Yojson.Safe.t -> unit)
  =
  let fiber_promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
      try
        while true do
          let raw = Lsp_process_manager.read_message proc.stdout_r in
          let json = Yojson.Safe.from_string raw in
          match parse_response json with
          | Some (server_id, result) -> resolve_pending router server_id result
          | None ->
            (match parse_notification json with
             | Some (method_, params) -> on_notification ~client_id:(-1) ~method_ params
             | None ->
               Log.Server.warn "LSP router: unparseable message from %s" proc.lang_id)
        done
      with
      | exn ->
        let reason = Printexc.to_string exn in
        Log.Server.debug
          "LSP router: response reader for %s ended: %s"
          proc.lang_id
          reason;
        reject_all
          router
          (Printf.sprintf "LSP process %s disconnected: %s" proc.lang_id reason);
        Option.iter (fun f -> f ~reason) on_exit)
  in
  Eio.Fiber.fork ~sw (fun () ->
    match Eio.Promise.await fiber_promise with
    | Ok () -> ()
    | Error exn ->
      Log.Server.warn
        "LSP router: response reader for %s crashed: %s"
        proc.lang_id
        (Printexc.to_string exn))
;;

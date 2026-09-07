type source =
  | Builtin
  | Attached of
      { provider_id : string
      ; endpoint : string
      ; remote_name : string
      }

type surface_entry =
  { source : source
  ; schema : Agent_core.Types.tool_schema
  }

type error =
  | Invalid_snapshot of string
  | Work_scope_unavailable of string

let error_to_string = function
  | Invalid_snapshot detail -> "invalid outstanding tool-load receipts: " ^ detail
  | Work_scope_unavailable detail -> "tool load could not read its current work scope: " ^ detail
;;

module Names = Map.Make (String)

type load =
  { tool_use_id : string
  ; turn : int
  ; planned_index : int
  }

type scope =
  { trace_id : Keeper_id.Trace_id.t
  ; task_id : Keeper_id.Task_id.t option
  ; surface_sha256 : Digestif.SHA256.t
  }

type snapshot =
  { scope : scope
  ; pending : load Names.t
  }

type restored =
  { context : Agent_core.Context.t
  ; snapshot : snapshot option
  }

type lock =
  | Sync of Mutex.t
  | Async of Eio.Mutex.t

type t =
  { context : Agent_core.Context.t
  ; lock : lock
  ; current_task_id : unit -> (Keeper_id.Task_id.t option, string) result
  ; mutable snapshot : snapshot
  }

let context_key = "keeper_tool_load_receipts"
let ( let* ) = Result.bind

let exact_fields expected = function
  | `Assoc fields as json ->
    let names = List.map fst fields |> List.sort String.compare in
    if names = List.sort String.compare expected
    then Ok json
    else Error "missing, duplicate, or unexpected fields"
  | _ -> Error "expected an object"
;;

let nonempty_string json name =
  let* value = Json_util.require_string json name in
  if String.trim value = "" then Error (name ^ " must not be blank") else Ok value
;;

let nonnegative_int json name =
  let* value = Json_field.int json name |> Json_field.require in
  if value < 0 then Error (name ^ " must be nonnegative") else Ok value
;;

let decode_load json =
  let* json = exact_fields [ "name"; "tool_use_id"; "turn"; "planned_index" ] json in
  let* name = nonempty_string json "name" in
  let* tool_use_id = nonempty_string json "tool_use_id" in
  let* turn = nonnegative_int json "turn" in
  let* planned_index = nonnegative_int json "planned_index" in
  Ok (name, { tool_use_id; turn; planned_index })
;;

let decode_snapshot json =
  let* json = exact_fields [ "trace_id"; "task_id"; "surface_sha256"; "pending" ] json in
  let* trace_id = Json_util.require_string json "trace_id" in
  let* trace_id = Keeper_id.Trace_id.of_string trace_id in
  let* task_id =
    match Yojson.Safe.Util.member "task_id" json with
    | `Null -> Ok None
    | `String value -> Keeper_id.Task_id.of_string value |> Result.map Option.some
    | _ -> Error "task_id must be null or a Task id"
  in
  let* digest = Json_util.require_string json "surface_sha256" in
  let* surface_sha256 =
    match Digestif.SHA256.consistent_of_hex_opt digest with
    | Some digest -> Ok digest
    | None -> Error "surface_sha256 must be a SHA-256 digest"
  in
  let* rows = Json_field.list json "pending" |> Json_field.require in
  let* pending =
    List.fold_left
      (fun acc row ->
         let* pending = acc in
         let* name, receipt = decode_load row in
         if Names.mem name pending
         then Error "pending contains a duplicate tool name"
         else Ok (Names.add name receipt pending))
      (Ok Names.empty)
      rows
  in
  Ok { scope = { trace_id; task_id; surface_sha256 }; pending }
;;

let snapshot_to_json { scope; pending } =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string scope.trace_id)
    ; ( "task_id"
      , Option.fold
          ~none:`Null
          ~some:(fun id -> `String (Keeper_id.Task_id.to_string id))
          scope.task_id )
    ; "surface_sha256", `String (Digestif.SHA256.to_hex scope.surface_sha256)
    ; ( "pending"
      , `List
          (Names.bindings pending
           |> List.map (fun (name, receipt) ->
             `Assoc
               [ "name", `String name
               ; "tool_use_id", `String receipt.tool_use_id
               ; "turn", `Int receipt.turn
               ; "planned_index", `Int receipt.planned_index
               ])) )
    ]
;;

let restore ~source ~target : (restored, error) result =
  let stored =
    Agent_core.Context.get_scoped source Agent_core.Context.Session context_key
  in
  let* snapshot =
    match stored with
    | None -> Ok None
    | Some json ->
      decode_snapshot json
      |> Result.map Option.some
      |> Result.map_error (fun detail -> Invalid_snapshot detail)
  in
  (match stored with
   | None ->
     Agent_core.Context.delete_scoped target Agent_core.Context.Session context_key
   | Some json ->
     Agent_core.Context.set_scoped target Agent_core.Context.Session context_key json);
  Ok { context = target; snapshot }
;;

let source_to_json = function
  | Builtin -> `Assoc [ "kind", `String "builtin" ]
  | Attached { provider_id; endpoint; remote_name } ->
    `Assoc
      [ "kind", `String "attached"
      ; "provider_id", `String provider_id
      ; "endpoint", `String endpoint
      ; "remote_name", `String remote_name
      ]
;;

let surface_digest surface =
  `List
    (List.map
       (fun { source; schema } ->
          `Assoc
            [ "source", source_to_json source
            ; "schema", Agent_core.Types.tool_schema_to_json schema
            ])
       surface)
  |> Yojson.Safe.sort
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
;;

let equal_scope a b =
  Keeper_id.Trace_id.equal a.trace_id b.trace_id
  && Option.equal Keeper_id.Task_id.equal a.task_id b.task_id
  && Digestif.SHA256.equal a.surface_sha256 b.surface_sha256
;;

let store context snapshot =
  Agent_core.Context.set_scoped
    context
    Agent_core.Context.Session
    context_key
    (snapshot_to_json snapshot)
;;

let create ~(restored : restored) ~trace_id ~task_id ~current_task_id ~surface =
  let scope = { trace_id; task_id; surface_sha256 = surface_digest surface } in
  let snapshot =
    match restored.snapshot with
    | Some snapshot when equal_scope snapshot.scope scope -> snapshot
    | Some _ | None -> { scope; pending = Names.empty }
  in
  let lock =
    match Agent_core.Context.concurrency_backend restored.context with
    | Agent_core.Context.Stdlib_mutex -> Sync (Mutex.create ())
    | Agent_core.Context.Eio_mutex -> Async (Eio.Mutex.create ())
  in
  store restored.context snapshot;
  { context = restored.context; lock; current_task_id; snapshot }
;;

let with_lock t f =
  match t.lock with
  | Sync lock ->
    (* A synchronous Context and the tool-set extension do not yield. *)
    Mutex.lock lock;
    Fun.protect f ~finally:(fun () -> Mutex.unlock lock)
  | Async lock ->
    (* A failed tool-set extension leaves the receipt snapshot unchanged.
       Propagate that failure after unlocking: letting it escape [use_rw]
       would poison the receipt lock and prevent every later load or use. *)
    let result =
      Eio.Mutex.use_rw ~protect:true lock (fun () ->
        try Ok (f ()) with exn -> (* cancel-guard-ok *)
          Error (exn, Printexc.get_raw_backtrace ()))
    in
    (match result with
     | Ok value -> value
     | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace)
;;

let pending_names t =
  with_lock t (fun () -> List.map fst (Names.bindings t.snapshot.pending))
;;

let publish t snapshot =
  store t.context snapshot;
  t.snapshot <- snapshot
;;

let loaded t ~invocation ~names ~apply =
  with_lock t (fun () ->
    let* task_id =
      t.current_task_id ()
      |> Result.map_error (fun detail -> Work_scope_unavailable detail)
    in
    let scope = { t.snapshot.scope with task_id } in
    let previous =
      if equal_scope t.snapshot.scope scope then t.snapshot.pending else Names.empty
    in
    apply ();
    let receipt =
      { tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation
      ; turn = Agent_core.Tool_contract.Invocation.turn invocation
      ; planned_index = Agent_core.Tool_contract.Invocation.planned_index invocation
      }
    in
    let pending =
      List.fold_left
        (fun pending name -> Names.add name receipt pending)
        previous
        names
    in
    publish t { scope; pending };
    Ok ())
;;

let dispatched t ~name =
  with_lock t (fun () ->
    if Names.mem name t.snapshot.pending
    then publish t { t.snapshot with pending = Names.remove name t.snapshot.pending })
;;

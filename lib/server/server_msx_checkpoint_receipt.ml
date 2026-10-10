type action = Save | Restore
type binding = { operation_id : Keeper_operation_id.t; action : action; slot : string }
(* The completion a worker reports for the checkpoint it ran. Local so the
   receipt store does not link the emulator lane it records evidence about. *)
type change_mark = { incarnation : string; count : int }
type completion = { mark : change_mark; checkpoint_sha256 : string }
type state = Pending | Committed of completion | Refused of string | Unknown of string
type receipt = { binding : binding; epoch : string; state : state }
type admission = Accepted | Existing of receipt
type error = Invalid_binding of string | Binding_conflict | Store_unavailable of string
let error_to_string = function
  | Invalid_binding message | Store_unavailable message -> message
  | Binding_conflict -> "checkpoint operation identity was already bound to another action or slot"
let ( let* ) = Result.bind
let action_name = function Save -> "save" | Restore -> "restore"
let schema =
  "CREATE TABLE receipts (operation_id TEXT PRIMARY KEY, action TEXT NOT NULL CHECK(action IN ('save','restore')), slot TEXT NOT NULL, epoch TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','committed','refused','unknown')), detail TEXT, incarnation TEXT, change_count INTEGER, checkpoint_sha256 TEXT, CHECK((state='pending' AND detail IS NULL AND incarnation IS NULL AND change_count IS NULL AND checkpoint_sha256 IS NULL) OR (state='committed' AND detail IS NULL AND incarnation IS NOT NULL AND change_count IS NOT NULL AND change_count>=0 AND checkpoint_sha256 IS NOT NULL) OR (state IN ('refused','unknown') AND detail IS NOT NULL AND incarnation IS NULL AND change_count IS NULL AND checkpoint_sha256 IS NULL))) STRICT"
let immutable =
  "CREATE TRIGGER terminal_immutable BEFORE UPDATE ON receipts WHEN OLD.state <> 'pending' BEGIN SELECT RAISE(ABORT,'terminal checkpoint receipt is immutable'); END"
let binding_immutable =
  "CREATE TRIGGER binding_immutable BEFORE UPDATE ON receipts WHEN NEW.operation_id <> OLD.operation_id OR NEW.action <> OLD.action OR NEW.slot <> OLD.slot OR NEW.epoch <> OLD.epoch BEGIN SELECT RAISE(ABORT,'checkpoint operation binding is immutable'); END"
let no_delete =
  "CREATE TRIGGER receipt_retained BEFORE DELETE ON receipts BEGIN SELECT RAISE(ABORT,'checkpoint identity receipts are retained'); END"
let sql_error db = Store_unavailable (Sqlite3.errmsg db)
let exec db sql = if Sqlite3.Rc.is_success (Sqlite3.exec db sql) then Ok () else Error (sql_error db)
let statement db sql values f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    let rec bind n = function
      | [] -> f stmt
      | value::rest ->
          if Sqlite3.Rc.is_success (Sqlite3.bind stmt n value) then bind (n+1) rest
          else Error (sql_error db) in
    bind 1 values)
let text value = Sqlite3.Data.TEXT value
let done_ db stmt = if Sqlite3.step stmt = Sqlite3.Rc.DONE then Ok () else Error (sql_error db)
let valid binding =
  match Machine_checkpoint.slot_of_string binding.slot with
  | Ok _ -> Ok () | Error message -> Error (Invalid_binding message)
let schema_objects db =
  statement db "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name" []
    (fun stmt ->
      let rec rows acc = match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> rows ((Sqlite3.column_text stmt 0,Sqlite3.column_text stmt 1)::acc)
        | DONE -> Ok (List.rev acc)
        | _ -> Error (sql_error db) in
      rows [])
let expected_schema = List.sort compare
  ["receipts",schema;"terminal_immutable",immutable;"receipt_retained",no_delete;"binding_immutable",binding_immutable]
let validate_schema db =
  let* actual = schema_objects db in
  if actual = expected_schema then Ok () else Error (Store_unavailable "checkpoint receipt schema differs")
let transaction db f =
  let* () = exec db "BEGIN IMMEDIATE" in
  let committed = ref false in
  Fun.protect ~finally:(fun () -> if not !committed then ignore (Sqlite3.exec db "ROLLBACK"))
    (fun () -> let* value = f () in let* () = exec db "COMMIT" in committed := true; Ok value)
let with_db ?(create=false) ~write ~path f =
  try
    let db = if create then Sqlite3.db_open path
      else Sqlite3.db_open ~mode:(if write then `NO_CREATE else `READONLY) path in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
      if write then begin
        let* () = exec db "PRAGMA journal_mode=DELETE" in
        let* () = exec db "PRAGMA synchronous=EXTRA" in
        let* () = statement db "PRAGMA synchronous" [] (fun stmt ->
          if Sqlite3.step stmt = Sqlite3.Rc.ROW && Sqlite3.column_int stmt 0 = 3
          then Ok () else Error (Store_unavailable "checkpoint receipt durability mode unavailable")) in
        transaction db (fun () ->
          let* objects = schema_objects db in
          let* () = if objects = [] && create then
            let* () = exec db schema in let* () = exec db immutable in
            let* () = exec db binding_immutable in exec db no_delete
            else validate_schema db in
          f db)
      end else let* () = validate_schema db in f db)
  with
  | Sqlite3.Error message | Sqlite3.SqliteError message | Sqlite3.DataTypeError message
  | Sqlite3.InternalError message | Sys_error message -> Error (Store_unavailable message)
  | Unix.Unix_error (error, operation, path) ->
      Error (Store_unavailable (operation ^ " " ^ path ^ ": " ^ Unix.error_message error))
let valid_completion completed =
  completed.mark.count >= 0 && String.trim completed.mark.incarnation <> ""
  && match Digestif.SHA256.consistent_of_hex_opt completed.checkpoint_sha256 with
     | Some digest -> Digestif.SHA256.to_hex digest = completed.checkpoint_sha256
     | None -> false
let read db binding =
  statement db
    "SELECT action,slot,epoch,state,detail,incarnation,change_count,checkpoint_sha256 FROM receipts WHERE operation_id=?"
    [text (Keeper_operation_id.to_string binding.operation_id)] (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> Ok None
      | ROW ->
          if Sqlite3.column_text stmt 0 <> action_name binding.action
             || Sqlite3.column_text stmt 1 <> binding.slot then Error Binding_conflict
          else
            let state = match Sqlite3.column_text stmt 3 with
              | "pending" -> Some Pending
              | "refused" -> Some (Refused (Sqlite3.column_text stmt 4))
              | "unknown" -> Some (Unknown (Sqlite3.column_text stmt 4))
              | "committed" ->
                  let count = Sqlite3.column_int64 stmt 6 in
                  if count < 0L || count > Int64.of_int max_int then None
                  else Some (Committed {
                    mark={incarnation=Sqlite3.column_text stmt 5;
                          count=Int64.to_int count};
                    checkpoint_sha256=Sqlite3.column_text stmt 7 })
              | _ -> None in
            (match state with
             | None -> Error (Store_unavailable "invalid checkpoint receipt state")
             | Some (Committed completed) when not (valid_completion completed) ->
                 Error (Store_unavailable "invalid persisted checkpoint completion evidence")
             | Some state -> Ok (Some {binding;epoch=Sqlite3.column_text stmt 2;state}))
      | _ -> Error (sql_error db))
let admit ~path ~epoch binding =
  let* () = valid binding in
  if String.trim epoch = "" then Error (Invalid_binding "checkpoint epoch is blank") else
  with_db ~create:true ~write:true ~path (fun db ->
    let* previous = read db binding in
    match previous with
    | Some receipt -> Ok (Existing receipt)
    | None ->
        let* () = statement db
          "INSERT INTO receipts(operation_id,action,slot,epoch,state) VALUES(?,?,?,?,'pending')"
          [text (Keeper_operation_id.to_string binding.operation_id);text (action_name binding.action);
           text binding.slot;text epoch] (done_ db) in
        Ok Accepted)
let inspect ~path binding =
  let* () = valid binding in
  try
    ignore (Unix.stat path);
    with_db ~write:false ~path (fun db -> read db binding)
  with
  | Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None
  | Unix.Unix_error (error,operation,path) ->
      Error (Store_unavailable (operation ^ " " ^ path ^ ": " ^ Unix.error_message error))
let settle_once ~path ~epoch binding state =
  let* () = valid binding in
  let* state_name,detail,incarnation,count,digest = match state with
    | Pending -> Error (Invalid_binding "cannot settle to pending")
    | Committed completed when not (valid_completion completed) ->
        Error (Invalid_binding "invalid checkpoint completion evidence")
    | Committed completed -> Ok ("committed",Sqlite3.Data.NULL,text completed.mark.incarnation,
        Sqlite3.Data.INT (Int64.of_int completed.mark.count),text completed.checkpoint_sha256)
    | Refused detail -> Ok ("refused",text detail,Sqlite3.Data.NULL,Sqlite3.Data.NULL,Sqlite3.Data.NULL)
    | Unknown detail -> Ok ("unknown",text detail,Sqlite3.Data.NULL,Sqlite3.Data.NULL,Sqlite3.Data.NULL) in
  with_db ~write:true ~path (fun db ->
    let* previous = read db binding in
    match previous with
    | Some {epoch=owner;state=Pending;_} when owner=epoch ->
        statement db
          "UPDATE receipts SET state=?,detail=?,incarnation=?,change_count=?,checkpoint_sha256=? WHERE operation_id=?"
          [text state_name;detail;incarnation;count;digest;text (Keeper_operation_id.to_string binding.operation_id)] (done_ db)
    | Some _ | None -> Error (Store_unavailable "checkpoint receipt is not pending in this server epoch"))


(* The effect worker has finished, but SQLite may temporarily refuse its
   terminal receipt. Retain that exact observation until it can be committed;
   status inspection retries only this write, never the machine operation. *)
let failed_settlements_mu = Mutex.create ()
let failed_settlements : ((string * string * string), binding * state) Hashtbl.t = Hashtbl.create 8
let settlement_key ~path ~epoch binding = path, epoch, Keeper_operation_id.to_string binding.operation_id
let settle ~path ~epoch binding state =
  let key = settlement_key ~path ~epoch binding in
  let result = settle_once ~path ~epoch binding state in
  Mutex.protect failed_settlements_mu (fun () ->
    match result with
    | Ok () -> Hashtbl.remove failed_settlements key
    | Error (Store_unavailable _) ->
        (* The first completed observation owns this retry; a later attempted
           terminal rewrite must not replace its evidence. *)
        if not (Hashtbl.mem failed_settlements key) then
          Hashtbl.add failed_settlements key (binding, state)
    | Error (Invalid_binding _ | Binding_conflict) -> ());
  result

let retry_settlement ~path ~epoch binding =
  let key = settlement_key ~path ~epoch binding in
  let retained = Mutex.protect failed_settlements_mu (fun () -> Hashtbl.find_opt failed_settlements key) in
  match retained with
  | None -> Ok ()
  | Some (original, _) when original.action <> binding.action || original.slot <> binding.slot ->
      Error Binding_conflict
  | Some (_, state) ->
      let* receipt = inspect ~path binding in
      match receipt with
      | Some {epoch=owner; state=Pending; _} when owner=epoch -> settle ~path ~epoch binding state
      | Some {state=(Committed _ | Refused _ | Unknown _); _} ->
          Mutex.protect failed_settlements_mu (fun () -> Hashtbl.remove failed_settlements key);
          Ok ()
      | Some {state=Pending; _} | None ->
          Error (Store_unavailable "checkpoint settlement recovery lost its admitted epoch")

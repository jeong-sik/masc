module Exact = Lane_addon_exact
module Store = Lane_addon_store
let ( let* ) = Result.bind
type configuration = {store_root:string; outputs:Lane_addon_types.exact_output list}
let configuration_to_json configuration = `Assoc ["store_root",`String configuration.store_root;
  "outputs",`Assoc (List.map (fun (output:Lane_addon_types.exact_output) -> output.name,output.schema) configuration.outputs)]
let configuration_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["outputs";"store_root"] ->
      let* store_root = match List.assoc "store_root" fields with
        | `String path when not (Filename.is_relative path) && not (String.contains path '\000') -> Ok path
        | _ -> Error "model receipt root must be an absolute host path" in
      let* outputs = match List.assoc "outputs" fields with
        | `Assoc outputs ->
            let names=List.map fst outputs in
            let* () = if List.length names=List.length (List.sort_uniq String.compare names) then Ok ()
              else Error "duplicate browser model output" in
            List.fold_right (fun (name,schema) acc -> let* rest=acc in
              let* ()=if Runtime_schema.exact_output_name_valid name then Ok () else Error "invalid browser model output" in
              let* ()=Lane_addon_action.validate_value_schema schema in
              Ok ({Lane_addon_types.name;schema}::rest)) outputs (Ok [])
        | _ -> Error "browser model outputs must be an object" in
      Ok {store_root;outputs}
  | _ -> Error "invalid browser model configuration"
type error = Retired | Output_disabled of string | Request_in_use
  | Receipt_failed of string | Invalid_result of string
let error_to_string = function
  | Retired -> "browser model owner is retired"
  | Output_disabled name -> "browser model output is disabled: " ^ name
  | Request_in_use -> "browser model request id was already used"
  | Receipt_failed detail -> "browser model receipt failed: " ^ detail
  | Invalid_result detail -> "invalid browser model result: " ^ detail
type outcome = Final of Exact.final | Exceeds_frame of {sha256:string;bytes:int}
type pending = {request:Exact.request; schema:Yojson.Safe.t;
  resolve:(outcome,error) result Eio.Promise.u}
type phase = Serving | Closed
type t = {incarnation:string; configuration:configuration; store:Store.t;
  mutable phase:phase; mutable pending:(string * pending) list;
  used:(string,unit) Hashtbl.t; mutable revision:int64; changed:Eio.Condition.t;
  receipts:Eio.Mutex.t}
let incarnation t = t.incarnation
let output_schema t ~name = match t.phase with
  | Closed -> None
  | Serving -> List.find_opt (fun (output:Lane_addon_types.exact_output) -> output.name=name)
      t.configuration.outputs |> Option.map (fun (output:Lane_addon_types.exact_output) -> output.schema)
let create ~incarnation ~configuration =
  let* _ = Browser_lane.client_id_of_string incarnation in
  let* configuration = configuration_of_json (configuration_to_json configuration) in
  Ok {incarnation;configuration;store=Store.create ~root:configuration.store_root;phase=Serving;
    pending=[];used=Hashtbl.create 8;revision=0L;changed=Eio.Condition.create ();receipts=Eio.Mutex.create ()}
let changed t = t.revision<-Int64.succ t.revision;Eio.Condition.broadcast t.changed
let withdraw t id original = match List.assoc_opt id t.pending with
  | Some current when current==original -> t.pending<-List.remove_assoc id t.pending;changed t
  | None | Some _ -> ()
let request t request = match t.phase with
  | Closed -> Error Retired
  | Serving ->
      match List.find_opt (fun (output:Lane_addon_types.exact_output) -> output.name=request.Exact.output) t.configuration.outputs with
      | None -> Error (Output_disabled request.output)
      | Some output ->
          if Hashtbl.mem t.used request.request_id then Error Request_in_use else
          let answer,resolve=Eio.Promise.create () in
          let pending={request;schema=output.schema;resolve} in
          Hashtbl.add t.used request.request_id ();
          t.pending<-t.pending @ [request.request_id,pending];changed t;
          Fun.protect ~finally:(fun () -> withdraw t request.request_id pending) (fun () -> Eio.Promise.await answer)
let listing t = match t.phase with
  | Closed -> Error Retired
  | Serving -> Ok (`Assoc ["requests",`List (List.map (fun (_,pending) -> Exact.request_to_json pending.request) t.pending)])
let wait t ~after = Eio.Condition.loop_no_mutex t.changed (fun () -> match t.phase with
  | Closed -> Some (Error Retired)
  | Serving ->
      let revision=Int64.to_string t.revision in
      if after=Some revision then None
      else Some (Ok {Lane_addon_host_request.revision;request_ids=List.map fst t.pending}))
let retire t = match t.phase with
  | Closed -> ()
  | Serving ->
      t.phase<-Closed;
      let pending=t.pending in t.pending<-[];changed t;
      List.iter (fun (_,pending) -> ignore (Eio.Promise.try_resolve pending.resolve (Error Retired))) pending
let decode_result ~schema result =
  match result with
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["bytes";"retained_sha256";"status"]
      && List.assoc "status" fields=`String "result_exceeds_frame" ->
      (match List.assoc "bytes" fields,List.assoc "retained_sha256" fields with
       | `Int bytes,`String sha256 when bytes>0 && String.length sha256=64 &&
           String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) sha256 -> Ok (Exceeds_frame {sha256;bytes})
       | _ -> Error "invalid oversized model result")
  | _ -> Exact.final_of_json ~schema result |> Result.map (fun final -> Final final)
let delivery_arguments = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["request_id";"result"] ->
      (match List.assoc "request_id" fields with
       | `String id when String.trim id<>"" -> Ok (id,List.assoc "result" fields)
       | _ -> Error "invalid model result request id")
  | _ -> Error "invalid model result arguments"
let deliver t ~arguments =
  let* request_id,result=delivery_arguments arguments |> Result.map_error (fun detail -> Invalid_result detail) in
  match t.phase with
  | Closed -> Error Retired
  | Serving -> Eio.Mutex.use_ro t.receipts (fun () ->
      if t.phase=Closed then Error Retired else
      let* result=Lane_addon_action.canonical result |> Result.map_error (fun detail -> Invalid_result detail) in
      let result_digest=Store.digest (Yojson.Safe.to_string result) in
      let* retained=Eio_unix.run_in_systhread (fun () -> Store.load_exact_request t.store
        ~declaration_id:t.incarnation ~request_id) |> Result.map_error (fun detail -> Receipt_failed detail) in
      if t.phase=Closed then Error Retired else
      let* pending=match retained,List.assoc_opt request_id t.pending with
        | Some (`Assoc fields),_ when List.sort String.compare (List.map fst fields)=
            ["disposition";"incarnation";"request";"request_digest";"result";"result_digest"] ->
            let* original=Exact.request_of_json (List.assoc "request" fields)
              |> Result.map_error (fun detail -> Receipt_failed detail) in
            let* output=List.find_opt (fun (output:Lane_addon_types.exact_output) -> output.name=original.output)
              t.configuration.outputs |> Option.to_result ~none:(Output_disabled original.output) in
            let* _=decode_result ~schema:output.schema result |> Result.map_error (fun detail -> Invalid_result detail) in
            if original.request_id=request_id
              && List.assoc "request_digest" fields=`String (Exact.digest original)
              && List.assoc "incarnation" fields=`String t.incarnation
              && List.assoc "disposition" fields=`String "model_result_received"
              && List.assoc "result_digest" fields=`String result_digest
              && List.assoc "result" fields=result then Ok None
            else Error (Invalid_result "conflicting retained model result")
        | Some _,_ -> Error (Receipt_failed "invalid retained browser model receipt")
        | None,None -> Ok None
        | None,Some pending ->
            let* outcome=decode_result ~schema:pending.schema result |> Result.map_error (fun detail -> Invalid_result detail) in
            Ok (Some (pending,outcome)) in
      match pending with
      | None -> Ok (Option.is_some retained)
      | Some (pending,outcome) ->
          let receipt=`Assoc ["incarnation",`String t.incarnation;"request",Exact.request_to_json pending.request;
            "request_digest",`String (Exact.digest pending.request);"result",result;"result_digest",`String result_digest;
            "disposition",`String "model_result_received"] in
          let* ()=Eio_unix.run_in_systhread (fun () -> Store.save_exact_request t.store
            ~declaration_id:t.incarnation ~request_id receipt) |> Result.map_error (fun detail -> Receipt_failed detail) in
          (* The write yields: a cancelled command can already have withdrawn
             its waiter. The receipt survives, but cannot wake another call. *)
          match t.phase,List.assoc_opt request_id t.pending with
          | Serving,Some current when current==pending ->
              withdraw t request_id pending;Eio.Promise.resolve pending.resolve (Ok outcome);Ok true
          | (Serving|Closed),(None|Some _) -> Ok false)

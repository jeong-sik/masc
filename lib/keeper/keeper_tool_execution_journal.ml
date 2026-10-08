(* Keeper_tool_execution_journal — 요청 단위 내구 실행 저널 (H2-S1/S2).

   Board 계약 p-963d6bf387f1bbd6e217054ad293c155 H2: "중단된
   composition·async 실행을 효과 확인 후 같은 요청에서 재개한다".

   실행기(keeper_tool_plan_executor)가 노드를 dispatch 하기 전에
   [attempting]을 남기고, 정산 후 [settled]로 바꾼다. 같은 요청
   식별자(request_id)로 다시 실행되면:

   - settled 레코드가 있는 노드는 dispatch 하지 않고 저장된 결과로 정산한다
     (적용된 단계의 중복 dispatch 금지).
   - attempting 잔여 레코드는 기록된 effect disposition 이
     [Proven_pre_effect]일 때만 재 dispatch 한다. 그 외(unknown·post)는
     fail-closed로 재개를 거절한다 — 효과가 이미 발생했을 수 있는 단계를
     두 번 치지 않는다.
   - 레코드를 읽을 수 없으면(손상·스키마 불일치) 저널을 조용히 무시하거나
     재작성하지 않고 [Journal_unreadable]을 돌려준다. 재개 여부를 판단할
     수 없는 상태에서 실행을 계속하면 중복이 조용해지므로, 계획은
     incomplete로 남고 호출자가 결정한다 (H2-S2).

   저장은 Keeper_fs.save_json_durable_atomic (엄격 내구 원자적 쓰기) 하나로
   게시한다. 레이아웃: <dir>/<request_id>/<node_id>.json. *)

open Keeper_types

type effect_disposition = Tool_result.failure_effect_disposition

type record_status =
  | Attempting
  | Settled

type record =
  { schema_version : int
  ; request_id : string
  ; node_id : string
  ; status : record_status
  ; effect_disposition : effect_disposition
  ; result_json : Yojson.Safe.t option
  ; updated_at_unix_s : float
  }

type read_error =
  | Corrupt_record of string
  | Schema_mismatch of { found : string }
  | Directory_unreadable of string

type resume_decision =
  | Skip_node_settled of record
      (** dispatch 없이 저장 결과로 정산. *)
  | Redo_node_pre_effect of record
      (** 효과 전임이 증명돼 있어 다시 dispatch 해도 안전. *)
  | Refuse_unknown_effect of record
      (** 효과 상태를 알 수 없어 fail-closed. *)
  | No_journal

type write_error = string

let schema_version = 1

let effect_disposition_to_string = Tool_result.failure_effect_disposition_to_string

let effect_disposition_of_string = Tool_result.failure_effect_disposition_of_string

let status_to_string = function
  | Attempting -> "attempting"
  | Settled -> "settled"
;;

let status_of_string = function
  | "attempting" -> Some Attempting
  | "settled" -> Some Settled
  | _ -> None
;;

let record_to_json record =
  `Assoc
    [ "schema_version", `Int record.schema_version
    ; "request_id", `String record.request_id
    ; "node_id", `String record.node_id
    ; "status", `String (status_to_string record.status)
    ; "effect_disposition", `String (effect_disposition_to_string record.effect_disposition)
    ; "result_json", (match record.result_json with Some json -> json | None -> `Null)
    ; "updated_at_unix_s", `Float record.updated_at_unix_s
    ]
;;

let record_of_json json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc fields -> (
      let member_string name =
        match List.assoc_opt name fields with
        | Some (`String value) -> Some value
        | _ -> None
      in
      match List.assoc_opt "schema_version" fields with
      | Some (`Int version) when version = schema_version -> (
          match (member_string "request_id", member_string "node_id") with
          | Some request_id, Some node_id -> (
              let status =
                match Option.bind (member_string "status") status_of_string with
                | Some status -> Some status
                | None -> None
              in
              let disposition =
                match member_string "effect_disposition" with
                | Some raw -> effect_disposition_of_string raw
                | None -> None
              in
              let result_json =
                match List.assoc_opt "result_json" fields with
                | Some `Null -> None
                | Some json -> Some json
                | None -> None
              in
              let updated_at =
                match List.assoc_opt "updated_at_unix_s" fields with
                | Some (`Float value) -> value
                | _ -> 0.0
              in
              match (status, disposition) with
              | Some status, Some disposition ->
                Ok
                  { schema_version
                  ; request_id
                  ; node_id
                  ; status
                  ; effect_disposition = disposition
                  ; result_json
                  ; updated_at_unix_s = updated_at
                  }
              | _ ->
                Error
                  (Corrupt_record
                     (Printf.sprintf "request %s node %s: bad status/disposition" request_id node_id)))
          | request_id, node_id ->
            let describe = function
              | Some value -> value
              | None -> "missing"
            in
            Error
              (Corrupt_record
                 (Printf.sprintf "ids %s/%s" (describe request_id) (describe node_id))))
      | Some (`Int other) ->
        Error (Schema_mismatch { found = "schema_version=" ^ string_of_int other })
      | _ -> Error (Schema_mismatch { found = "schema_version missing or not int" }))
  | _ -> Error (Corrupt_record "record is not a JSON object")
;;

let record_path ~dir ~request_id ~node_id =
  if
    String.length request_id > 0
    && String.length node_id > 0
    && String.for_all (fun c ->
           match c with
           | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
           | _ -> false)
           request_id
    && String.for_all (fun c ->
           match c with
           | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
           | _ -> false)
           node_id
  then Some (Filename.concat (Filename.concat dir request_id) (node_id ^ ".json"))
  else None
;;

let read_record ~dir ~request_id ~node_id =
  match record_path ~dir ~request_id ~node_id with
  | None -> Error (Corrupt_record "unsafe path components")
  | Some path -> (
      match open_in_bin path with
      | exception Sys_error _ -> Ok None
      | exception _ -> Error (Directory_unreadable path)
      | channel -> (
          let bytes =
            really_input_string channel (in_channel_length channel)
          in
          close_in channel;
          match Yojson.Safe.from_string bytes with
          | exception Yojson.Json_error reason -> Error (Corrupt_record reason)
          | json -> (
              match record_of_json json with
              | Ok record -> Ok (Some record)
              | Error ((Corrupt_record _ | Schema_mismatch _) as error) -> Error error
              | Error (Directory_unreadable _) ->
                Error (Corrupt_record "confused read error"))))
;;

let write_record ~dir record =
  match record_path ~dir ~request_id:record.request_id ~node_id:record.node_id with
  | None -> Error "unsafe path components"
  | Some path -> (
      let request_dir = Filename.concat dir record.request_id in
      (try if not (Sys.file_exists request_dir) then Unix.mkdir request_dir 0o755
       with Unix.Unix_error _ -> ());
      Keeper_fs.save_json_durable_atomic ~pretty:false path (record_to_json record)
      |> Result.map_error Keeper_fs.durable_write_error_to_string)
;;

(* 재개 판정: 기록된 disposition 이 효과 전임을 증명하는 경우에만 재실행. *)
let resume_decision_of_record record =
  match record.status with
  | Settled -> Skip_node_settled record
  | Attempting -> (
      match record.effect_disposition with
      | Tool_result.Proven_pre_effect -> Redo_node_pre_effect record
      | Tool_result.Effect_outcome_unknown | Tool_result.Proven_post_effect ->
        Refuse_unknown_effect record)
;;

(* 노드가 실제로 dispatch 되기 전에 부른다. 기존 레코드가 있으면 그 판정을,
   없으면 dispatch-전 효과 분류([pre_effect_disposition]: readonly 노드는
   [Proven_pre_effect], 효과 가능 노드는 [Effect_outcome_unknown])를 담은
   attempting 을 새로 남기고 Redo 를 돌려준다. *)
let begin_node ~dir ~request_id ~node_id ~pre_effect_disposition =
  match read_record ~dir ~request_id ~node_id with
  | Error error -> Error error
  | Ok (Some record) -> Ok (resume_decision_of_record record)
  | Ok None -> (
      let record =
        { schema_version
        ; request_id
        ; node_id
        ; status = Attempting
        ; effect_disposition = pre_effect_disposition
        ; result_json = None
        ; updated_at_unix_s = Unix.gettimeofday ()
        }
      in
      match write_record ~dir record with
      | Ok () -> Ok (Redo_node_pre_effect record)
      | Error error -> Error (Corrupt_record ("write failed: " ^ error)))
;;

(* 정산 후 settled 로 승격한다. disposition 은 실행기가 계산한 것으로
   갱신하고, Completed 결과는 저장해 재개 정산에 재사용한다. *)
let settle_node
      ~dir
      ~request_id
      ~node_id
      ~effect_disposition
      ?(result_json : Yojson.Safe.t option)
      () =
  let record =
    { schema_version
    ; request_id
    ; node_id
    ; status = Settled
    ; effect_disposition
    ; result_json
    ; updated_at_unix_s = Unix.gettimeofday ()
    }
  in
  write_record ~dir record
;;

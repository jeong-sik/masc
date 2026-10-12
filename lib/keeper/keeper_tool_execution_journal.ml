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

type record = { schema_version : int
  ; request_id : string
  ; node_id : string
  ; status : record_status
  ; effect_disposition : effect_disposition
  ; plan_revision : string
      (** 계획 identity: 계획 fingerprint(노드 집합·입력 템플릿·의존성의
          해시). 다른 계획이 같은 request_id 를 재사용해 저장 결과를 훔쳐
          보지 못하게 한다 (H2 계약: input identity 결속). *)
  ; input_sha : string
      (** 노드 입력 identity: 실제 resolve 된 입력 JSON 의 SHA-256. 같은
          노드라도 입력이 다르면 저장 결과를 재사용하지 않는다. *)
  ; owner : string
      (** 소유권(워커 identity): 다른 워커의 저널을 재사용하지 않는다. *)
  ; result_json : Yojson.Safe.t option
  ; updated_at_unix_s : float
  }

type read_error =
  | Corrupt_record of string
  | Schema_mismatch of { found : string }
  | Directory_unreadable of string

type identity = { plan_revision : string; input_sha : string; owner : string }

type identity_mismatch =
  { stored_plan_revision : string
  ; stored_input_sha : string
  ; stored_owner : string
  ; given_plan_revision : string
  ; given_input_sha : string
  ; given_owner : string
  }

type resume_decision =
  | Skip_node_settled of record
      (** dispatch 없이 저장 결과로 정산. *)
  | Redo_node_pre_effect of record
      (** 효과 전임이 증명돼 있어 다시 dispatch 해도 안전. *)
  | Refuse_unknown_effect of record
      (** 효과 상태를 알 수 없어 fail-closed. *)
  | Identity_mismatch of identity_mismatch
      (** 기록된 계획·입력·소유권이 이번 재시도와 다르다 — 이 요청의 저널이
          아니다. 저장 결과를 재사용하지 않고 거절한다(조용한 재작성 없음). *)
  | No_journal

let digests_equal a b = String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)

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
    ([ "schema_version", `Int record.schema_version
    ; "request_id", `String record.request_id
    ; "node_id", `String record.node_id
    ; "status", `String (status_to_string record.status)
    ; "effect_disposition", `String (effect_disposition_to_string record.effect_disposition)
    ; "plan_revision", `String record.plan_revision
    ; "input_sha", `String record.input_sha
    ; "owner", `String record.owner
    ; "updated_at_unix_s", `Float record.updated_at_unix_s
    ]
    @ (match record.result_json with
       | None -> []
       | Some json -> [ "result_json", json ]))
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
                (* JSON null is a completed value; only absence means no result. *)
                List.assoc_opt "result_json" fields
              in
              let updated_at =
                match List.assoc_opt "updated_at_unix_s" fields with
                | Some (`Float value) -> value
                | _ -> 0.0
              in
              let required_string name =
                match member_string name with
                | Some value when String.length value > 0 -> Some value
                | _ -> None
              in
              match
                ( status
                , disposition
                , required_string "plan_revision"
                , required_string "input_sha"
                , required_string "owner" )
              with
              | Some status, Some disposition, Some plan_revision, Some input_sha, Some owner ->
                Ok
                  { schema_version
                  ; request_id
                  ; node_id
                  ; status
                  ; effect_disposition = disposition
                  ; plan_revision
                  ; input_sha
                  ; owner
                  ; result_json
                  ; updated_at_unix_s = updated_at
                  }
              | ( Some _
                , Some _
                , _
                , _
                , _ )
                when Option.is_none (member_string "plan_revision")
                     || Option.is_none (member_string "input_sha")
                     || Option.is_none (member_string "owner") ->
                Error
                  (Schema_mismatch
                     { found = "identity fields (plan_revision/input_sha/owner) missing" })
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
    && request_id <> "." && request_id <> ".."
    && node_id <> "." && node_id <> ".."
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
      match Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
      | exception Unix.Unix_error _ -> Error (Directory_unreadable path)
      | fd ->
          let channel = Unix.in_channel_of_descr fd in
          match Fun.protect ~finally:(fun () -> close_in_noerr channel)
              (fun () -> really_input_string channel (in_channel_length channel)) with
          | exception (Sys_error _ | End_of_file | Unix.Unix_error _) ->
              Error (Directory_unreadable path)
          | bytes ->
              match Yojson.Safe.from_string bytes with
              | exception Yojson.Json_error reason -> Error (Corrupt_record reason)
              | json ->
                  match record_of_json json with
                  | Error error -> Error error
                  | Ok record when String.equal record.request_id request_id
                                   && String.equal record.node_id node_id ->
                      Ok (Some record)
                  | Ok _ -> Error (Corrupt_record "record request/node IDs differ from its path"))
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

let identity_matches ~(identity : identity) (record : record) : bool =
  String.equal record.plan_revision identity.plan_revision
  && digests_equal record.input_sha identity.input_sha
  && String.equal record.owner identity.owner
;;

(* Settled and Attempting both belong to the recorded plan/input/owner. *)
let resume_decision_of_record ~identity record =
  if not (identity_matches ~identity record) then
    Identity_mismatch
      { stored_plan_revision = record.plan_revision
      ; stored_input_sha = record.input_sha
      ; stored_owner = record.owner
      ; given_plan_revision = identity.plan_revision
      ; given_input_sha = identity.input_sha
      ; given_owner = identity.owner
      }
  else
    match record.status with
    | Settled -> Skip_node_settled record
    | Attempting ->
        match record.effect_disposition with
        | Tool_result.Proven_pre_effect -> Redo_node_pre_effect record
        | Tool_result.Effect_outcome_unknown | Tool_result.Proven_post_effect ->
          Refuse_unknown_effect record
;;

(* 노드가 실제로 dispatch 되기 전에 부른다. 기존 레코드가 있으면 그 판정을,
   없으면 dispatch-전 효과 분류([pre_effect_disposition]: readonly 노드는
   [Proven_pre_effect], 효과 가능 노드는 [Effect_outcome_unknown])를 담은
   attempting 을 새로 남기고 Redo 를 돌려준다. *)
let begin_node
      ~dir
      ~request_id
      ~node_id
      ~pre_effect_disposition
      ~identity : (resume_decision, read_error) result =
  match read_record ~dir ~request_id ~node_id with
  | Error error -> Error error
  | Ok (Some record) -> Ok (resume_decision_of_record ~identity record)
  | Ok None -> (
      let record =
        { schema_version
        ; request_id
        ; node_id
        ; status = Attempting
        ; effect_disposition = pre_effect_disposition
        ; plan_revision = identity.plan_revision
        ; input_sha = identity.input_sha
        ; owner = identity.owner
        ; result_json = None
        ; updated_at_unix_s = Unix.gettimeofday ()
        }
      in
      match write_record ~dir record with
      | Ok () -> Ok (Redo_node_pre_effect record)
      | Error error -> Error (Corrupt_record ("write failed: " ^ error)))
;;

(* 효과가 실제로 발생한 뒤(결과 정산 전) 중단됐을 때, 저널의 원자적 상태만으로는
   효과 재발생을 배제할 수 없다. 이 경계의 유일한 정직한 재개는 목적지에서
   이미 적용된 효과를 읽어 증명하는 것이다. [prove_effect] 는 그 목적지
   readback: Some true 면 효과가 목적지에 존재하므로 attempting 기록을 settled
   로 승격하고(1회 확정) 재개 정산에 쓰라고 기록을 돌려준다. Some false·None
   (증명 실패)이면 기록을 그대로 둔다 — 재개는 Refuse 로 남고 조용한 재작성은
   없다. *)
let confirm_effect_via_readback
      ~dir
      ~request_id
      ~node_id
      ~identity
      ~prove_effect
      ~(result_json : Yojson.Safe.t option) =
  match read_record ~dir ~request_id ~node_id with
  | Error error -> Error error
  | Ok None -> Ok None
  | Ok (Some record) ->
    if not (identity_matches ~identity record) then
      Ok
        (Some
           (Identity_mismatch
              { stored_plan_revision = record.plan_revision
              ; stored_input_sha = record.input_sha
              ; stored_owner = record.owner
              ; given_plan_revision = identity.plan_revision
              ; given_input_sha = identity.input_sha
              ; given_owner = identity.owner
              }))
    else if (match record.status with Attempting -> false | Settled -> true) then Ok None
    else
      let proved = prove_effect () in
      match proved with
      | Some true -> (
          let record = { record with status = Settled; result_json } in
          match write_record ~dir record with
          | Ok () -> Ok (Some (Skip_node_settled record))
          | Error error -> Error (Corrupt_record ("readback promote failed: " ^ error)))
      | Some false | None -> Ok None
;;

(* 정산 후 settled 로 승격한다. disposition 은 실행기가 계산한 것으로
   갱신하고, Completed 결과는 저장해 재개 정산에 재사용한다. 정산 기록에
   실패하면 [Error] 를 돌려준다 — 실행기는 이 노드를 실패로 정산해
   재시도가 settled 아닌 잔여를 다시 보게 해야 하며, dispatch 는 이미
   일어났으므로 기록의 disposition 을 성공처럼 남기지 않는다. *)
let settle_node
      ~dir
      ~request_id
      ~node_id
      ~effect_disposition
      ?(result_json : Yojson.Safe.t option)
      ~identity () =
  let record =
    { schema_version
    ; request_id
    ; node_id
    ; status = Settled
    ; effect_disposition
    ; plan_revision = identity.plan_revision
    ; input_sha = identity.input_sha
    ; owner = identity.owner
    ; result_json
    ; updated_at_unix_s = Unix.gettimeofday ()
    }
  in
  write_record ~dir record
;;

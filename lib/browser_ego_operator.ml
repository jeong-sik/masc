module Input = Browser_ego_input
type recovery = {status:unit -> Input.status;busy:unit -> bool;assert_reset:generation:string -> (unit,string) result;
  space_observation:unit -> Browser_ego_space_observation.t option}
type connection = {client_id:string;space:Browser_lane.ego_space;recovery:recovery}
let schema = `Assoc ["type",`String "object";"properties",`Assoc [
  "action",`Assoc ["type",`String "string";"enum",`List [`String "view";`String "assert_input_reset"]];
  "arguments",`Assoc ["type",`String "object";"properties",`Assoc (List.map (fun key ->
    key,`Assoc ["type",`String "string"]) ["clientId";"spaceId";"generation";"confirmation"]);
    "additionalProperties",`Bool false]];
  "required",`List [`String "action";`String "arguments"];"additionalProperties",`Bool false]
let obj fields = `Assoc fields
let text value = `String value
type outcome = Observed | Asserted | Not_applied
let view ?(outcome=Observed) connection =
  let message,actions=match connection with
    | None -> "현재 이 작업자가 관리하는 Ego 연결이 없습니다.",[]
    | Some connection ->
      let where=Printf.sprintf "Ego Space #%d (%s)" connection.space.id connection.space.name in
      if connection.recovery.busy () then where ^ "에서 동작을 처리 중입니다. 결과를 확인한 뒤 다시 여세요.",[]
      else match connection.recovery.status () with
        | Input.Ready Input.Command_settled -> where ^ "에 입력 확인 요청이 없습니다.",[]
        | Ready (Operator_reset_asserted _) -> where ^ "의 입력 상태를 운영자가 확인·초기화했다고 기록했습니다. 원래 동작은 재실행하지 않습니다.",[]
        | Uncertain pending ->
          Printf.sprintf "%s의 탭 %d에서 입력 해제 여부가 불확실합니다. 해당 Space에서 키·버튼 상태를 직접 확인하고 필요한 초기화를 마친 경우에만 아래 버튼을 누르세요. 로그인 완료와는 별도입니다."
            where pending.tab_id,
          [obj ["id",text "assert_input_reset";"label",text "입력 상태 확인·초기화 완료";
            "arguments",obj ["clientId",text connection.client_id;"spaceId",text (string_of_int connection.space.id);
              "generation",text pending.generation;"confirmation",text "checked_and_reset"];
            "fields",`List []]] in
  let message=match connection with
    | None -> message
    | Some connection ->
      let observation=match connection.recovery.space_observation () with
        | None -> "SDK Space 상태 관측이 없습니다. 같은 연결에서 space_status로 조회할 수 있습니다."
        | Some observed when observed.space.id=connection.space.id -> Printf.sprintf "마지막 SDK 관측: Space #%d (%s), ownership=%s, observedAt=%.3f (Unix)."
            observed.space.id observed.space.name observed.ownership observed.observed_at
        | Some _ -> "현재 연결과 SDK Space 관측이 일치하지 않습니다." in
      message ^ "\n" ^ observation in
  let message=match outcome with Observed|Asserted -> message
    | Not_applied -> "확인을 적용하지 않았습니다. 현재 요청을 다시 확인하세요.\n" ^ message in
  obj ["title",text "Ego 입력 상태 확인";"message",text message;
    "actions",`List actions;"outcome",text (match outcome with
      | Observed -> "observed" | Asserted -> "operator_asserted" | Not_applied -> "not_applied")]
let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare names -> Ok fields
  | _ -> Error ()
open Result.Syntax
type request = View | Assert of {client_id:string;space_id:string;generation:string}
let parse json =
  let* fields=exact ["action";"arguments"] json in
  let value key fields=match List.assoc_opt key fields with Some (`String s) -> Ok s | None|Some _ -> Error () in
  let* action=value "action" fields in
  let* arguments=Option.to_result ~none:() (List.assoc_opt "arguments" fields) in
  match action with
  | "view" -> let* _=exact [] arguments in Ok View
  | "assert_input_reset" ->
    let* fields=exact ["clientId";"spaceId";"generation";"confirmation"] arguments in
    let* confirmation=value "confirmation" fields in
    if confirmation<>"checked_and_reset" then Error () else
    let* client_id=value "clientId" fields in let* space_id=value "spaceId" fields in
    let* generation=value "generation" fields in Ok (Assert {client_id;space_id;generation})
  | _ -> Error ()
let invoke connection json =
  let rejected ()=view ~outcome:Not_applied connection in
  match parse json,connection with
  | Ok View,_ -> view connection
  | Error (),_ | Ok (Assert _),None -> rejected ()
  | Ok (Assert request),Some current ->
    if request.client_id<>current.client_id || request.space_id<>string_of_int current.space.id
    then rejected () else
    match current.recovery.assert_reset ~generation:request.generation with
    | Error _ -> rejected ()
    | Ok () -> view ~outcome:Asserted connection

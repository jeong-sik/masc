type report =
  { recovered : int
  ; claimed : int
  ; completed : int
  ; failed : int
  }

type error =
  | Store_error of Keeper_memory_work_store.error
  | Concurrent_claim of string

let empty = { recovered = 0; claimed = 0; completed = 0; failed = 0 }
let ( let* ) = Result.bind

let error_to_string = function
  | Store_error error -> Keeper_memory_work_store.error_to_string error
  | Concurrent_claim request_id ->
    Printf.sprintf "Memory work already claimed by another owner: %s" request_id
;;

let store result = Result.map_error (fun error -> Store_error error) result

let next ~base_path ~keeper_name =
  let* recovered =
    Keeper_memory_work_store.recover_in_flight ~base_path ~keeper_name |> store
  in
  match recovered with
  | Some request -> Ok (Some (`Recovered, request))
  | None ->
    let* claimed =
      Keeper_memory_work_store.claim_next ~base_path ~keeper_name |> store
    in
    (match claimed with
     | Keeper_memory_work_store.Queue_empty -> Ok None
     | Keeper_memory_work_store.Claim_busy request_id ->
       Error (Concurrent_claim request_id)
     | Keeper_memory_work_store.Claimed request ->
       Ok (Some (`Claimed, request)))
;;

let execute_result execute request =
  try execute request with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn -> Error (Printexc.to_string exn)
;;

let rec loop ~base_path ~keeper_name ~execute report =
  let* next = next ~base_path ~keeper_name in
  match next with
  | None -> Ok report
  | Some (source, request) ->
    let request_id = Keeper_memory_work_request.request_id request in
    let execution = execute_result execute request in
    let outcome =
      match execution with
      | Ok () -> Keeper_memory_work_store.Completed
      | Error detail -> Keeper_memory_work_store.Failed detail
    in
    let* (_ : Keeper_memory_work_store.settle_result) =
      Keeper_memory_work_store.settle
        ~base_path
        ~keeper_name
        ~request_id
        outcome
      |> store
    in
    let report =
      { recovered = report.recovered + (match source with `Recovered -> 1 | `Claimed -> 0)
      ; claimed = report.claimed + (match source with `Recovered -> 0 | `Claimed -> 1)
      ; completed = report.completed + (match execution with Ok () -> 1 | Error _ -> 0)
      ; failed = report.failed + (match execution with Ok () -> 0 | Error _ -> 1)
      }
    in
    loop ~base_path ~keeper_name ~execute report
;;

let drain ~base_path ~keeper_name ~execute =
  loop ~base_path ~keeper_name ~execute empty
;;

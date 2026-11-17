open Masc
module Owner = Owner_under_test
open Result.Syntax
type error = Lane_addon_submit_once.error = Unavailable of string | Rejected of string | Uncertain of string
let io_count=ref 0
let io work=incr io_count;Systhread_host.run work
let rejected value=Result.map_error(fun detail -> Rejected detail)value
let owned value=Result.map_error(fun error -> Unavailable(Owner.error_to_string error))value
module Request = Request_after
let load_with_restore ~restore ~store (record,(index:Request.index)) =
  let* original=io (fun () -> Owner.load_listed ~store record) |> owned in
  let* request=io (fun () ->
    let* request=restore ~owner:index.owner original in
    (* [restore] bound the summary of the record it read to the body. That
       record was read after [discover]; its summary must be the same index. *)
    let* stored=Request.index_of_summary (Owner.listed original) in
    if stored=index then Ok request
    else Error "Original history index changed after its inventory was read") |> rejected in
  Ok (original,request)
let load ~store original = load_with_restore ~restore:Request.restore ~store original
let load_many ~store originals =
  let rec read sources found = function
    | [] -> Ok (List.rev found)
    | ((_,(index:Request.index)) as original)::rest ->
      let restore=match Set_util.StringMap.find_opt index.source_digest sources with
        | None -> Request.restore
        | Some previous -> Request.restore_reusing_source ~previous in
      let* retained,request=load_with_restore ~restore ~store original in
      let sources=Set_util.StringMap.add index.source_digest request sources in
      read sources ((retained,request)::found) rest in
  read Set_util.StringMap.empty [] originals

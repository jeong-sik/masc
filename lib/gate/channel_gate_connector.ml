(** Channel_gate_connector -- connector interface and registry.

    @since 2.260.0 *)

module type S = sig
  val connector_id : string
  val display_name : string
  val channel : string
  val status_json : ?audit_limit:int -> unit -> Yojson.Safe.t

  val connector_json
    :  ?gate_status_json:Yojson.Safe.t
    -> ?audit_limit:int
    -> unit
    -> Yojson.Safe.t

  val bind
    :  channel_id:string
    -> keeper_name:string
    -> actor_name:string
    -> (Yojson.Safe.t, string) result

  val unbind : channel_id:string -> actor_name:string -> (Yojson.Safe.t, string) result
end

module U = Yojson.Safe.Util

let registry : (string, (module S)) Hashtbl.t = Hashtbl.create 4
let register (module C : S) = Hashtbl.replace registry C.connector_id (module C : S)
let find name = Hashtbl.find_opt registry name
let all () = Hashtbl.fold (fun _k v acc -> v :: acc) registry []

let connectors_json ?gate_status_json ?(audit_limit = 10) () =
  let connectors = all () in
  let connector_jsons =
    List.map
      (fun (module C : S) -> C.connector_json ?gate_status_json ~audit_limit ())
      connectors
  in
  let active_count =
    List.fold_left
      (fun acc json ->
         if
           json |> U.member "available" |> U.to_bool_option |> Option.value ~default:false
         then acc + 1
         else acc)
      0
      connector_jsons
  in
  `Assoc
    [ "connectors", `List connector_jsons
    ; "total", `Int (List.length connectors)
    ; "active_count", `Int active_count
    ; "generated_at", `String (Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()))
    ]
;;

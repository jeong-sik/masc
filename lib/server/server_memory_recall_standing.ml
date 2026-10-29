module Standing = Keeper_memory_recall_standing

type keeper =
  { name : string
  ; standing : Standing.t
  }

type t =
  { lane : (unit, Standing.reason) result
  ; keepers : keeper list
  }

let lane () =
  match Typesafeai_config.lane_destinations () with
  | Ok (_ : Typesafeai_config.destinations) -> Ok ()
  | Error reason -> Error (Standing.lane_reason_of_unavailable reason)
;;

(* A file name that is not a Keeper name names no Keeper that can start, so it
   is not listed. A declaration whose [keeper.name] differs from its file name
   is not told apart here: that takes loading the file. *)
let is_keeper_name name = Result.is_ok (Keeper_id.Keeper_name.of_string name)

let read ~keepers_dir =
  Result.map
    (fun names ->
       { lane = lane ()
       ; keepers =
           List.map
             (fun name -> { name; standing = Standing.of_keeper ~keeper_id:name })
             (List.sort_uniq String.compare (List.filter is_keeper_name names))
       })
    (Server_runtime_startup_maintenance.declared_keeper_names ~keepers_dir)
;;

let lane_word = function
  | Ok () -> Standing.lane_armed_word
  | Error reason -> Standing.reason_to_string reason
;;

let standing_word = function
  | Standing.Judged -> Standing.judged_word
  | Standing.Not_judged reason -> Standing.reason_to_string reason
;;

let to_yojson ~generated_at t =
  `Assoc
    [ "generated_at", `String generated_at
    ; "lane", `String (lane_word t.lane)
    ; ( "keepers"
      , `List
          (List.map
             (fun keeper ->
                `Assoc
                  [ "name", `String keeper.name
                  ; "standing", `String (standing_word keeper.standing)
                  ])
             t.keepers) )
    ]
;;

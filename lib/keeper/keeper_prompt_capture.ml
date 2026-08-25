(** See [keeper_prompt_capture.mli]. *)

type block =
  { id : Prompt_block_id.t
  ; text : string
  }

type capture =
  { captured_at : float
  ; trace_id : string
  ; absolute_turn : int
  ; blocks : block list
  ; assembled : string option
  }

type read_error =
  | Unknown_keeper of string
  | Not_captured
  | Malformed of string

let read_error_to_string = function
  | Unknown_keeper keeper -> Printf.sprintf "invalid keeper name: %s" keeper
  | Not_captured -> "this keeper has not assembled a turn since prompt capture existed"
  | Malformed detail -> Printf.sprintf "capture could not be decoded: %s" detail
;;

let filename = "last-prompt.json"

(* The keeper's own directory, taken as the parent of a store already rooted
   there. Deriving it rather than rebuilding the path keeps one owner of where
   a keeper's files live. *)
let path_for config keeper =
  let keeper_dir =
    Filename.dirname (Keeper_types_support.keeper_raw_trace_dir config keeper)
  in
  Filename.concat keeper_dir filename
;;

let block_to_json (block : block) =
  `Assoc
    [ "id", `String (Prompt_block_id.to_string block.id)
    ; "bytes", `Int (String.length block.text)
    ; "text", `String block.text
    ]
;;

let to_json capture =
  `Assoc
    [ "captured_at", `Float capture.captured_at
    ; "trace_id", `String capture.trace_id
    ; "absolute_turn", `Int capture.absolute_turn
    ; "blocks", `List (List.map block_to_json capture.blocks)
    ; ( "assembled"
      , match capture.assembled with
        | None -> `Null
        | Some text -> `String text )
    ; ( "assembled_bytes"
      , `Int (match capture.assembled with None -> 0 | Some text -> String.length text) )
    ]
;;

let block_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "id" fields, List.assoc_opt "text" fields with
     | Some (`String id), Some (`String text) ->
       (match Prompt_block_id.of_string id with
        | Ok id -> Ok { id; text }
        | Error message -> Error message)
     | _ -> Error "block is missing id/text")
  | _ -> Error "block is not a JSON object"
;;

let capture_of_json = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "captured_at" fields
       , List.assoc_opt "trace_id" fields
       , List.assoc_opt "absolute_turn" fields
       , List.assoc_opt "blocks" fields )
     with
     | ( Some (`Float captured_at)
       , Some (`String trace_id)
       , Some (`Int absolute_turn)
       , Some (`List block_items) ) ->
       let rec decode acc = function
         | [] -> Ok (List.rev acc)
         | item :: rest ->
           (match block_of_json item with
            | Ok block -> decode (block :: acc) rest
            | Error message -> Error message)
       in
       (match decode [] block_items with
        | Error message -> Error message
        | Ok blocks ->
          let assembled =
            match List.assoc_opt "assembled" fields with
            | Some (`String text) -> Some text
            | Some `Null | None -> None
            | Some _ -> None
          in
          Ok { captured_at; trace_id; absolute_turn; blocks; assembled })
     | _ -> Error "capture is missing captured_at/trace_id/absolute_turn/blocks")
  | _ -> Error "capture is not a JSON object"
;;

(* The turn this describes is already proceeding. Losing its capture is an
   observation gap, not a reason to fail dispatch. Cancellation is never
   absorbed. *)
let write ~config ~keeper ~trace_id ~absolute_turn ~blocks ~assembled =
  let capture =
    { captured_at = Time_compat.now ()
    ; trace_id
    ; absolute_turn
    ; blocks = List.map (fun (id, text) -> { id; text }) blocks
    ; assembled
    }
  in
  let path = path_for config keeper in
  let warn detail =
    Log.Keeper.warn
      ~keeper_name:keeper
      "prompt capture write failed path=%s: %s"
      path
      detail
  in
  match
    (try
       (* The keeper directory exists on any keeper that has written a turn
          record, but a first turn can reach here before anything else has
          created it, and the atomic write needs somewhere to put its temp
          file. *)
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file_atomic path (Yojson.Safe.to_string (to_json capture))
     with
     | Eio.Cancel.Cancelled _ as error -> raise error
     | exn -> Error (Printexc.to_string exn))
  with
  | Ok () -> ()
  | Error detail -> warn detail
;;

let read ~config ~keeper =
  if not (Keeper_config.validate_name keeper)
  then Error (Unknown_keeper keeper)
  else (
    let path = path_for config keeper in
    match Fs_compat.load_file_opt path with
    | None -> Error Not_captured
    | Some contents ->
      (match Yojson.Safe.from_string contents with
       | json ->
         (match capture_of_json json with
          | Ok capture -> Ok capture
          | Error message -> Error (Malformed message))
       | exception Yojson.Json_error message -> Error (Malformed message)))
;;

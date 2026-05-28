type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Discord_api of { code : int; message : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Http_status { code; body } ->
      Format.fprintf fmt "http %d: %s" code body
  | Discord_api { code; message } ->
      Format.fprintf fmt "discord %d: %s" code message
  | Other msg -> Format.fprintf fmt "other: %s" msg

let send_message ~token:_ ~channel_id:_ ~content:_ =
  Error
    (Other
       "Discord_rest_client.send_message: not implemented (RFC-0203 Phase 2)")

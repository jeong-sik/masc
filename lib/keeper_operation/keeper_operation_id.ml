let lowercase_hex_length = 64

let validate_prefixed ~prefix value =
  let prefix_length = String.length prefix in
  let expected = prefix_length + lowercase_hex_length in
  if String.length value <> expected
  then
    Error
      (Printf.sprintf
         "%s identifier must be exactly %d bytes"
         prefix
         expected)
  else if not (String.equal (String.sub value 0 prefix_length) prefix)
  then Error (Printf.sprintf "identifier must begin with %s" prefix)
  else
    let rec loop index =
      if index = expected
      then Ok value
      else
        match String.unsafe_get value index with
        | '0' .. '9' | 'a' .. 'f' -> loop (index + 1)
        | found ->
          Error
            (Printf.sprintf
               "identifier has non-lowercase-hex byte %C at index %d"
               found
               index)
    in
    loop prefix_length
;;

let add_framed buffer value =
  Buffer.add_string buffer (string_of_int (String.length value));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer value
;;

let derive_hex ~domain parts =
  let buffer = Buffer.create 256 in
  add_framed buffer "masc.keeper.identity.v1";
  add_framed buffer domain;
  List.iter (add_framed buffer) parts;
  Digestif.SHA256.(digest_string (Buffer.contents buffer) |> to_hex)
;;

module Operation_id = struct
  type t = string

  let prefix = "kop1:"
  let generate () = prefix ^ Random_id.hex ~bytes:32
  let of_string value = validate_prefixed ~prefix value
  let to_string value = value
  let equal = String.equal

  let derived ~domain parts = prefix ^ derive_hex ~domain parts

  let for_event ~keeper_key ~event_identity =
    derived ~domain:"event" [ keeper_key; event_identity ]
  ;;

  let for_continuation ~parent ~continuation_ref =
    derived ~domain:"continuation" [ to_string parent; continuation_ref ]
  ;;

  let for_keeper_message ~causing_operation ~tool_call_id ~ordinal ~target_keeper =
    if String.length tool_call_id = 0
    then invalid_arg "Keeper message tool_call_id must not be empty";
    if ordinal < 0 then invalid_arg "Keeper message ordinal must be non-negative";
    derived
      ~domain:"keeper-message"
      [ to_string causing_operation; tool_call_id; string_of_int ordinal; target_keeper ]
  ;;

  let for_autonomous ~keeper_key ~candidate_identity =
    derived ~domain:"autonomous" [ keeper_key; candidate_identity ]
  ;;
end

module Delivery_id = struct
  type t = string

  let prefix = "kdel1:"
  let of_string value = validate_prefixed ~prefix value
  let to_string value = value
  let equal = String.equal

  let derive ~operation_id ~ordinal ~destination_ref ~payload_ref =
    if ordinal < 0 then invalid_arg "Delivery ordinal must be non-negative";
    prefix
    ^ derive_hex
        ~domain:"delivery"
        [ Operation_id.to_string operation_id
        ; string_of_int ordinal
        ; destination_ref
        ; payload_ref
        ]
  ;;
end

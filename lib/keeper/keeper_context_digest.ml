(** See [keeper_context_digest.mli]. *)

let text value = Digest.to_hex (Digest.string value)

let message_texts_as_joined messages =
  let module Hash = Digestif.MD5 in
  let rec loop ctx = function
    | [] -> ctx
    | [ message ] ->
      Hash.feed_string ctx (Agent_core.Types.text_of_message message)
    | message :: rest ->
      let ctx = Hash.feed_string ctx (Agent_core.Types.text_of_message message) in
      loop (Hash.feed_string ctx "\n") rest
  in
  Hash.(to_hex (get (loop empty messages)))
;;

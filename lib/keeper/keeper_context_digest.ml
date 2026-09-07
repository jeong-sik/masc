(** See [keeper_context_digest.mli]. *)

let text value = Digest.to_hex (Digest.string value)

let compute_message_texts_as_joined messages =
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

let message_texts_as_joined messages =
  match messages with
  | [] -> compute_message_texts_as_joined []
  | _ :: _ ->
    (* Message text extraction and hashing are pure. Keep both off the main
       domain; only the completed digest returns to the manifest/capture writer. *)
    Executor_pool_ref.submit_or_inline (fun () ->
      compute_message_texts_as_joined messages)
;;

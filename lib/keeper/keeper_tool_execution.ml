type t =
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; metadata : Yojson.Safe.t option
  ; disposition :
      (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition
  }

let success raw_output =
  { raw_output; data = None; metadata = None; disposition = Tool_result.Completed () }
;;

let success_data ?metadata data =
  { raw_output = Yojson.Safe.to_string data
  ; data = Some data
  ; metadata
  ; disposition = Tool_result.Completed ()
  }
;;

let deferred_data ?metadata data =
  { raw_output = Yojson.Safe.to_string data
  ; data = Some data
  ; metadata
  ; disposition = Tool_result.Deferred ()
  }
;;

let failure ?(class_ = Tool_result.Runtime_failure) raw_output =
  { raw_output; data = None; metadata = None; disposition = Tool_result.Failed class_ }
;;

let failure_data ~class_ ~message data =
  { raw_output = message
  ; data = Some data
  ; metadata = None
  ; disposition = Tool_result.Failed class_
  }
;;

let of_tool_result (result : Tool_result.result) =
  let raw_output = Tool_result.message result in
  let data = Some (Tool_result.data result) in
  match result with
  | Tool_result.Completed { metadata; _ } ->
    { raw_output; data; metadata; disposition = Tool_result.Completed () }
  | Tool_result.Deferred { metadata; _ } ->
    { raw_output; data; metadata; disposition = Tool_result.Deferred () }
  | Tool_result.Failed { class_; _ } ->
    { raw_output; data; metadata = None; disposition = Tool_result.Failed class_ }
;;

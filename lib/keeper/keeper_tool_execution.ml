type outcome =
  | Succeeded
  | Failed of Tool_result.tool_failure_class

type t =
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; outcome : outcome
  }

let success raw_output = { raw_output; data = None; outcome = Succeeded }

let success_data data =
  { raw_output = Yojson.Safe.to_string data; data = Some data; outcome = Succeeded }
;;

let failure ?(class_ = Tool_result.Runtime_failure) raw_output =
  { raw_output; data = None; outcome = Failed class_ }
;;

let failure_data
      ~class_
      ~message
      data
  =
  { raw_output = message; data = Some data; outcome = Failed class_ }
;;

let of_tool_result (result : Tool_result.result) =
  let data = Some (Tool_result.data result) in
  let raw_output = Tool_result.message result in
  match result with
  | Ok _ -> { raw_output; data; outcome = Succeeded }
  | Error { class_; _ } -> { raw_output; data; outcome = Failed class_ }
;;

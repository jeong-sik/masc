(** Gemini URL construction.

    Extracted from {!Complete} to keep the main completion module
    focused on request/response lifecycle.  Sampling values are caller-owned;
    this module does not inject provider-wide defaults.

    @since 0.205.9 *)

(** Construct the URL for a Gemini API call.
    Sync: [base_url/models/model_id:generateContent]
    Stream: [base_url/models/model_id:streamGenerateContent?alt=sse]

    The API key is never included in the URL.  Callers must add it to the
    [x-goog-api-key] header via {!Provider_config.auth_headers_for_config}. *)
let gemini_url ~(config : Provider_config.t) ~stream =
  let method_name = if stream then "streamGenerateContent" else "generateContent" in
  let base =
    Printf.sprintf "%s/models/%s:%s" config.base_url config.model_id method_name
  in
  if stream then base ^ "?alt=sse" else base
;;

(* --- gemini_url tests ---

   [gemini_url] reads [base_url] and [model_id] only, so each test takes the
   rest of its config from [Provider_config.make]. *)

let%test "gemini_url sync no api_key" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:"https://gen.googleapis.com/v1beta"
      ()
  in
  gemini_url ~config ~stream:false
  = "https://gen.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent"
;;

let%test "gemini_url sync with api_key" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:"mykey"
      ()
  in
  gemini_url ~config ~stream:false
  = "https://gen.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent"
;;

let%test "gemini_url stream with api_key" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:"mykey"
      ()
  in
  gemini_url ~config ~stream:true
  = "https://gen.googleapis.com/v1beta/models/gemini-3.7-flash:streamGenerateContent?alt=sse"
;;

let%test "gemini_url stream no api_key" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:"https://gen.googleapis.com/v1beta"
      ()
  in
  gemini_url ~config ~stream:true
  = "https://gen.googleapis.com/v1beta/models/gemini-3.7-flash:streamGenerateContent?alt=sse"
;;

let%test "gemini_url never leaks api_key even when set" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:"https://gen.googleapis.com/v1beta"
      ~api_key:"mykey"
      ()
  in
  let leaks url =
    Agent_core_strings.contains_substring ~haystack:url ~needle:"mykey"
  in
  (not (leaks (gemini_url ~config ~stream:false)))
  && not (leaks (gemini_url ~config ~stream:true))
;;

let%test "gemini_url empty base_url no trailing slash" =
  let config =
    Provider_config.make
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3.7-flash"
      ~base_url:""
      ()
  in
  gemini_url ~config ~stream:false = "/models/gemini-3.7-flash:generateContent"
;;

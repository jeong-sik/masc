(** MASC gRPC Server.

    Runs the gRPC workspace service on a separate port (default 8936).
    Configurable via MASC_GRPC_PORT environment variable.

    The server runs in a forked Eio fiber alongside the HTTP/SSE server.
    It uses grpc-direct's Eio-native implementation for h2c (HTTP/2 cleartext). *)

(** SSOT: [Env_config.Transport.grpc_port]. *)
let default_port = Env_config.Transport.grpc_port

let health_service_name = "grpc.health.v1.Health"

(** Read the configured gRPC port from environment or use default. *)
let configured_port () = Env_config.Transport.grpc_port

(** Check whether gRPC is enabled (default: enabled, opt-out via env). *)
let is_enabled () = Env_config.Transport.grpc_enabled ()

let parse_lsp_jsonrpc_request jsonrpc_request_json =
  try
    match Yojson.Safe.from_string jsonrpc_request_json with
    | `Assoc fields ->
      (match List.assoc_opt "method" fields with
       | Some (`String method_) ->
         let params =
           match List.assoc_opt "params" fields with
           | Some value -> value
           | None -> `Null
         in
         Ok (method_, params)
       | Some _ -> Error "JSON-RPC request method field must be a string"
       | None -> Error "JSON-RPC request missing method field")
    | _ -> Error "JSON-RPC request must be a JSON object"
  with
  | Yojson.Json_error msg -> Error (Printf.sprintf "JSON-RPC parse error: %s" msg)
;;

module For_testing = struct
  let parse_lsp_jsonrpc_request = parse_lsp_jsonrpc_request
end

module Reflection_bridge = struct
  let reflection_v1_service_name = "grpc.reflection.v1.ServerReflection"
  let reflection_v1alpha_service_name = "grpc.reflection.v1alpha.ServerReflection"

  type request =
    | ListServices
    | FileContainingSymbol of string
    | FileByFilename of string
    | Unknown

  module Wire = struct
    let req_file_by_filename = 3
    let req_file_containing_symbol = 4
    let req_list_services = 7
    let resp_original_request = 2
    let resp_file_descriptor_response = 4
    let resp_list_services_response = 6
    let resp_error_response = 7
    let list_service_service = 1
    let service_name = 1
    let error_code = 1
    let error_message = 2
    let file_descriptor_proto = 1
  end

  let grpc_health_descriptor_b64 =
    "ChtncnBjL2hlYWx0aC92MS9oZWFsdGgucHJvdG8SDmdycGMuaGVhbHRoLnYxIi4KEkhlYWx0aENoZWNrUmVxdWVzdBIYCgdzZXJ2aWNlGAEgASgJUgdzZXJ2aWNlIrEBChNIZWFsdGhDaGVja1Jlc3BvbnNlEkkKBnN0YXR1cxgBIAEoDjIxLmdycGMuaGVhbHRoLnYxLkhlYWx0aENoZWNrUmVzcG9uc2UuU2VydmluZ1N0YXR1c1IGc3RhdHVzIk8KDVNlcnZpbmdTdGF0dXMSCwoHVU5LTk9XThAAEgsKB1NFUlZJTkcQARIPCgtOT1RfU0VSVklORxACEhMKD1NFUlZJQ0VfVU5LTk9XThADMq4BCgZIZWFsdGgSUAoFQ2hlY2sSIi5ncnBjLmhlYWx0aC52MS5IZWFsdGhDaGVja1JlcXVlc3QaIy5ncnBjLmhlYWx0aC52MS5IZWFsdGhDaGVja1Jlc3BvbnNlElIKBVdhdGNoEiIuZ3JwYy5oZWFsdGgudjEuSGVhbHRoQ2hlY2tSZXF1ZXN0GiMuZ3JwYy5oZWFsdGgudjEuSGVhbHRoQ2hlY2tSZXNwb25zZTABYgZwcm90bzM="
  ;;

  let grpc_reflection_descriptor_b64 =
    "CiNncnBjL3JlZmxlY3Rpb24vdjEvcmVmbGVjdGlvbi5wcm90bxISZ3JwYy5yZWZsZWN0aW9uLnYxIvMCChdTZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBISCgRob3N0GAEgASgJUgRob3N0EioKEGZpbGVfYnlfZmlsZW5hbWUYAyABKAlIAFIOZmlsZUJ5RmlsZW5hbWUSNgoWZmlsZV9jb250YWluaW5nX3N5bWJvbBgEIAEoCUgAUhRmaWxlQ29udGFpbmluZ1N5bWJvbBJiChlmaWxlX2NvbnRhaW5pbmdfZXh0ZW5zaW9uGAUgASgLMiQuZ3JwYy5yZWZsZWN0aW9uLnYxLkV4dGVuc2lvblJlcXVlc3RIAFIXZmlsZUNvbnRhaW5pbmdFeHRlbnNpb24SQgodYWxsX2V4dGVuc2lvbl9udW1iZXJzX29mX3R5cGUYBiABKAlIAFIZYWxsRXh0ZW5zaW9uTnVtYmVyc09mVHlwZRIlCg1saXN0X3NlcnZpY2VzGAcgASgJSABSDGxpc3RTZXJ2aWNlc0IRCg9tZXNzYWdlX3JlcXVlc3QiZgoQRXh0ZW5zaW9uUmVxdWVzdBInCg9jb250YWluaW5nX3R5cGUYASABKAlSDmNvbnRhaW5pbmdUeXBlEikKEGV4dGVuc2lvbl9udW1iZXIYAiABKAVSD2V4dGVuc2lvbk51bWJlciKuBAoYU2VydmVyUmVmbGVjdGlvblJlc3BvbnNlEh0KCnZhbGlkX2hvc3QYASABKAlSCXZhbGlkSG9zdBJWChBvcmlnaW5hbF9yZXF1ZXN0GAIgASgLMisuZ3JwYy5yZWZsZWN0aW9uLnYxLlNlcnZlclJlZmxlY3Rpb25SZXF1ZXN0Ug9vcmlnaW5hbFJlcXVlc3QSZgoYZmlsZV9kZXNjcmlwdG9yX3Jlc3BvbnNlGAQgASgLMiouZ3JwYy5yZWZsZWN0aW9uLnYxLkZpbGVEZXNjcmlwdG9yUmVzcG9uc2VIAFIWZmlsZURlc2NyaXB0b3JSZXNwb25zZRJyCh5hbGxfZXh0ZW5zaW9uX251bWJlcnNfcmVzcG9uc2UYBSABKAsyKy5ncnBjLnJlZmxlY3Rpb24udjEuRXh0ZW5zaW9uTnVtYmVyUmVzcG9uc2VIAFIbYWxsRXh0ZW5zaW9uTnVtYmVyc1Jlc3BvbnNlEl8KFmxpc3Rfc2VydmljZXNfcmVzcG9uc2UYBiABKAsyJy5ncnBjLnJlZmxlY3Rpb24udjEuTGlzdFNlcnZpY2VSZXNwb25zZUgAUhRsaXN0U2VydmljZXNSZXNwb25zZRJKCg5lcnJvcl9yZXNwb25zZRgHIAEoCzIhLmdycGMucmVmbGVjdGlvbi52MS5FcnJvclJlc3BvbnNlSABSDWVycm9yUmVzcG9uc2VCEgoQbWVzc2FnZV9yZXNwb25zZSJMChZGaWxlRGVzY3JpcHRvclJlc3BvbnNlEjIKFWZpbGVfZGVzY3JpcHRvcl9wcm90bxgBIAMoDFITZmlsZURlc2NyaXB0b3JQcm90byJqChdFeHRlbnNpb25OdW1iZXJSZXNwb25zZRIkCg5iYXNlX3R5cGVfbmFtZRgBIAEoCVIMYmFzZVR5cGVOYW1lEikKEGV4dGVuc2lvbl9udW1iZXIYAiADKAVSD2V4dGVuc2lvbk51bWJlciJUChNMaXN0U2VydmljZVJlc3BvbnNlEj0KB3NlcnZpY2UYASADKAsyIy5ncnBjLnJlZmxlY3Rpb24udjEuU2VydmljZVJlc3BvbnNlUgdzZXJ2aWNlIiUKD1NlcnZpY2VSZXNwb25zZRISCgRuYW1lGAEgASgJUgRuYW1lIlMKDUVycm9yUmVzcG9uc2USHQoKZXJyb3JfY29kZRgBIAEoBVIJZXJyb3JDb2RlEiMKDWVycm9yX21lc3NhZ2UYAiABKAlSDGVycm9yTWVzc2FnZTKJAQoQU2VydmVyUmVmbGVjdGlvbhJ1ChRTZXJ2ZXJSZWZsZWN0aW9uSW5mbxIrLmdycGMucmVmbGVjdGlvbi52MS5TZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBosLmdycGMucmVmbGVjdGlvbi52MS5TZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2UoATABYgZwcm90bzM="
  ;;

  let grpc_reflection_v1alpha_descriptor_b64 =
    "ChhyZWZsZWN0aW9uX3YxYWxwaGEucHJvdG8SF2dycGMucmVmbGVjdGlvbi52MWFscGhhIvgCChdTZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBISCgRob3N0GAEgASgJUgRob3N0EioKEGZpbGVfYnlfZmlsZW5hbWUYAyABKAlIAFIOZmlsZUJ5RmlsZW5hbWUSNgoWZmlsZV9jb250YWluaW5nX3N5bWJvbBgEIAEoCUgAUhRmaWxlQ29udGFpbmluZ1N5bWJvbBJnChlmaWxlX2NvbnRhaW5pbmdfZXh0ZW5zaW9uGAUgASgLMikuZ3JwYy5yZWZsZWN0aW9uLnYxYWxwaGEuRXh0ZW5zaW9uUmVxdWVzdEgAUhdmaWxlQ29udGFpbmluZ0V4dGVuc2lvbhJCCh1hbGxfZXh0ZW5zaW9uX251bWJlcnNfb2ZfdHlwZRgGIAEoCUgAUhlhbGxFeHRlbnNpb25OdW1iZXJzT2ZUeXBlEiUKDWxpc3Rfc2VydmljZXMYByABKAlIAFIMbGlzdFNlcnZpY2VzQhEKD21lc3NhZ2VfcmVxdWVzdCJmChBFeHRlbnNpb25SZXF1ZXN0EicKD2NvbnRhaW5pbmdfdHlwZRgBIAEoCVIOY29udGFpbmluZ1R5cGUSKQoQZXh0ZW5zaW9uX251bWJlchgCIAEoBVIPZXh0ZW5zaW9uTnVtYmVyIscEChhTZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2USHQoKdmFsaWRfaG9zdBgBIAEoCVIJdmFsaWRIb3N0ElsKEG9yaWdpbmFsX3JlcXVlc3QYAiABKAsyMC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdFIPb3JpZ2luYWxSZXF1ZXN0EmsKGGZpbGVfZGVzY3JpcHRvcl9yZXNwb25zZRgEIAEoCzIvLmdycGMucmVmbGVjdGlvbi52MWFscGhhLkZpbGVEZXNjcmlwdG9yUmVzcG9uc2VIAFIWZmlsZURlc2NyaXB0b3JSZXNwb25zZRJ3Ch5hbGxfZXh0ZW5zaW9uX251bWJlcnNfcmVzcG9uc2UYBSABKAsyMC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5FeHRlbnNpb25OdW1iZXJSZXNwb25zZUgAUhthbGxFeHRlbnNpb25OdW1iZXJzUmVzcG9uc2USZAoWbGlzdF9zZXJ2aWNlc19yZXNwb25zZRgGIAEoCzIsLmdycGMucmVmbGVjdGlvbi52MWFscGhhLkxpc3RTZXJ2aWNlUmVzcG9uc2VIAFIUbGlzdFNlcnZpY2VzUmVzcG9uc2USTwoOZXJyb3JfcmVzcG9uc2UYByABKAsyJi5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5FcnJvclJlc3BvbnNlSABSDWVycm9yUmVzcG9uc2VCEgoQbWVzc2FnZV9yZXNwb25zZSJMChZGaWxlRGVzY3JpcHRvclJlc3BvbnNlEjIKFWZpbGVfZGVzY3JpcHRvcl9wcm90bxgBIAMoDFITZmlsZURlc2NyaXB0b3JQcm90byJqChdFeHRlbnNpb25OdW1iZXJSZXNwb25zZRIkCg5iYXNlX3R5cGVfbmFtZRgBIAEoCVIMYmFzZVR5cGVOYW1lEikKEGV4dGVuc2lvbl9udW1iZXIYAiADKAVSD2V4dGVuc2lvbk51bWJlciJZChNMaXN0U2VydmljZVJlc3BvbnNlEkIKB3NlcnZpY2UYASADKAsyKC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2aWNlUmVzcG9uc2VSB3NlcnZpY2UiJQoPU2VydmljZVJlc3BvbnNlEhIKBG5hbWUYASABKAlSBG5hbWUiUwoNRXJyb3JSZXNwb25zZRIdCgplcnJvcl9jb2RlGAEgASgFUgllcnJvckNvZGUSIwoNZXJyb3JfbWVzc2FnZRgCIAEoCVIMZXJyb3JNZXNzYWdlMpMBChBTZXJ2ZXJSZWZsZWN0aW9uEn8KFFNlcnZlclJlZmxlY3Rpb25JbmZvEjAuZ3JwYy5yZWZsZWN0aW9uLnYxYWxwaGEuU2VydmVyUmVmbGVjdGlvblJlcXVlc3QaMS5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2UoATABYgZwcm90bzM="
  ;;

  let grpc_masc_descriptor_b64 =
    String.concat ""
      [ "ChRtYXNjX3dvcmtzcGFjZS5wcm90bxIRbWFzYy53b3Jrc3BhY2UudjEimAEKDUhlYXJ0YmVhdFBpbmcSHQoKYWdlbnRfbmFtZRgB"
      ; "IAEoCVIJYWdlbnROYW1lEh0KCnNlc3Npb25faWQYAiABKAlSCXNlc3Npb25JZBIhCgx0aW1lc3RhbXBfbXMYAyABKANSC3RpbWVz"
      ; "dGFtcE1zEiYKD2N1cnJlbnRfdGFza19pZBgEIAEoCVINY3VycmVudFRhc2tJZCKtAQoMSGVhcnRiZWF0QWNrEiEKDHRpbWVzdGFt"
      ; "cF9tcxgBIAEoA1ILdGltZXN0YW1wTXMSLAoSYWN0aXZlX2FnZW50X2NvdW50GAIgASgFUhBhY3RpdmVBZ2VudENvdW50EiwKEnBl"
      ; "bmRpbmdfdGFza19jb3VudBgDIAEoBVIQcGVuZGluZ1Rhc2tDb3VudBIeCgpkaXJlY3RpdmVzGAQgAygJUgpkaXJlY3RpdmVzIo4B"
      ; "ChBTdWJzY3JpYmVSZXF1ZXN0Eh0KCmFnZW50X25hbWUYASABKAlSCWFnZW50TmFtZRIdCgpzZXNzaW9uX2lkGAIgASgJUglzZXNz"
      ; "aW9uSWQSHwoLZXZlbnRfdHlwZXMYAyADKAlSCmV2ZW50VHlwZXMSGwoJc2luY2Vfc2VxGAQgASgDUghzaW5jZVNlcSKhAQoFRXZl"
      ; "bnQSEAoDc2VxGAEgASgDUgNzZXESHQoKZXZlbnRfdHlwZRgCIAEoCVIJZXZlbnRUeXBlEiEKDHNvdXJjZV9hZ2VudBgDIAEoCVIL"
      ; "c291cmNlQWdlbnQSIQoMdGltZXN0YW1wX21zGAQgASgDUgt0aW1lc3RhbXBNcxIhCgxwYXlsb2FkX2pzb24YBSABKAlSC3BheWxv"
      ; "YWRKc29uIpMBCg9Ub29sQ2FsbFJlcXVlc3QSHQoKYWdlbnRfbmFtZRgBIAEoCVIJYWdlbnROYW1lEh0KCnNlc3Npb25faWQYAiAB"
      ; "KAlSCXNlc3Npb25JZBIbCgl0b29sX25hbWUYAyABKAlSCHRvb2xOYW1lEiUKDmFyZ3VtZW50c19qc29uGAQgASgJUg1hcmd1bWVu"
      ; "dHNKc29uIpEBChBUb29sQ2FsbFJlc3BvbnNlEhgKB3N1Y2Nlc3MYASABKAhSB3N1Y2Nlc3MSHwoLcmVzdWx0X2pzb24YAiABKAlS"
      ; "CnJlc3VsdEpzb24SIwoNZXJyb3JfbWVzc2FnZRgDIAEoCVIMZXJyb3JNZXNzYWdlEh0KCmVycm9yX2NvZGUYBCABKAVSCWVycm9y"
      ; "Q29kZSJnChBCcm9hZGNhc3RSZXF1ZXN0Eh0KCmFnZW50X25hbWUYASABKAlSCWFnZW50TmFtZRIYCgdtZXNzYWdlGAIgASgJUgdt"
      ; "ZXNzYWdlEhoKCG1lbnRpb25zGAMgAygJUghtZW50aW9ucyI/ChFCcm9hZGNhc3RSZXNwb25zZRIYCgdzdWNjZXNzGAEgASgIUgdz"
      ; "dWNjZXNzEhAKA3NlcRgCIAEoA1IDc2VxIg8KDVN0YXR1c1JlcXVlc3QixQEKDlN0YXR1c1Jlc3BvbnNlEjQKBmFnZW50cxgBIAMo"
      ; "CzIcLm1hc2Mud29ya3NwYWNlLnYxLkFnZW50SW5mb1IGYWdlbnRzEjEKBXRhc2tzGAIgAygLMhsubWFzYy53b3Jrc3BhY2UudjEu"
      ; "VGFza0luZm9SBXRhc2tzEiMKDW1lc3NhZ2VfY291bnQYAyABKAVSDG1lc3NhZ2VDb3VudBIlCg53b3Jrc3BhY2VfcGF0aBgEIAEo"
      ; "CVINd29ya3NwYWNlUGF0aCLeAQoJQWdlbnRJbmZvEhIKBG5hbWUYASABKAlSBG5hbWUSFgoGc3RhdHVzGAIgASgJUgZzdGF0dXMS"
      ; "IgoMY2FwYWJpbGl0aWVzGAMgAygJUgxjYXBhYmlsaXRpZXMSKgoRbGFzdF9oZWFydGJlYXRfbXMYBCABKANSD2xhc3RIZWFydGJl"
      ; "YXRNcxItChNzZXNzaW9uX2JvdW5kX2F0X21zGAUgASgDUhBzZXNzaW9uQm91bmRBdE1zEiYKD2N1cnJlbnRfdGFza19pZBgGIAEo"
      ; "CVINY3VycmVudFRhc2tJZCKFAQoIVGFza0luZm8SDgoCaWQYASABKAlSAmlkEhQKBXRpdGxlGAIgASgJUgV0aXRsZRIWCgZzdGF0"
      ; "dXMYAyABKAlSBnN0YXR1cxIfCgthc3NpZ25lZF90bxgEIAEoCVIKYXNzaWduZWRUbxIaCghwcmlvcml0eRgFIAEoBVIIcHJpb3Jp"
      ; "dHkihgEKCkxzcFJlcXVlc3QSHwoLbGFuZ3VhZ2VfaWQYASABKAlSCmxhbmd1YWdlSWQSMAoUanNvbnJwY19yZXF1ZXN0X2pzb24Y"
      ; "AiABKAlSEmpzb25ycGNSZXF1ZXN0SnNvbhIlCg53b3Jrc3BhY2Vfcm9vdBgDIAEoCVINd29ya3NwYWNlUm9vdCJmCgtMc3BSZXNw"
      ; "b25zZRIyChVqc29ucnBjX3Jlc3BvbnNlX2pzb24YASABKAlSE2pzb25ycGNSZXNwb25zZUpzb24SIwoNZXJyb3JfbWVzc2FnZRgC"
      ; "IAEoCVIMZXJyb3JNZXNzYWdlMvoDCg1NYXNjV29ya3NwYWNlElIKCUhlYXJ0YmVhdBIgLm1hc2Mud29ya3NwYWNlLnYxLkhlYXJ0"
      ; "YmVhdFBpbmcaHy5tYXNjLndvcmtzcGFjZS52MS5IZWFydGJlYXRBY2soATABEkwKCVN1YnNjcmliZRIjLm1hc2Mud29ya3NwYWNl"
      ; "LnYxLlN1YnNjcmliZVJlcXVlc3QaGC5tYXNjLndvcmtzcGFjZS52MS5FdmVudDABElMKCFRvb2xDYWxsEiIubWFzYy53b3Jrc3Bh"
      ; "Y2UudjEuVG9vbENhbGxSZXF1ZXN0GiMubWFzYy53b3Jrc3BhY2UudjEuVG9vbENhbGxSZXNwb25zZRJWCglCcm9hZGNhc3QSIy5t"
      ; "YXNjLndvcmtzcGFjZS52MS5Ccm9hZGNhc3RSZXF1ZXN0GiQubWFzYy53b3Jrc3BhY2UudjEuQnJvYWRjYXN0UmVzcG9uc2USUAoJ"
      ; "R2V0U3RhdHVzEiAubWFzYy53b3Jrc3BhY2UudjEuU3RhdHVzUmVxdWVzdBohLm1hc2Mud29ya3NwYWNlLnYxLlN0YXR1c1Jlc3Bv"
      ; "bnNlEkgKB0xzcENhbGwSHS5tYXNjLndvcmtzcGFjZS52MS5Mc3BSZXF1ZXN0Gh4ubWFzYy53b3Jrc3BhY2UudjEuTHNwUmVzcG9u"
      ; "c2ViBnByb3RvMw=="
      ]
  ;;

  let grpc_health_descriptor = Base64.decode_exn grpc_health_descriptor_b64
  let grpc_reflection_descriptor = Base64.decode_exn grpc_reflection_descriptor_b64

  let grpc_reflection_v1alpha_descriptor =
    Base64.decode_exn grpc_reflection_v1alpha_descriptor_b64
  ;;

  let grpc_masc_descriptor = Base64.decode_exn grpc_masc_descriptor_b64

  let health_proto_filenames =
    [ "grpc/health/v1/health.proto"; "grpc-health.proto"; "health.proto" ]
  ;;

  let reflection_proto_filenames =
    [ "grpc/reflection/v1/reflection.proto"
    ; "grpc_reflection_v1.proto"
    ; "reflection.proto"
    ]
  ;;

  let reflection_v1alpha_proto_filenames =
    [ "reflection_v1alpha.proto"; "grpc/reflection/v1alpha/reflection.proto" ]
  ;;

  let masc_proto_filenames = [ "masc_workspace.proto" ]

  let health_symbols =
    [ "grpc.health.v1.Health"
    ; "grpc.health.v1.Health.Check"
    ; "grpc.health.v1.Health.Watch"
    ; "grpc.health.v1.HealthCheckRequest"
    ; "grpc.health.v1.HealthCheckResponse"
    ; "grpc.health.v1.HealthCheckResponse.ServingStatus"
    ]
  ;;

  let reflection_symbols =
    [ reflection_v1_service_name
    ; reflection_v1_service_name ^ ".ServerReflectionInfo"
    ; "grpc.reflection.v1.ServerReflectionRequest"
    ; "grpc.reflection.v1.ServerReflectionResponse"
    ; "grpc.reflection.v1.FileDescriptorResponse"
    ; "grpc.reflection.v1.ListServiceResponse"
    ; "grpc.reflection.v1.ServiceResponse"
    ; "grpc.reflection.v1.ErrorResponse"
    ; "grpc.reflection.v1.ExtensionRequest"
    ; "grpc.reflection.v1.ExtensionNumberResponse"
    ]
  ;;

  let reflection_v1alpha_symbols =
    [ reflection_v1alpha_service_name
    ; reflection_v1alpha_service_name ^ ".ServerReflectionInfo"
    ; "grpc.reflection.v1alpha.ServerReflectionRequest"
    ; "grpc.reflection.v1alpha.ServerReflectionResponse"
    ; "grpc.reflection.v1alpha.FileDescriptorResponse"
    ; "grpc.reflection.v1alpha.ListServiceResponse"
    ; "grpc.reflection.v1alpha.ServiceResponse"
    ; "grpc.reflection.v1alpha.ErrorResponse"
    ; "grpc.reflection.v1alpha.ExtensionRequest"
    ; "grpc.reflection.v1alpha.ExtensionNumberResponse"
    ]
  ;;

  let masc_symbols = [ Masc_grpc_service.service_name ]
  let has_prefix ~prefix value = String.starts_with ~prefix value

  let decode_varint (bytes : string) (pos : int ref) : int =
    let result = ref 0 in
    let shift = ref 0 in
    let done_ = ref false in
    while !pos < String.length bytes && not !done_ do
      let byte = Char.code bytes.[!pos] in
      if !shift >= Sys.int_size then invalid_arg "reflection varint overflow";
      incr pos;
      result := !result lor ((byte land 0x7f) lsl !shift);
      shift := !shift + 7;
      if byte land 0x80 = 0 then done_ := true
    done;
    if not !done_ then invalid_arg "reflection truncated varint";
    !result
  ;;

  let encode_varint (n : int) : string =
    if n < 0
    then invalid_arg "reflection negative varint"
    else if n = 0
    then "\x00"
    else (
      let buf = Buffer.create 10 in
      let n = ref n in
      while !n > 0 do
        let byte = !n land 0x7f in
        n := !n lsr 7;
        if !n > 0
        then Buffer.add_char buf (Char.chr (byte lor 0x80))
        else Buffer.add_char buf (Char.chr byte)
      done;
      Buffer.contents buf)
  ;;

  let encode_length_delimited (field_num : int) (data : string) : string =
    let tag = (field_num lsl 3) lor 2 in
    encode_varint tag ^ encode_varint (String.length data) ^ data
  ;;

  let encode_string_field (field_num : int) (s : string) : string =
    encode_length_delimited field_num s
  ;;

  let parse_request (data : string) : request =
    if String.length data = 0
    then Unknown
    else (
      let pos = ref 0 in
      let result = ref Unknown in
      while !pos < String.length data do
        let tag = decode_varint data pos in
        let field_num = tag lsr 3 in
        let wire_type = tag land 7 in
        match wire_type with
        | 2 ->
          let len = decode_varint data pos in
          if !pos + len > String.length data
          then invalid_arg "reflection truncated length-delimited field";
          let value = String.sub data !pos len in
          pos := !pos + len;
          (match field_num with
           | n when n = Wire.req_file_by_filename -> result := FileByFilename value
           | n when n = Wire.req_file_containing_symbol ->
             result := FileContainingSymbol value
           | n when n = Wire.req_list_services -> result := ListServices
           | _ ->
             Log.Server.warn "masc_grpc_server: unknown reflection field_num %d" field_num)
        | 0 ->
          let _ = decode_varint data pos in
          ()
        | 1 ->
          if !pos + 8 > String.length data
          then invalid_arg "reflection truncated fixed64 field";
          pos := !pos + 8
        | _ ->
          if wire_type = 5
          then (
            if !pos + 4 > String.length data
            then invalid_arg "reflection truncated fixed32 field";
            pos := !pos + 4)
          else pos := String.length data
      done;
      !result)
  ;;

  let encode_list_services_response (services : string list) : string =
    let buf = Buffer.create 256 in
    List.iter
      (fun name ->
         let msg = encode_string_field Wire.service_name name in
         Buffer.add_string buf (encode_length_delimited Wire.list_service_service msg))
      services;
    let list_response = Buffer.contents buf in
    encode_length_delimited Wire.resp_list_services_response list_response
  ;;

  let with_original_request ~(request : string) (payload : string) : string =
    encode_length_delimited Wire.resp_original_request request ^ payload
  ;;

  let encode_error_response (code : int) (message : string) : string =
    let error_msg =
      encode_varint ((Wire.error_code lsl 3) lor 0)
      ^ encode_varint code
      ^ encode_string_field Wire.error_message message
    in
    encode_length_delimited Wire.resp_error_response error_msg
  ;;

  let encode_file_descriptor_response (descriptors : string list) : string =
    let buf = Buffer.create 4096 in
    List.iter
      (fun d ->
         Buffer.add_string buf (encode_length_delimited Wire.file_descriptor_proto d))
      descriptors;
    encode_length_delimited Wire.resp_file_descriptor_response (Buffer.contents buf)
  ;;

  let health_descriptor_response () =
    encode_file_descriptor_response [ grpc_health_descriptor ]
  ;;

  let reflection_v1_descriptor_response () =
    encode_file_descriptor_response [ grpc_reflection_descriptor ]
  ;;

  let reflection_v1alpha_descriptor_response () =
    encode_file_descriptor_response [ grpc_reflection_v1alpha_descriptor ]
  ;;

  let masc_descriptor_response () =
    encode_file_descriptor_response [ grpc_masc_descriptor ]
  ;;

  let handles_health_symbol symbol =
    List.mem symbol health_symbols || has_prefix ~prefix:"grpc.health.v1." symbol
  ;;

  let handles_health_filename filename = List.mem filename health_proto_filenames

  let handles_masc_symbol symbol =
    List.mem symbol masc_symbols || has_prefix ~prefix:"masc.workspace.v1." symbol
  ;;

  let handles_masc_filename filename = List.mem filename masc_proto_filenames

  let handles_reflection_v1_symbol symbol =
    List.mem symbol reflection_symbols || has_prefix ~prefix:"grpc.reflection.v1." symbol
  ;;

  let handles_reflection_v1alpha_symbol symbol =
    List.mem symbol reflection_v1alpha_symbols
    || has_prefix ~prefix:"grpc.reflection.v1alpha." symbol
  ;;

  let handles_reflection_v1_filename filename =
    List.mem filename reflection_proto_filenames
  ;;

  let handles_reflection_v1alpha_filename filename =
    List.mem filename reflection_v1alpha_proto_filenames
  ;;

  let to_service ~service_name (server_ref : Grpc_eio.Server.t ref) : Grpc_eio.Service.t =
    let handle_reflection_bidi ~sw (request_stream : string Grpc_eio.Stream.t)
      : string Grpc_eio.Stream.t
      =
      let response_stream = Grpc_eio.Stream.create 16 in
      let process_loop () =
        Eio.Switch.run
        @@ fun loop_sw ->
        Eio.Switch.on_release loop_sw (fun () ->
          Safe_ops.protect ~default:() (fun () -> Grpc_eio.Stream.close response_stream));
        let rec loop () =
          let request_bytes = Grpc_eio.Stream.take request_stream in
          let services = Grpc_eio.Server.list_services !server_ref in
          let response_payload =
            try
              match parse_request request_bytes with
              | ListServices -> encode_list_services_response services
              | FileContainingSymbol symbol when handles_reflection_v1alpha_symbol symbol
                -> reflection_v1alpha_descriptor_response ()
              | FileByFilename filename when handles_reflection_v1alpha_filename filename
                -> reflection_v1alpha_descriptor_response ()
              | FileContainingSymbol symbol when handles_reflection_v1_symbol symbol ->
                reflection_v1_descriptor_response ()
              | FileByFilename filename when handles_reflection_v1_filename filename ->
                reflection_v1_descriptor_response ()
              | FileContainingSymbol symbol when handles_health_symbol symbol ->
                health_descriptor_response ()
              | FileByFilename filename when handles_health_filename filename ->
                health_descriptor_response ()
              | FileContainingSymbol symbol when handles_masc_symbol symbol ->
                masc_descriptor_response ()
              | FileByFilename filename when handles_masc_filename filename ->
                masc_descriptor_response ()
              | FileContainingSymbol symbol ->
                encode_error_response 5 (Printf.sprintf "Symbol not found: %s" symbol)
              | FileByFilename filename ->
                encode_error_response
                  5
                  (Printf.sprintf "FileDescriptor not available for: %s" filename)
              | Unknown -> encode_error_response 3 "Unknown request type"
            with
            | (Invalid_argument _ | Failure _) as exn ->
              encode_error_response
                3
                (Printf.sprintf
                   "Malformed reflection request: %s"
                   (Printexc.to_string exn))
          in
          let response = with_original_request ~request:request_bytes response_payload in
          Grpc_eio.Stream.add response_stream response;
          loop ()
        in
        try loop () with
        | End_of_file -> ()
      in
      Eio.Fiber.fork ~sw (fun () ->
        try process_loop () with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Server.error
            "gRPC reflection process_loop crashed: %s"
            (Printexc.to_string exn));
      response_stream
    in
    Grpc_eio.Service.create service_name
    |> Grpc_eio.Service.add_bidi_streaming "ServerReflectionInfo" handle_reflection_bidi
  ;;
end

let create_server
      ~(port : int)
      ~(workspace_config : Workspace_utils_backend_setup.config)
      ~(tool_dispatcher :
          identity:Server_transport_admission.identity
          -> auth_token:string
          -> tool_name:string
          -> arguments:Yojson.Safe.t
          -> (string, string) result)
      ~(lsp_dispatcher :
          language_id:string
          -> jsonrpc_request_json:string
          -> workspace_root:string option
          -> (string, string) result)
  : Grpc_eio.Server.t
  =
  let service =
    Masc_grpc_service.create_service ~workspace_config ~tool_dispatcher ~lsp_dispatcher
  in
  let health = Grpc_eio.Health.create ~default_status:Grpc_eio.Health.Serving () in
  Grpc_eio.Health.register_service health ~service:Masc_grpc_service.service_name;
  Grpc_eio.Health.set_status
    health
    ~service:Masc_grpc_service.service_name
    Grpc_eio.Health.Serving;
  Grpc_eio.Health.register_service health ~service:"grpc.health.v1.Health";
  Grpc_eio.Health.set_status
    health
    ~service:"grpc.health.v1.Health"
    Grpc_eio.Health.Serving;
  let server =
    Grpc_eio.Server.create
      ~config:
        { Grpc_eio.Server.default_config with port; host = Env_config_core.masc_host () }
      ()
  in
  let server_ref = ref server in
  let reflection_service_v1 =
    Reflection_bridge.to_service
      ~service_name:Reflection_bridge.reflection_v1_service_name
      server_ref
  in
  let reflection_service_v1alpha =
    Reflection_bridge.to_service
      ~service_name:Reflection_bridge.reflection_v1alpha_service_name
      server_ref
  in
  let server =
    server
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.add_service service
    |> Grpc_eio.Server.add_service reflection_service_v1
    |> Grpc_eio.Server.add_service reflection_service_v1alpha
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  server_ref := server;
  server
;;

(** Start the gRPC workspace server.

    Runs in a forked fiber. Does not block the caller.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment (for network access).
    @param workspace_config The MASC workspace configuration.
    @param tool_dispatcher Function that dispatches tool calls. *)
let start
      ~(sw : Eio.Switch.t)
      ~(env : Eio_unix.Stdenv.base)
      ~(workspace_config : Workspace_utils_backend_setup.config)
      ~(tool_dispatcher :
          identity:Server_transport_admission.identity
          -> auth_token:string
          -> tool_name:string
          -> arguments:Yojson.Safe.t
          -> (string, string) result)
  : unit
  =
  if not (is_enabled ())
  then (
    Transport_metrics.set_grpc_runtime_listening false;
    Transport_metrics.set_grpc_listen_status "disabled";
    Log.Server.info "gRPC transport disabled (set MASC_GRPC_ENABLED=0 to disable)")
  else (
    let port = configured_port () in
    (* Extract Eio capabilities for LSP proxy wiring. *)
    let proc_mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    let base_path = workspace_config.Workspace_utils_backend_setup.base_path in
    (* Build the LSP dispatcher closure. Uses a dedicated switch scoped to
       the gRPC server lifetime so LSP child processes are cleaned up when
       the server shuts down. The process cache and router are server-scoped
       (shared across all gRPC calls) since gRPC calls are stateless unary RPCs,
       unlike the WebSocket endpoint which uses per-connection state. *)
    let lsp_sw = sw in
    let lsp_processes : (string, Lsp_process_manager.lsp_process) Hashtbl.t =
      Hashtbl.create 8
    in
    let lsp_router = Lsp_message_router.create () in
    let lsp_spawn_mutex = Eio.Mutex.create () in
    let lsp_dispatcher
          ~language_id
          ~jsonrpc_request_json
          ~workspace_root
      : (string, string) result
      =
      let lang_id = language_id in
      let ws_root = Option.value workspace_root ~default:base_path in
      (* Ensure the LSP process for this language is running. *)
      let ensure_proc () =
        Eio.Mutex.use_rw ~protect:true lsp_spawn_mutex (fun () ->
          match Hashtbl.find_opt lsp_processes lang_id with
          | Some proc -> Ok proc
          | None ->
            (match Lsp_process_manager.spawn ~sw:lsp_sw ~lang_id ~workspace_root:ws_root proc_mgr with
             | Error spawn_err ->
               Error (Format.asprintf "LSP spawn failed for %s: %a" lang_id Lsp_process_manager.pp_spawn_error spawn_err)
             | Ok proc ->
               let _reader =
                 Lsp_message_router.start_response_reader
                   ~sw:lsp_sw lsp_router proc
                   ~on_exit:None
                   ~on_notification:(fun ~client_id:_ ~method_:_ _params -> ())
               in
               (* Send initialize request with timeout. *)
               let init_params =
                 `Assoc
                   [ "processId", `Int (Unix.getpid ())
                   ; "rootUri", `String ("file://" ^ ws_root)
                   ; "capabilities", `Assoc []
                   ]
               in
               (try
                  let init_result =
                    Eio.Time.with_timeout_exn clock 10.0 (fun () ->
                      let promise =
                        Lsp_message_router.send_request
                          lsp_router proc
                          ~method_:"initialize"
                          ~params:init_params
                          ~client_id:0
                      in
                      Eio.Promise.await promise)
                  in
                  (match init_result with
                   | Ok _ ->
                     Lsp_message_router.send_notification
                       lsp_router proc
                       ~method_:"initialized"
                       ~params:(`Assoc []);
                     Hashtbl.replace lsp_processes lang_id proc;
                     Ok proc
                   | Error msg ->
                     (* Init failed: the proc + its 3 pipe FDs + reader fibers
                        are bound to [lsp_sw] (server lifetime) and were NOT
                        cached, so without teardown they leak until shutdown and
                        the next LspCall re-spawns (RFC-0261 / #21546). *)
                     Lsp_process_manager.shutdown proc;
                     Error (Printf.sprintf "LSP initialize failed for %s: %s" lang_id msg))
                with
                | Eio.Time.Timeout ->
                  Lsp_process_manager.shutdown proc;
                  Error (Printf.sprintf "LSP initialize timeout for %s (10s)" lang_id)
                | exn ->
                  Lsp_process_manager.shutdown proc;
                  Error (Printf.sprintf "LSP initialize error for %s: %s" lang_id (Printexc.to_string exn)))))
      in
      match ensure_proc () with
      | Error _ as e -> e
      | Ok proc ->
        (match parse_lsp_jsonrpc_request jsonrpc_request_json with
         | Error _ as error -> error
         | Ok (method_, params) ->
           try
             let promise =
               Lsp_message_router.send_request
                 lsp_router proc
                 ~method_
                 ~params
                 ~client_id:0
             in
             (match Eio.Promise.await promise with
              | Ok result ->
                Ok (Yojson.Safe.to_string result)
              | Error msg ->
                Error (Printf.sprintf "LSP request failed: %s" msg))
           with
           | exn ->
             Error (Printf.sprintf "LSP dispatch error: %s" (Printexc.to_string exn)))
    in
    Eio.Fiber.fork ~sw (fun () ->
      try
        let server =
          create_server ~port ~workspace_config ~tool_dispatcher ~lsp_dispatcher
        in
        Log.Server.info
          "gRPC workspace server starting on port %d (health + reflection enabled)"
          port;
        Log.Server.info "  service: %s" Masc_grpc_service.service_name;
        Log.Server.info "  health: %s/Check" health_service_name;
        Log.Server.info
          "  methods: Broadcast, GetStatus, ToolCall, LspCall, Subscribe, Heartbeat";
        Transport_metrics.set_grpc_runtime_listening true;
        Transport_metrics.set_grpc_listen_status "listening";
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Eio_guard.protect
          ~finally:(fun () ->
            Transport_metrics.set_grpc_runtime_listening false;
            Transport_metrics.set_grpc_listen_status "stopped")
          (fun () -> Grpc_eio.Server.serve ~sw ~env server)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Transport_metrics.set_grpc_runtime_listening false;
        Transport_metrics.set_grpc_listen_status "bind_failed";
        Log.Server.error
          "gRPC workspace transport unavailable on %s:%d: port already in use"
          Masc_network_defaults.masc_http_default_host
          port
      | exn ->
        Transport_metrics.set_grpc_runtime_listening false;
        Transport_metrics.set_grpc_listen_status "stopped";
        Log.Server.error "gRPC server failed: %s" (Printexc.to_string exn)))
;;

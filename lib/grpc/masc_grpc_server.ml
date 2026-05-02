(** MASC gRPC Server.

    Runs the gRPC coordination service on a separate port (default 8936).
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

  let grpc_reflection_descriptor_b64 =
    "CiNncnBjL3JlZmxlY3Rpb24vdjEvcmVmbGVjdGlvbi5wcm90bxISZ3JwYy5yZWZsZWN0aW9uLnYxIvMCChdTZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBISCgRob3N0GAEgASgJUgRob3N0EioKEGZpbGVfYnlfZmlsZW5hbWUYAyABKAlIAFIOZmlsZUJ5RmlsZW5hbWUSNgoWZmlsZV9jb250YWluaW5nX3N5bWJvbBgEIAEoCUgAUhRmaWxlQ29udGFpbmluZ1N5bWJvbBJiChlmaWxlX2NvbnRhaW5pbmdfZXh0ZW5zaW9uGAUgASgLMiQuZ3JwYy5yZWZsZWN0aW9uLnYxLkV4dGVuc2lvblJlcXVlc3RIAFIXZmlsZUNvbnRhaW5pbmdFeHRlbnNpb24SQgodYWxsX2V4dGVuc2lvbl9udW1iZXJzX29mX3R5cGUYBiABKAlIAFIZYWxsRXh0ZW5zaW9uTnVtYmVyc09mVHlwZRIlCg1saXN0X3NlcnZpY2VzGAcgASgJSABSDGxpc3RTZXJ2aWNlc0IRCg9tZXNzYWdlX3JlcXVlc3QiZgoQRXh0ZW5zaW9uUmVxdWVzdBInCg9jb250YWluaW5nX3R5cGUYASABKAlSDmNvbnRhaW5pbmdUeXBlEikKEGV4dGVuc2lvbl9udW1iZXIYAiABKAVSD2V4dGVuc2lvbk51bWJlciKuBAoYU2VydmVyUmVmbGVjdGlvblJlc3BvbnNlEh0KCnZhbGlkX2hvc3QYASABKAlSCXZhbGlkSG9zdBJWChBvcmlnaW5hbF9yZXF1ZXN0GAIgASgLMisuZ3JwYy5yZWZsZWN0aW9uLnYxLlNlcnZlclJlZmxlY3Rpb25SZXF1ZXN0Ug9vcmlnaW5hbFJlcXVlc3QSZgoYZmlsZV9kZXNjcmlwdG9yX3Jlc3BvbnNlGAQgASgLMiouZ3JwYy5yZWZsZWN0aW9uLnYxLkZpbGVEZXNjcmlwdG9yUmVzcG9uc2VIAFIWZmlsZURlc2NyaXB0b3JSZXNwb25zZRJyCh5hbGxfZXh0ZW5zaW9uX251bWJlcnNfcmVzcG9uc2UYBSABKAsyKy5ncnBjLnJlZmxlY3Rpb24udjEuRXh0ZW5zaW9uTnVtYmVyUmVzcG9uc2VIAFIbYWxsRXh0ZW5zaW9uTnVtYmVyc1Jlc3BvbnNlEl8KFmxpc3Rfc2VydmljZXNfcmVzcG9uc2UYBiABKAsyJy5ncnBjLnJlZmxlY3Rpb24udjEuTGlzdFNlcnZpY2VSZXNwb25zZUgAUhRsaXN0U2VydmljZXNSZXNwb25zZRJKCg5lcnJvcl9yZXNwb25zZRgHIAEoCzIhLmdycGMucmVmbGVjdGlvbi52MS5FcnJvclJlc3BvbnNlSABSDWVycm9yUmVzcG9uc2VCEgoQbWVzc2FnZV9yZXNwb25zZSJMChZGaWxlRGVzY3JpcHRvclJlc3BvbnNlEjIKFWZpbGVfZGVzY3JpcHRvcl9wcm90bxgBIAMoDFITZmlsZURlc2NyaXB0b3JQcm90byJqChdFeHRlbnNpb25OdW1iZXJSZXNwb25zZRIkCg5iYXNlX3R5cGVfbmFtZRgBIAEoCVIMYmFzZVR5cGVOYW1lEikKEGV4dGVuc2lvbl9udW1iZXIYAiADKAVSD2V4dGVuc2lvbk51bWJlciJUChNMaXN0U2VydmljZVJlc3BvbnNlEj0KB3NlcnZpY2UYASADKAsyIy5ncnBjLnJlZmxlY3Rpb24udjEuU2VydmljZVJlc3BvbnNlUgdzZXJ2aWNlIiUKD1NlcnZpY2VSZXNwb25zZRISCgRuYW1lGAEgASgJUgRuYW1lIlMKDUVycm9yUmVzcG9uc2USHQoKZXJyb3JfY29kZRgBIAEoBVIJZXJyb3JDb2RlEiMKDWVycm9yX21lc3NhZ2UYAiABKAlSDGVycm9yTWVzc2FnZTKJAQoQU2VydmVyUmVmbGVjdGlvbhJ1ChRTZXJ2ZXJSZWZsZWN0aW9uSW5mbxIrLmdycGMucmVmbGVjdGlvbi52MS5TZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBosLmdycGMucmVmbGVjdGlvbi52MS5TZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2UoATABYgZwcm90bzM="

  let grpc_reflection_v1alpha_descriptor_b64 =
    "ChhyZWZsZWN0aW9uX3YxYWxwaGEucHJvdG8SF2dycGMucmVmbGVjdGlvbi52MWFscGhhIvgCChdTZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdBISCgRob3N0GAEgASgJUgRob3N0EioKEGZpbGVfYnlfZmlsZW5hbWUYAyABKAlIAFIOZmlsZUJ5RmlsZW5hbWUSNgoWZmlsZV9jb250YWluaW5nX3N5bWJvbBgEIAEoCUgAUhRmaWxlQ29udGFpbmluZ1N5bWJvbBJnChlmaWxlX2NvbnRhaW5pbmdfZXh0ZW5zaW9uGAUgASgLMikuZ3JwYy5yZWZsZWN0aW9uLnYxYWxwaGEuRXh0ZW5zaW9uUmVxdWVzdEgAUhdmaWxlQ29udGFpbmluZ0V4dGVuc2lvbhJCCh1hbGxfZXh0ZW5zaW9uX251bWJlcnNfb2ZfdHlwZRgGIAEoCUgAUhlhbGxFeHRlbnNpb25OdW1iZXJzT2ZUeXBlEiUKDWxpc3Rfc2VydmljZXMYByABKAlIAFIMbGlzdFNlcnZpY2VzQhEKD21lc3NhZ2VfcmVxdWVzdCJmChBFeHRlbnNpb25SZXF1ZXN0EicKD2NvbnRhaW5pbmdfdHlwZRgBIAEoCVIOY29udGFpbmluZ1R5cGUSKQoQZXh0ZW5zaW9uX251bWJlchgCIAEoBVIPZXh0ZW5zaW9uTnVtYmVyIscEChhTZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2USHQoKdmFsaWRfaG9zdBgBIAEoCVIJdmFsaWRIb3N0ElsKEG9yaWdpbmFsX3JlcXVlc3QYAiABKAsyMC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2ZXJSZWZsZWN0aW9uUmVxdWVzdFIPb3JpZ2luYWxSZXF1ZXN0EmsKGGZpbGVfZGVzY3JpcHRvcl9yZXNwb25zZRgEIAEoCzIvLmdycGMucmVmbGVjdGlvbi52MWFscGhhLkZpbGVEZXNjcmlwdG9yUmVzcG9uc2VIAFIWZmlsZURlc2NyaXB0b3JSZXNwb25zZRJ3Ch5hbGxfZXh0ZW5zaW9uX251bWJlcnNfcmVzcG9uc2UYBSABKAsyMC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5FeHRlbnNpb25OdW1iZXJSZXNwb25zZUgAUhthbGxFeHRlbnNpb25OdW1iZXJzUmVzcG9uc2USZAoWbGlzdF9zZXJ2aWNlc19yZXNwb25zZRgGIAEoCzIsLmdycGMucmVmbGVjdGlvbi52MWFscGhhLkxpc3RTZXJ2aWNlUmVzcG9uc2VIAFIUbGlzdFNlcnZpY2VzUmVzcG9uc2USTwoOZXJyb3JfcmVzcG9uc2UYByABKAsyJi5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5FcnJvclJlc3BvbnNlSABSDWVycm9yUmVzcG9uc2VCEgoQbWVzc2FnZV9yZXNwb25zZSJMChZGaWxlRGVzY3JpcHRvclJlc3BvbnNlEjIKFWZpbGVfZGVzY3JpcHRvcl9wcm90bxgBIAMoDFITZmlsZURlc2NyaXB0b3JQcm90byJqChdFeHRlbnNpb25OdW1iZXJSZXNwb25zZRIkCg5iYXNlX3R5cGVfbmFtZRgBIAEoCVIMYmFzZVR5cGVOYW1lEikKEGV4dGVuc2lvbl9udW1iZXIYAiADKAVSD2V4dGVuc2lvbk51bWJlciJZChNMaXN0U2VydmljZVJlc3BvbnNlEkIKB3NlcnZpY2UYASADKAsyKC5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2aWNlUmVzcG9uc2VSB3NlcnZpY2UiJQoPU2VydmljZVJlc3BvbnNlEhIKBG5hbWUYASABKAlSBG5hbWUiUwoNRXJyb3JSZXNwb25zZRIdCgplcnJvcl9jb2RlGAEgASgFUgllcnJvckNvZGUSIwoNZXJyb3JfbWVzc2FnZRgCIAEoCVIMZXJyb3JNZXNzYWdlMpMBChBTZXJ2ZXJSZWZsZWN0aW9uEn8KFFNlcnZlclJlZmxlY3Rpb25JbmZvEjAuZ3JwYy5yZWZsZWN0aW9uLnYxYWxwaGEuU2VydmVyUmVmbGVjdGlvblJlcXVlc3QaMS5ncnBjLnJlZmxlY3Rpb24udjFhbHBoYS5TZXJ2ZXJSZWZsZWN0aW9uUmVzcG9uc2UoATABYgZwcm90bzM="

  let grpc_masc_descriptor_b64 =
    "ChdtYXNjX2Nvb3JkaW5hdGlvbi5wcm90bxIUbWFzYy5jb29yZGluYXRpb24udjEi2gEKC0pvaW5SZXF1ZXN0Eh0KCmFnZW50X25hbWUYASABKAlSCWFnZW50"
    ^ "TmFtZRIiCgxjYXBhYmlsaXRpZXMYAiADKAlSDGNhcGFiaWxpdGllcxJLCghtZXRhZGF0YRgDIAMoCzIvLm1hc2MuY29vcmRpbmF0aW9uLnYxLkpvaW5SZXF1"
    ^ "ZXN0Lk1ldGFkYXRhRW50cnlSCG1ldGFkYXRhGjsKDU1ldGFkYXRhRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZhbHVlOgI4ASKn"
    ^ "AQoMSm9pblJlc3BvbnNlEhgKB3N1Y2Nlc3MYASABKAhSB3N1Y2Nlc3MSGAoHbWVzc2FnZRgCIAEoCVIHbWVzc2FnZRIdCgpzZXNzaW9uX2lkGAMgASgJUglz"
    ^ "ZXNzaW9uSWQSRAoNYWN0aXZlX2FnZW50cxgEIAMoCzIfLm1hc2MuY29vcmRpbmF0aW9uLnYxLkFnZW50SW5mb1IMYWN0aXZlQWdlbnRzIkwKDExlYXZlUmVx"
    ^ "dWVzdBIdCgphZ2VudF9uYW1lGAEgASgJUglhZ2VudE5hbWUSHQoKc2Vzc2lvbl9pZBgCIAEoCVIJc2Vzc2lvbklkIkMKDUxlYXZlUmVzcG9uc2USGAoHc3Vj"
    ^ "Y2VzcxgBIAEoCFIHc3VjY2VzcxIYCgdtZXNzYWdlGAIgASgJUgdtZXNzYWdlIpgBCg1IZWFydGJlYXRQaW5nEh0KCmFnZW50X25hbWUYASABKAlSCWFnZW50"
    ^ "TmFtZRIdCgpzZXNzaW9uX2lkGAIgASgJUglzZXNzaW9uSWQSIQoMdGltZXN0YW1wX21zGAMgASgDUgt0aW1lc3RhbXBNcxImCg9jdXJyZW50X3Rhc2tfaWQY"
    ^ "BCABKAlSDWN1cnJlbnRUYXNrSWQirQEKDEhlYXJ0YmVhdEFjaxIhCgx0aW1lc3RhbXBfbXMYASABKANSC3RpbWVzdGFtcE1zEiwKEmFjdGl2ZV9hZ2VudF9j"
    ^ "b3VudBgCIAEoBVIQYWN0aXZlQWdlbnRDb3VudBIsChJwZW5kaW5nX3Rhc2tfY291bnQYAyABKAVSEHBlbmRpbmdUYXNrQ291bnQSHgoKZGlyZWN0aXZlcxgE"
    ^ "IAMoCVIKZGlyZWN0aXZlcyKOAQoQU3Vic2NyaWJlUmVxdWVzdBIdCgphZ2VudF9uYW1lGAEgASgJUglhZ2VudE5hbWUSHQoKc2Vzc2lvbl9pZBgCIAEoCVIJ"
    ^ "c2Vzc2lvbklkEh8KC2V2ZW50X3R5cGVzGAMgAygJUgpldmVudFR5cGVzEhsKCXNpbmNlX3NlcRgEIAEoA1IIc2luY2VTZXEioQEKBUV2ZW50EhAKA3NlcRgB"
    ^ "IAEoA1IDc2VxEh0KCmV2ZW50X3R5cGUYAiABKAlSCWV2ZW50VHlwZRIhCgxzb3VyY2VfYWdlbnQYAyABKAlSC3NvdXJjZUFnZW50EiEKDHRpbWVzdGFtcF9t"
    ^ "cxgEIAEoA1ILdGltZXN0YW1wTXMSIQoMcGF5bG9hZF9qc29uGAUgASgJUgtwYXlsb2FkSnNvbiKTAQoPVG9vbENhbGxSZXF1ZXN0Eh0KCmFnZW50X25hbWUY"
    ^ "ASABKAlSCWFnZW50TmFtZRIdCgpzZXNzaW9uX2lkGAIgASgJUglzZXNzaW9uSWQSGwoJdG9vbF9uYW1lGAMgASgJUgh0b29sTmFtZRIlCg5hcmd1bWVudHNf"
    ^ "anNvbhgEIAEoCVINYXJndW1lbnRzSnNvbiKRAQoQVG9vbENhbGxSZXNwb25zZRIYCgdzdWNjZXNzGAEgASgIUgdzdWNjZXNzEh8KC3Jlc3VsdF9qc29uGAIg"
    ^ "ASgJUgpyZXN1bHRKc29uEiMKDWVycm9yX21lc3NhZ2UYAyABKAlSDGVycm9yTWVzc2FnZRIdCgplcnJvcl9jb2RlGAQgASgFUgllcnJvckNvZGUiZwoQQnJv"
    ^ "YWRjYXN0UmVxdWVzdBIdCgphZ2VudF9uYW1lGAEgASgJUglhZ2VudE5hbWUSGAoHbWVzc2FnZRgCIAEoCVIHbWVzc2FnZRIaCghtZW50aW9ucxgDIAMoCVII"
    ^ "bWVudGlvbnMiPwoRQnJvYWRjYXN0UmVzcG9uc2USGAoHc3VjY2VzcxgBIAEoCFIHc3VjY2VzcxIQCgNzZXEYAiABKANSA3NlcSIPCg1TdGF0dXNSZXF1ZXN0"
    ^ "IsEBCg5TdGF0dXNSZXNwb25zZRI3CgZhZ2VudHMYASADKAsyHy5tYXNjLmNvb3JkaW5hdGlvbi52MS5BZ2VudEluZm9SBmFnZW50cxI0CgV0YXNrcxgCIAMo"
    ^ "CzIeLm1hc2MuY29vcmRpbmF0aW9uLnYxLlRhc2tJbmZvUgV0YXNrcxIjCg1tZXNzYWdlX2NvdW50GAMgASgFUgxtZXNzYWdlQ291bnQSGwoJcm9vbV9wYXRo"
    ^ "GAQgASgJUghyb29tUGF0aCLRAQoJQWdlbnRJbmZvEhIKBG5hbWUYASABKAlSBG5hbWUSFgoGc3RhdHVzGAIgASgJUgZzdGF0dXMSIgoMY2FwYWJpbGl0aWVz"
    ^ "GAMgAygJUgxjYXBhYmlsaXRpZXMSKgoRbGFzdF9oZWFydGJlYXRfbXMYBCABKANSD2xhc3RIZWFydGJlYXRNcxIgCgxqb2luZWRfYXRfbXMYBSABKANSCmpv"
    ^ "aW5lZEF0TXMSJgoPY3VycmVudF90YXNrX2lkGAYgASgJUg1jdXJyZW50VGFza0lkIoUBCghUYXNrSW5mbxIOCgJpZBgBIAEoCVICaWQSFAoFdGl0bGUYAiAB"
    ^ "KAlSBXRpdGxlEhYKBnN0YXR1cxgDIAEoCVIGc3RhdHVzEh8KC2Fzc2lnbmVkX3RvGAQgASgJUgphc3NpZ25lZFRvEhoKCHByaW9yaXR5GAUgASgFUghwcmlv"
    ^ "cml0eTLyBAoQTWFzY0Nvb3JkaW5hdGlvbhJNCgRKb2luEiEubWFzYy5jb29yZGluYXRpb24udjEuSm9pblJlcXVlc3QaIi5tYXNjLmNvb3JkaW5hdGlvbi52"
    ^ "MS5Kb2luUmVzcG9uc2USUAoFTGVhdmUSIi5tYXNjLmNvb3JkaW5hdGlvbi52MS5MZWF2ZVJlcXVlc3QaIy5tYXNjLmNvb3JkaW5hdGlvbi52MS5MZWF2ZVJl"
    ^ "c3BvbnNlElgKCUhlYXJ0YmVhdBIjLm1hc2MuY29vcmRpbmF0aW9uLnYxLkhlYXJ0YmVhdFBpbmcaIi5tYXNjLmNvb3JkaW5hdGlvbi52MS5IZWFydGJlYXRB"
    ^ "Y2soATABElIKCVN1YnNjcmliZRImLm1hc2MuY29vcmRpbmF0aW9uLnYxLlN1YnNjcmliZVJlcXVlc3QaGy5tYXNjLmNvb3JkaW5hdGlvbi52MS5FdmVudDAB"
    ^ "ElkKCFRvb2xDYWxsEiUubWFzYy5jb29yZGluYXRpb24udjEuVG9vbENhbGxSZXF1ZXN0GiYubWFzYy5jb29yZGluYXRpb24udjEuVG9vbENhbGxSZXNwb25z"
    ^ "ZRJcCglCcm9hZGNhc3QSJi5tYXNjLmNvb3JkaW5hdGlvbi52MS5Ccm9hZGNhc3RSZXF1ZXN0GicubWFzYy5jb29yZGluYXRpb24udjEuQnJvYWRjYXN0UmVz"
    ^ "cG9uc2USVgoJR2V0U3RhdHVzEiMubWFzYy5jb29yZGluYXRpb24udjEuU3RhdHVzUmVxdWVzdBokLm1hc2MuY29vcmRpbmF0aW9uLnYxLlN0YXR1c1Jlc3Bv"
    ^ "bnNlYgZwcm90bzM="

  let grpc_health_descriptor =
    Base64.decode_exn grpc_health_descriptor_b64

  let grpc_reflection_descriptor =
    Base64.decode_exn grpc_reflection_descriptor_b64

  let grpc_reflection_v1alpha_descriptor =
    Base64.decode_exn grpc_reflection_v1alpha_descriptor_b64

  let grpc_masc_descriptor =
    Base64.decode_exn grpc_masc_descriptor_b64

  let health_proto_filenames =
    [ "grpc/health/v1/health.proto"; "grpc-health.proto"; "health.proto" ]

  let reflection_proto_filenames =
    [
      "grpc/reflection/v1/reflection.proto";
      "grpc_reflection_v1.proto";
      "reflection.proto";
    ]

  let reflection_v1alpha_proto_filenames =
    [ "reflection_v1alpha.proto"; "grpc/reflection/v1alpha/reflection.proto" ]

  let masc_proto_filenames =
    [ "masc_coordination.proto" ]

  let health_symbols =
    [
      "grpc.health.v1.Health";
      "grpc.health.v1.Health.Check";
      "grpc.health.v1.Health.Watch";
      "grpc.health.v1.HealthCheckRequest";
      "grpc.health.v1.HealthCheckResponse";
      "grpc.health.v1.HealthCheckResponse.ServingStatus";
    ]

  let reflection_symbols =
    [
      reflection_v1_service_name;
      reflection_v1_service_name ^ ".ServerReflectionInfo";
      "grpc.reflection.v1.ServerReflectionRequest";
      "grpc.reflection.v1.ServerReflectionResponse";
      "grpc.reflection.v1.FileDescriptorResponse";
      "grpc.reflection.v1.ListServiceResponse";
      "grpc.reflection.v1.ServiceResponse";
      "grpc.reflection.v1.ErrorResponse";
      "grpc.reflection.v1.ExtensionRequest";
      "grpc.reflection.v1.ExtensionNumberResponse";
    ]

  let reflection_v1alpha_symbols =
    [
      reflection_v1alpha_service_name;
      reflection_v1alpha_service_name ^ ".ServerReflectionInfo";
      "grpc.reflection.v1alpha.ServerReflectionRequest";
      "grpc.reflection.v1alpha.ServerReflectionResponse";
      "grpc.reflection.v1alpha.FileDescriptorResponse";
      "grpc.reflection.v1alpha.ListServiceResponse";
      "grpc.reflection.v1alpha.ServiceResponse";
      "grpc.reflection.v1alpha.ErrorResponse";
      "grpc.reflection.v1alpha.ExtensionRequest";
      "grpc.reflection.v1alpha.ExtensionNumberResponse";
    ]

  let masc_symbols =
    [ Masc_grpc_service.service_name ]

  let has_prefix ~prefix value = String.starts_with ~prefix value

  let decode_varint (bytes : string) (pos : int ref) : int =
    let result = ref 0 in
    let shift = ref 0 in
    let done_ = ref false in
    while !pos < String.length bytes && not !done_ do
      let byte = Char.code bytes.[!pos] in
      if !shift >= Sys.int_size then
        invalid_arg "reflection varint overflow";
      incr pos;
      result := !result lor ((byte land 0x7f) lsl !shift);
      shift := !shift + 7;
      if byte land 0x80 = 0 then done_ := true
    done;
    if not !done_ then
      invalid_arg "reflection truncated varint";
    !result

  let encode_varint (n : int) : string =
    if n < 0 then
      invalid_arg "reflection negative varint"
    else if n = 0 then
      "\x00"
    else
      let buf = Buffer.create 10 in
      let n = ref n in
      while !n > 0 do
        let byte = !n land 0x7f in
        n := !n lsr 7;
        if !n > 0 then
          Buffer.add_char buf (Char.chr (byte lor 0x80))
        else
          Buffer.add_char buf (Char.chr byte)
      done;
      Buffer.contents buf

  let encode_length_delimited (field_num : int) (data : string) : string =
    let tag = (field_num lsl 3) lor 2 in
    encode_varint tag ^ encode_varint (String.length data) ^ data

  let encode_string_field (field_num : int) (s : string) : string =
    encode_length_delimited field_num s

  let parse_request (data : string) : request =
    if String.length data = 0 then
      Unknown
    else
      let pos = ref 0 in
      let result = ref Unknown in
      while !pos < String.length data do
        let tag = decode_varint data pos in
        let field_num = tag lsr 3 in
        let wire_type = tag land 7 in
        match wire_type with
        | 2 ->
            let len = decode_varint data pos in
            if !pos + len > String.length data then
              invalid_arg "reflection truncated length-delimited field";
            let value = String.sub data !pos len in
            pos := !pos + len;
            (match field_num with
            | n when n = Wire.req_file_by_filename -> result := FileByFilename value
            | n when n = Wire.req_file_containing_symbol ->
                result := FileContainingSymbol value
            | n when n = Wire.req_list_services -> result := ListServices
            | _ -> Log.Server.warn "masc_grpc_server: unknown reflection field_num %d" field_num)
        | 0 ->
            let _ = decode_varint data pos in
            ()
        | 1 ->
            if !pos + 8 > String.length data then
              invalid_arg "reflection truncated fixed64 field";
            pos := !pos + 8
        | _ ->
            if wire_type = 5 then begin
              if !pos + 4 > String.length data then
                invalid_arg "reflection truncated fixed32 field";
              pos := !pos + 4
            end else
              pos := String.length data
      done;
      !result

  let encode_list_services_response (services : string list) : string =
    let buf = Buffer.create 256 in
    List.iter
      (fun name ->
        let msg = encode_string_field Wire.service_name name in
        Buffer.add_string buf (encode_length_delimited Wire.list_service_service msg))
      services;
    let list_response = Buffer.contents buf in
    encode_length_delimited Wire.resp_list_services_response list_response

  let with_original_request ~(request : string) (payload : string) : string =
    encode_length_delimited Wire.resp_original_request request ^ payload

  let encode_error_response (code : int) (message : string) : string =
    let error_msg =
      encode_varint ((Wire.error_code lsl 3) lor 0)
      ^ encode_varint code
      ^ encode_string_field Wire.error_message message
    in
    encode_length_delimited Wire.resp_error_response error_msg

  let encode_file_descriptor_response (descriptors : string list) : string =
    let buf = Buffer.create 4096 in
    List.iter
      (fun d -> Buffer.add_string buf (encode_length_delimited Wire.file_descriptor_proto d))
      descriptors;
    encode_length_delimited Wire.resp_file_descriptor_response (Buffer.contents buf)

  let health_descriptor_response () =
    encode_file_descriptor_response [ grpc_health_descriptor ]

  let reflection_v1_descriptor_response () =
    encode_file_descriptor_response [ grpc_reflection_descriptor ]

  let reflection_v1alpha_descriptor_response () =
    encode_file_descriptor_response [ grpc_reflection_v1alpha_descriptor ]

  let masc_descriptor_response () =
    encode_file_descriptor_response [ grpc_masc_descriptor ]

  let handles_health_symbol symbol =
    List.mem symbol health_symbols
    || has_prefix ~prefix:"grpc.health.v1." symbol

  let handles_health_filename filename =
    List.mem filename health_proto_filenames

  let handles_masc_symbol symbol =
    List.mem symbol masc_symbols
    || has_prefix ~prefix:"masc.coordination.v1." symbol

  let handles_masc_filename filename =
    List.mem filename masc_proto_filenames

  let handles_reflection_v1_symbol symbol =
    List.mem symbol reflection_symbols
    || has_prefix ~prefix:"grpc.reflection.v1." symbol

  let handles_reflection_v1alpha_symbol symbol =
    List.mem symbol reflection_v1alpha_symbols
    || has_prefix ~prefix:"grpc.reflection.v1alpha." symbol

  let handles_reflection_v1_filename filename =
    List.mem filename reflection_proto_filenames

  let handles_reflection_v1alpha_filename filename =
    List.mem filename reflection_v1alpha_proto_filenames

  let to_service ~service_name (server_ref : Grpc_eio.Server.t ref) :
      Grpc_eio.Service.t =
    let handle_reflection_bidi ~sw
        (request_stream : string Grpc_eio.Stream.t) :
        string Grpc_eio.Stream.t =
      let response_stream = Grpc_eio.Stream.create 16 in
      let process_loop () =
        Eio.Switch.run @@ fun loop_sw ->
        Eio.Switch.on_release loop_sw (fun () ->
            Safe_ops.protect ~default:() (fun () ->
              Grpc_eio.Stream.close response_stream));
            let rec loop () =
              let request_bytes = Grpc_eio.Stream.take request_stream in
              let services = Grpc_eio.Server.list_services !server_ref in
              let response_payload =
              try
                match parse_request request_bytes with
                | ListServices ->
                    encode_list_services_response services
                | FileContainingSymbol symbol
                  when handles_reflection_v1alpha_symbol symbol ->
                    reflection_v1alpha_descriptor_response ()
                | FileByFilename filename
                  when handles_reflection_v1alpha_filename filename ->
                    reflection_v1alpha_descriptor_response ()
                | FileContainingSymbol symbol
                  when handles_reflection_v1_symbol symbol ->
                    reflection_v1_descriptor_response ()
                | FileByFilename filename
                  when handles_reflection_v1_filename filename ->
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
                    encode_error_response 5
                      (Printf.sprintf "Symbol not found: %s" symbol)
                | FileByFilename filename ->
                    encode_error_response 5
                      (Printf.sprintf "FileDescriptor not available for: %s"
                         filename)
                | Unknown ->
                    encode_error_response 3 "Unknown request type"
              with
              | Invalid_argument _ | Failure _ as exn ->
                  encode_error_response 3
                    (Printf.sprintf "Malformed reflection request: %s"
                       (Printexc.to_string exn))
            in
            let response =
              with_original_request ~request:request_bytes response_payload
            in
            Grpc_eio.Stream.add response_stream response;
              loop ()
            in
            try loop () with End_of_file -> ()
      in
      Eio.Fiber.fork ~sw (fun () ->
        try process_loop ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Server.error
              "gRPC reflection process_loop crashed: %s"
              (Printexc.to_string exn));
      response_stream
    in
    Grpc_eio.Service.create service_name
    |> Grpc_eio.Service.add_bidi_streaming
         "ServerReflectionInfo" handle_reflection_bidi
end

let create_server
    ~(port : int)
    ~(room_config : Coord_utils_backend_setup.config)
    ~(tool_dispatcher : string -> string -> (string, string) result)
  : Grpc_eio.Server.t =
  let service =
    Masc_grpc_service.create_service ~room_config ~tool_dispatcher
  in
  let health = Grpc_eio.Health.create ~default_status:Grpc_eio.Health.Serving () in
  Grpc_eio.Health.register_service health
    ~service:Masc_grpc_service.service_name;
  Grpc_eio.Health.set_status health
    ~service:Masc_grpc_service.service_name
    Grpc_eio.Health.Serving;
  Grpc_eio.Health.register_service health ~service:"grpc.health.v1.Health";
  Grpc_eio.Health.set_status health
    ~service:"grpc.health.v1.Health"
    Grpc_eio.Health.Serving;
  let server =
    Grpc_eio.Server.create
      ~config:{ Grpc_eio.Server.default_config with port; host = Env_config_core.masc_host () }
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

(** Start the gRPC coordination server.

    Runs in a forked fiber. Does not block the caller.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment (for network access).
    @param room_config The MASC room configuration.
    @param tool_dispatcher Function that dispatches tool calls. *)
let start
    ~(sw : Eio.Switch.t)
    ~(env : Eio_unix.Stdenv.base)
    ~(room_config : Coord_utils_backend_setup.config)
    ~(tool_dispatcher : string -> string -> (string, string) result)
  : unit =
  if not (is_enabled ()) then begin
    Transport_metrics.set_grpc_runtime_listening false;
    Transport_metrics.set_grpc_listen_status "disabled";
    Log.Server.info "gRPC transport disabled (set MASC_GRPC_ENABLED=0 to disable)";
  end
  else begin
    let port = configured_port () in
    Eio.Fiber.fork ~sw (fun () ->
      (try
        let server = create_server ~port ~room_config ~tool_dispatcher in
        Log.Server.info
          "gRPC coordination server starting on port %d (health + reflection enabled)"
          port;
        Log.Server.info "  service: %s" Masc_grpc_service.service_name;
        Log.Server.info "  health: %s/Check" health_service_name;
        Log.Server.info
          "  methods: Join, Leave, Broadcast, GetStatus, ToolCall, Subscribe, Heartbeat";
        Transport_metrics.set_grpc_runtime_listening true;
        Transport_metrics.set_grpc_listen_status "listening";
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Fun.protect
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
          "gRPC coordination transport unavailable on 127.0.0.1:%d: port already in use"
          port
      | exn ->
        Transport_metrics.set_grpc_runtime_listening false;
        Transport_metrics.set_grpc_listen_status "stopped";
        Log.Server.error "gRPC server failed: %s" (Printexc.to_string exn)))
  end

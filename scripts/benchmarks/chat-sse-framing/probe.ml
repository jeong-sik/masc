(* Run after loading the complete production Sse_wire module. Protocol-only:
   no renderer, provider, journal reducer, or fabricated reasoning is involved. *)
open Sse_wire
let check label expected actual =
  if expected <> actual then failwith label
let cases = [
  "thinking", Some 1, "{\"type\":\"CUSTOM\",\"name\":\"KEEPER_THINKING_DELTA\",\"value\":{\"index\":0,\"delta\":\"관측된 추론\"}}";
  "saying", Some 2, "{\"type\":\"TEXT_MESSAGE_CONTENT\",\"delta\":\" 엉...\\n원문 🙂 \"}";
  "tool", Some 3, "{\"type\":\"TOOL_CALL_ARGS\",\"delta\":\"{\\\"query\\\":\\\"원문\\\"}\"}";
  "external", Some 4, "{\"type\":\"CUSTOM\",\"name\":\"external\",\"value\":\"broadcast\"}";
  "acceptance", None, "{\"type\":\"CUSTOM\",\"name\":\"KEEPER_CHAT_OPERATION_ACCEPTED\"}";
  "multiline", Some 5, " leading\n\n마지막 줄 \n";
]
let expected = List.map (fun (_,id,data) ->
  {id=Option.map string_of_int id;data}) cases
let wire = List.map (fun (_,id,data) -> format_event ?id data) cases |> String.concat ""
let run chunks =
  let decoder = create_decoder () in List.concat_map (feed decoder) chunks
let checks = ref 0
let verify label expected actual = incr checks; check label expected actual
let () =
  verify "whole stream" expected (run [wire]);
  for split = 0 to String.length wire do
    verify "every byte boundary" expected
      (run [String.sub wire 0 split; String.sub wire split (String.length wire-split)])
  done;
  verify "byte-at-a-time including UTF8" expected
    (run (List.init (String.length wire) (fun i -> String.sub wire i 1)));
  let crlf = String.concat "\r\n" (String.split_on_char '\n' wire) in
  for split = 0 to String.length crlf do
    verify "CRLF boundary" expected
      (run [String.sub crlf 0 split;String.sub crlf split (String.length crlf-split)])
  done;
  verify "BOM byte boundaries" expected
    (run (List.init (String.length wire+3) (fun i -> String.sub ("\239\187\191"^wire) i 1)));
  let unfinished = "id: 999\ndata: incomplete" in
  let disconnected = create_decoder () in
  verify "incomplete disconnected frame" [] (feed disconnected unfinished);
  verify "fresh connection has no inherited ID or body"
    [{id=None;data="accepted"}] (run [format_event "accepted"]);
  verify "explicit IDs are frame-local"
    [{id=Some "1";data="a"};{id=None;data="b"}]
    (run [format_event ~id:1 "a" ^ format_event "b"]);
  verify "NUL ID ignored" [{id=None;data="a"}]
    (run ["id: bad\000id\ndata:a\n\n"]);
  verify "spaces are not frame terminator" [{id=None;data="a\nb"}]
    (run ["data:a\n \ndata:b\n\n"]);
  verify "EOF does not dispatch partial frame" [] (run ["data:a\n"]);
  Printf.printf "PASS framing checks=%d events=%d LF_bytes=%d CRLF_bytes=%d\n"
    !checks (List.length expected) (String.length wire) (String.length crlf)

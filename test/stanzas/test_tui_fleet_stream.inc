; The terminal's side of the fleet stream (RFC-0477): the Snapshot and the
; events after it become the reading the Keepers screen draws, a gap or an
; unreadable frame asks for a new connection, and a refusal or a schema this
; build does not read shows until a Snapshot arrives. The screen draws that
; reading only while a job follows the stream.

(test
 (name test_tui_fleet_stream)
 (modules test_tui_fleet_stream)
 (libraries masc masc_tui_fleet_stream masc_tui_types masc.sse_wire alcotest yojson))

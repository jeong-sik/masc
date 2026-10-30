# Tool_result.recorded_call_outcome; present malformed disposition never
# falls back to wire_outcome, success booleans, or nested output text.
def recorded_call_outcome:
  if type != "object" then "malformed"
  elif has("disposition") then
    if .disposition == "completed" then "succeeded"
    elif .disposition == "failed" then "failed"
    elif .disposition == "deferred" then "deferred"
    else "malformed" end
  elif has("wire_outcome") then
    if .wire_outcome == "ok" then "succeeded"
    elif .wire_outcome == "error" then "failed"
    elif .wire_outcome == "unknown" then "unsettled"
    else "malformed" end
  else "unsettled" end;

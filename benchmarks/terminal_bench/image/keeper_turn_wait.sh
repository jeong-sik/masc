#!/usr/bin/env bash
# The wait at the end of probe_keeper_tools.sh, in a file of its own so a test
# can run it against a fake docker and a fake mcp. Source it; it defines one
# function.
#
# masc_keeper_msg returns once the turn is queued, so its result says nothing
# about how the turn ended. The operation id it returns is the handle for that:
# masc_keeper_delegate_status reports Queued, Running, Succeeded, Failed or
# Cancelled for it (the same poll driver/run_episode.sh makes). Waiting on the
# marker alone made a turn that failed in a fraction of a second look the same
# as a slow one for the whole wait.
#
# wait_for_keeper_turn OP_ID
#   Needs NAME (container), MARKER (the path the keeper was asked to create),
#   KEEPER (keeper name), a `mcp ID TOOL ARGS SECS` function and docker on PATH.
#   Optional: WAIT_ROUNDS (90), WAIT_SLEEP_SEC (5), POLL_FAILURE_LIMIT (10).
#   Returns 0 when the marker exists.
#   Returns 1 when the probe failed; the stage and its reason are on stderr.
#   Returns 2 when the rounds ran out while the turn was still Queued or Running.
wait_for_keeper_turn() {
  local op_id="$1"
  local rounds="${WAIT_ROUNDS:-90}"
  local sleep_sec="${WAIT_SLEEP_SEC:-5}"
  local failure_limit="${POLL_FAILURE_LIMIT:-10}"
  local poll_failures=0 status_args st state round

  status_args="$(jq -cn --arg name "${KEEPER}" --arg op "${op_id}" \
    '{target:{kind:"keeper",name:$name}, operation_id:$op}')"

  for (( round = 0; round < rounds; round++ )); do
    # The container is checked on every round, so one that dies mid-wait ends
    # the probe with a reason instead of a poll against nothing.
    if ! docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null | grep -q true; then
      echo "STAGE_FAIL container-died during the keeper turn" >&2
      return 1
    fi
    if docker exec "${NAME}" test -f "${MARKER}" 2>/dev/null; then return 0; fi

    # A failed or empty answer is counted, and only a run of them ends the
    # probe, under its own name, so a broken observation is not reported as a
    # keeper that did nothing.
    st=""
    state=""
    if st="$(mcp 13 masc_keeper_delegate_status "${status_args}" 30)"; then
      state="$(printf '%s' "${st}" | jq -r '.state // empty' 2>/dev/null)"
    fi

    # Keeper_chat_operation.state is a closed set encoded by name: Queued and
    # Running are still working, the other three are terminal. A name outside
    # the set is a state this probe has not been taught, so it ends the probe
    # under that name instead of waiting out the clock.
    case "${state}" in
      Queued|Running) poll_failures=0 ;;
      Succeeded)
        # The keeper's command ran before the turn became Succeeded, so look
        # once more rather than trust the check above, which came earlier.
        if docker exec "${NAME}" test -f "${MARKER}" 2>/dev/null; then return 0; fi
        echo "STAGE_FAIL keeper-turn-Succeeded-without-marker: $(printf '%s' "${st}" | head -c 1200)" >&2
        return 1
        ;;
      Failed|Cancelled)
        echo "STAGE_FAIL keeper-turn-${state}: $(printf '%s' "${st}" | head -c 1200)" >&2
        return 1
        ;;
      "")
        poll_failures=$(( poll_failures + 1 ))
        if [[ "${poll_failures}" -ge "${failure_limit}" ]]; then
          echo "STAGE_FAIL delegate_status-unreadable after ${poll_failures} polls: $(printf '%s' "${st}" | head -c 300)" >&2
          return 1
        fi
        ;;
      *)
        echo "STAGE_FAIL keeper-turn-unknown-state ${state}: $(printf '%s' "${st}" | head -c 1200)" >&2
        return 1
        ;;
    esac
    # Sleep on the host, not with `docker exec sleep`: a container that dies
    # mid-wait turned that into a hot loop printing "is not running" once per
    # iteration instead of stopping with a reason.
    sleep "${sleep_sec}"
  done
  return 2
}

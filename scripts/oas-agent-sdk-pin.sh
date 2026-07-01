#!/usr/bin/env bash

readonly OAS_AGENT_SDK_URL="https://github.com/jeong-sik/oas.git"
readonly OAS_AGENT_SDK_BASE_VERSION="v0.208.10"
# 0.208.10 is a tagged release on OAS main (commit below). Relative to the prior
# 0.208.7 pin it adds: HTTP 402 classified as first-class PaymentRequired rather
# than InvalidRequest (oas#2407), Local compat dialect inference reverted to
# fail-closed (oas#2410), resume config allowed to override thinking policy
# (oas#2412), identity no longer inferred from model id (oas#2373), and a batch
# of provider env-boundary refactors. It retains the typed reasoning-details
# projection and oas#2363's id-keyed streaming tool-call block fix from 0.208.7.
# agent_sdk.opam depends: is unchanged from 0.208.7, so masc.opam.locked only
# moves the three agent_sdk pin lines. The reachability guard in check-oas-pin.sh
# tracks main.
readonly OAS_AGENT_SDK_TRACK_REF="main"
readonly OAS_AGENT_SDK_SHA="72296aa77a888f957204cc9000cbc5f62d24919d"
readonly OAS_AGENT_SDK_MIN_VERSION="0.208.10"

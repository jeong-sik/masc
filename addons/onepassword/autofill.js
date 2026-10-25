async context => {
  // This entire program, its arguments and its result belong to the private
  // backend transport. Never export it as a model tool or log its payload.
  const args = context.arguments;
  const record = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const text = value => typeof value === "string" && value.length > 0;
  const exact = keys => record(args) && Object.keys(args).length === keys.length &&
    keys.every(key => Object.hasOwn(args, key));
  const safeError = response => {
    const code = response?.error?.code;
    switch (code) {
      case "rateLimitExceeded": case "timeout": case "networkError":
      case "agenticModeNotEnabled": case "fillFailed": case "autosubmitFailed":
        return {error: code};
      default: return {error: "provider_failed"};
    }
  };
  const base = ["kind", "access_token", "integration_key"];
  if (!record(args) || !text(args.access_token) || !text(args.integration_key)) {
    return {error: "invalid_request"};
  }
  const api = globalThis.api?.agenticAutofill?.v1;
  if (!api) return {error: "api_unavailable"};
  const auth = {accessToken: args.access_token, integrationKey: args.integration_key};
  // Refuse before calling the provider if the pinned tab has navigated.
  const currentWebsite = async website => {
    try {
      const expected = new URL(website), observed = new URL(context.url);
      if (expected.protocol !== "https:" || observed.protocol !== "https:" ||
          expected.username || expected.password || observed.username || observed.password ||
          expected.origin !== observed.origin || !Number.isSafeInteger(context.tab_id)) return false;
      const tab = await chrome.tabs.get(context.tab_id);
      return tab.id === context.tab_id && tab.url === context.url;
    } catch { return false; }
  };
  switch (args.kind) {
    case "request": {
      if (!exact([...base, "website", "goal", "reason"]) ||
          !text(args.website) || !text(args.goal) || !text(args.reason)) return {error: "invalid_request"};
      if (!await currentWebsite(args.website)) return {error: "target_changed"};
      let response;
      try {
        response = await api.createAccessRequest({...auth, requests: {
          version: 2, goal: args.goal, entries: [{type: "login",
            parameters: {website: args.website}, reason: args.reason}]
        }});
      } catch { return {error: "provider_outcome_unknown"}; }
      if (response?.success !== true) return safeError(response);
      const result = response.result;
      if (!text(result?.accessRequest?.id) || result.accessRequest.entries?.length !== 1 ||
          !text(result.accessRequest.entries[0]?.id) || !text(result.appLink)) {
        return {error: "provider_outcome_unknown"};
      }
      try {
        const link = new URL(result.appLink);
        if (link.protocol !== "onepassword:" || link.hostname !== "grant-brokered-access" ||
            link.username || link.password) return {error: "provider_outcome_unknown"};
      } catch { return {error: "provider_outcome_unknown"}; }
      return {request_id: result.accessRequest.id, entry_id: result.accessRequest.entries[0].id,
        app_link: result.appLink};
    }
    case "status": {
      if (!exact([...base, "request_id", "entry_id"]) ||
          !text(args.request_id) || !text(args.entry_id)) return {error: "invalid_request"};
      let response;
      try { response = await api.getAccessRequestStatus({...auth, accessRequestUUID: args.request_id}); }
      catch { return {error: "provider_outcome_unknown"}; }
      if (response?.success !== true) return safeError(response);
      const result = response.result;
      switch (result?.state) {
        case "pending": case "denied": case "failed": case "expired": return {state: result.state};
        case "resolved": {
          if (!Array.isArray(result.resolved)) return {error: "provider_outcome_unknown"};
          const grants = result.resolved.filter(grant => grant?.entryId === args.entry_id);
          if (grants.length === 0) return {state: "resolved", granted: false};
          if (grants.length !== 1 || !text(grants[0].reference)) return {error: "provider_outcome_unknown"};
          return {state: "resolved", granted: true, reference: grants[0].reference};
        }
        default: return {error: "provider_outcome_unknown"};
      }
    }
    case "fill": {
      if (!exact([...base, "website", "reference"]) || !text(args.reference) || !text(args.website)) {
        return {error: "invalid_request"};
      }
      if (!await currentWebsite(args.website)) return {error: "target_changed"};
      // Any failure after entry is uncertain. Throw a fixed error so the Browser
      // backend fences this original session before it releases the page slot.
      try {
        const response = await api.fillCredential({...auth, resourcePath: args.reference, tabId: context.tab_id});
        if (response?.success === true && response.result?.status === "fill_submitted") {
          return {status: "fill_submitted"};
        }
      } catch { /* Discard provider prose and any credential-bearing exception. */ }
      throw new Error("onepassword_private_outcome_unknown");
    }
    default: return {error: "invalid_request"};
  }
}

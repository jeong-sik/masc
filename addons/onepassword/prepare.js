async () => {
  // Trusted package code, evaluated only in the pinned 1Password worker.
  // The Browser page slot stays held until agentic mode has been enabled.
  const api = globalThis.api;
  if (typeof api?.initialization?.v1?.whenSettled !== "function" ||
      await api.initialization.v1.whenSettled() !== "ready" ||
      typeof api.agenticMode?.v1?.enable !== "function" ||
      !["createAccessRequest", "getAccessRequestStatus", "fillCredential"].every(
        name => typeof api.agenticAutofill?.v1?.[name] === "function")) {
    return {ready: false};
  }
  // No tab argument: ordinary autofill is disabled for the whole owned browser.
  const response = await api.agenticMode.v1.enable();
  return {ready: response?.success === true};
}

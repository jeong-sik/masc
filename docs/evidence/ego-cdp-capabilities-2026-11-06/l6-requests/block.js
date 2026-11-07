async function(page, args, reason) {
  const registry = globalThis.mascBlockedHosts ??= new Map();
  const before = registry.get(args.label) ?? [];
  const hosts = args.hosts === null ? [] : [...new Set([...before, ...args.hosts])].sort();
  try {
    await page.cdp("Network.setBlockedURLs",
      {urlPatterns: hosts.map(host => ({urlPattern: "*://" + host + ":*/*", block: true}))});
  } catch (error) {
    return {ok: false, error: "Network.setBlockedURLs failed: " + reason(error)};
  }
  if (hosts.length === 0) registry.delete(args.label); else registry.set(args.label, hosts);
  return {ok: true, value: args.hosts === null ? {unblocked: before.length} : {blocked: hosts}};
}

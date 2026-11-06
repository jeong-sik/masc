async function(page, args, reason) {
  const read = () => page.evaluate(`(async () => ({
    origin: location.origin,
    locale: Intl.DateTimeFormat().resolvedOptions().locale,
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    geolocationPermission: (await navigator.permissions.query({name: "geolocation"})).state
  }))()`);
  let before;
  try { before = await read(); }
  catch (error) { return {ok: false, before: true, error: "the page could not be read before emulation: " + reason(error)}; }
  const applied = [];
  const stop = (step, error, observed) => applied.length === 0 && observed === null
    ? {ok: false, before: true, error: step + ": " + error}
    : {ok: true, value: {applied, failed: {step, error}, before, observed}};
  const steps = [];
  let canonical = {};
  if (args.clear) {
    steps.push(["geolocation", "Emulation.clearGeolocationOverride", {}],
      ["locale", "Emulation.setLocaleOverride", {}],
      ["timezone", "Emulation.setTimezoneOverride", {timezoneId: ""}]);
  } else {
    try {
      canonical = await page.evaluate(`(() => {
        const zone = ${JSON.stringify(args.timezone)}, locale = ${JSON.stringify(args.locale)}, out = {};
        if (zone !== null) {
          try { out.timezone = new Intl.DateTimeFormat("en-US", {timeZone: zone}).resolvedOptions().timeZone; }
          catch (error) { out.timezoneError = String(error && error.message || error); }
        }
        if (locale !== null) {
          try { out.locale = Intl.getCanonicalLocales(locale)[0]; }
          catch (error) { out.localeError = String(error && error.message || error); }
        }
        return out;
      })()`);
    } catch (error) { return {ok: false, before: true, error: "the page could not check the locale and time zone: " + reason(error)}; }
    if (canonical.timezoneError !== undefined)
      return {ok: false, before: true, error: "the page knows no time zone " + JSON.stringify(args.timezone) + ": " + canonical.timezoneError};
    if (canonical.localeError !== undefined)
      return {ok: false, before: true, error: "the page takes no locale " + JSON.stringify(args.locale) + ": " + canonical.localeError};
    if (canonical.locale !== undefined) steps.push(["locale", "Emulation.setLocaleOverride", {locale: canonical.locale}]);
    if (canonical.timezone !== undefined) steps.push(["timezone", "Emulation.setTimezoneOverride", {timezoneId: canonical.timezone}]);
    if (args.geolocation !== null) {
      if (before.origin !== "null")
        steps.push(["geolocation_grant", "Browser.setPermission",
          {permission: {name: "geolocation"}, setting: "granted", origin: before.origin}]);
      steps.push(["geolocation", "Emulation.setGeolocationOverride", {latitude: args.geolocation.latitude,
        longitude: args.geolocation.longitude, accuracy: args.geolocation.accuracy}]);
    }
  }
  for (const [step, method, params] of steps) {
    try { await page.cdp(method, params); applied.push(step); }
    catch (error) { return stop(step, reason(error), null); }
  }
  let observed;
  try { observed = await read(); }
  catch (error) { return stop("observe", reason(error), null); }
  if (canonical.timezone !== undefined && observed.timeZone !== canonical.timezone)
    return stop("timezone", "the page reports " + observed.timeZone + " after the override to " + canonical.timezone, observed);
  return {ok: true, value: {applied, before, observed,
    geolocationGrant: applied.includes("geolocation_grant") ? before.origin : null,
    emulated: args.clear ? null : {locale: canonical.locale ?? null, timezone: canonical.timezone ?? null,
      geolocation: args.geolocation}}};
}

export function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--")) continue;
    args[key.slice(2)] = value;
    i += 1;
  }
  return args;
}

export function parseCookieHeader(cookieHeader) {
  if (!cookieHeader || !cookieHeader.trim()) return [];
  return cookieHeader
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const eq = part.indexOf("=");
      if (eq <= 0) return null;
      return { name: part.slice(0, eq).trim(), value: part.slice(eq + 1).trim() };
    })
    .filter(Boolean);
}

export function pickBrowser(name, browsers) {
  const lower = String(name || "chromium").toLowerCase();
  if (lower === "firefox") return browsers.firefox;
  if (lower === "webkit") return browsers.webkit;
  return browsers.chromium;
}

export async function withBrowser(browserType, callback) {
  const browser = await browserType.launch({ headless: true });
  try {
    return await callback(browser);
  } finally {
    await browser.close();
  }
}

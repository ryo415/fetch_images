#!/usr/bin/env node

import fs from "node:fs";
import { chromium, firefox, webkit } from "playwright";

function parseArgs(argv) {
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

function parseCookieHeader(cookieHeader) {
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

function pickBrowser(name) {
  const lower = String(name || "chromium").toLowerCase();
  if (lower === "firefox") return firefox;
  if (lower === "webkit") return webkit;
  return chromium;
}

function buildCookieTargets(url, postUrl) {
  const targets = new Set([
    "https://www.fanbox.cc",
    "https://api.fanbox.cc"
  ]);
  try {
    const u = new URL(url);
    targets.add(`${u.protocol}//${u.host}`);
  } catch {
    // ignore
  }
  try {
    const u = new URL(postUrl);
    targets.add(`${u.protocol}//${u.host}`);
  } catch {
    // ignore
  }
  return [...targets];
}

function extractCreatorAndPostId(url, fallbackPostId) {
  try {
    const u = new URL(url);
    const host = u.host.toLowerCase();
    const path = u.pathname;

    if (host.endsWith(".fanbox.cc")) {
      const creator = host.replace(".fanbox.cc", "");
      return { creator, postId: fallbackPostId };
    }

    const m = path.match(/^\/@([^/]+)\/posts\/(\d+)/);
    if (m) return { creator: m[1], postId: m[2] };
  } catch {
    // ignore
  }
  return { creator: null, postId: String(fallbackPostId || "") };
}

async function main() {
  const args = parseArgs(process.argv);
  const url = args.url;
  const postId = args["post-id"];
  const output = args.output;
  const browserName = args.browser || "chromium";

  if (!url || !postId || !output) {
    throw new Error("Missing required args: --url --post-id --output");
  }

  const browserType = pickBrowser(browserName);
  const browser = await browserType.launch({ headless: true });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    locale: "ja-JP"
  });

  const cookieHeader = process.env.FANBOX_COOKIE_HEADER || "";
  const cookies = parseCookieHeader(cookieHeader);
  if (cookies.length > 0) {
    const targets = buildCookieTargets(url, `https://www.fanbox.cc/`);
    const playwrightCookies = [];
    for (const target of targets) {
      for (const cookie of cookies) {
        playwrightCookies.push({
          name: cookie.name,
          value: cookie.value,
          url: target
        });
      }
    }
    await context.addCookies(playwrightCookies);
  }

  const page = await context.newPage();
  const parsed = extractCreatorAndPostId(url, postId);
  const canonicalUrl = parsed.creator
    ? `https://www.fanbox.cc/@${parsed.creator}/posts/${parsed.postId}`
    : url;

  let capturedApiPayload = null;
  let capturedApiStatus = null;
  let capturedApiBody = "";
  page.on("response", async (response) => {
    try {
      const responseUrl = response.url();
      if (!responseUrl.includes("api.fanbox.cc/post.info")) return;
      capturedApiStatus = response.status();
      const text = await response.text();
      capturedApiBody = text.slice(0, 500);
      if (!response.ok()) return;
      capturedApiPayload = JSON.parse(text);
    } catch {
      // ignore
    }
  });

  await page.goto(canonicalUrl, { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.waitForTimeout(5000);
  if (capturedApiPayload) {
    fs.writeFileSync(output, JSON.stringify(capturedApiPayload));
    await browser.close();
    return;
  }

  let browserFetchResult = { ok: false, status: 0, text: "", error: "" };
  try {
    browserFetchResult = await page.evaluate(async ({ postId }) => {
      const metaRaw = document.querySelector("meta#metadata")?.getAttribute("content") || "";
      let csrfToken = "";
      try {
        const parsed = JSON.parse(metaRaw);
        csrfToken = parsed?.csrfToken || "";
      } catch {
        csrfToken = "";
      }

      try {
        const response = await fetch(`https://api.fanbox.cc/post.info?postId=${postId}`, {
          method: "GET",
          credentials: "include",
          headers: {
            Accept: "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
            ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
          }
        });
        const text = await response.text();
        return { ok: response.ok, status: response.status, text, error: "" };
      } catch (error) {
        return { ok: false, status: 0, text: "", error: String(error) };
      }
    }, { postId });
  } catch (error) {
    browserFetchResult = { ok: false, status: 0, text: "", error: String(error) };
  }

  if (browserFetchResult.ok) {
    const data = JSON.parse(browserFetchResult.text);
    fs.writeFileSync(output, JSON.stringify(data));
    await browser.close();
    return;
  }

  // Fallback: Playwright APIRequestContext direct call.
  const apiUrl = `https://api.fanbox.cc/post.info?postId=${postId}`;
  const response = await page.request.get(apiUrl, {
    headers: {
      Accept: "application/json, text/plain, */*",
      Referer: url,
      Origin: new URL(url).origin,
      "X-Requested-With": "XMLHttpRequest"
    },
    timeout: 30000
  });

  if (!response.ok()) {
    const browserBody = (browserFetchResult.text || "").slice(0, 300);
    const body = (await response.text()).slice(0, 300);
    throw new Error(
      `Playwright API failed: ` +
      `capturedApiStatus=${capturedApiStatus || "none"} capturedApiBody=${capturedApiBody} | ` +
      `browserFetch=${browserFetchResult.status} ${browserBody} browserFetchError=${browserFetchResult.error} | ` +
      `requestContext=${response.status()} ${body}`
    );
  }

  const data = await response.json();
  fs.writeFileSync(output, JSON.stringify(data));
  await browser.close();
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});

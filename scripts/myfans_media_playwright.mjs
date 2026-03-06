#!/usr/bin/env node

import fs from "node:fs";
import { chromium, firefox, webkit } from "playwright";

const VIDEO_EXT_RE = /\.(mp4|webm|mov|m4v|m3u8)(\?|$)/i;
const IMAGE_EXT_RE = /\.(jpe?g|png|gif|bmp|webp|avif)(\?|$)/i;

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
      const idx = part.indexOf("=");
      if (idx <= 0) return null;
      return { name: part.slice(0, idx).trim(), value: part.slice(idx + 1).trim() };
    })
    .filter(Boolean);
}

function pickBrowser(name) {
  const lower = String(name || "chromium").toLowerCase();
  if (lower === "firefox") return firefox;
  if (lower === "webkit") return webkit;
  return chromium;
}

function likelyVideoUrl(url) {
  try {
    const u = new URL(url);
    const path = u.pathname.toLowerCase();
    const query = u.search.toLowerCase();
    if (path.startsWith("/api/")) return false;
    if (/\.(ts|m4s|aac|vtt)(\?|$)/i.test(path)) return false;
    if (IMAGE_EXT_RE.test(path)) return false;
    if (VIDEO_EXT_RE.test(path)) return true;
    if (/(^|\/)(video|videos|movie|movies|stream|playback|manifest|playlist|hls|dash|vod)(\/|$)/i.test(path)) return true;
    if (/(mp4|m3u8|hls|stream|playback|manifest|playlist|mime=video|content[_-]?type=video)/i.test(query)) return true;
    return u.hostname.toLowerCase().includes("video");
  } catch {
    return false;
  }
}

function likelyImageUrl(url) {
  try {
    const u = new URL(url);
    return IMAGE_EXT_RE.test(u.pathname.toLowerCase());
  } catch {
    return false;
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const url = args.url;
  const output = args.output;
  const browserName = args.browser || "chromium";
  if (!url || !output) throw new Error("Missing required args: --url --output");

  const browserType = pickBrowser(browserName);
  const browser = await browserType.launch({ headless: true });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    locale: "ja-JP"
  });

  const cookieHeader = process.env.MYFANS_COOKIE_HEADER || "";
  const cookies = parseCookieHeader(cookieHeader);
  if (cookies.length > 0) {
    const origin = new URL(url).origin;
    await context.addCookies(
      cookies.map((cookie) => ({
        name: cookie.name,
        value: cookie.value,
        url: origin
      }))
    );
  }

  const videos = new Set();
  const images = new Set();
  const page = await context.newPage();

  const collect = (candidate) => {
    if (!candidate || typeof candidate !== "string") return;
    if (likelyVideoUrl(candidate)) {
      videos.add(candidate);
    } else if (likelyImageUrl(candidate)) {
      images.add(candidate);
    }
  };

  const collectFromJson = (value) => {
    if (typeof value === "string") {
      collect(value);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) collectFromJson(item);
      return;
    }
    if (value && typeof value === "object") {
      for (const v of Object.values(value)) collectFromJson(v);
    }
  };

  page.on("request", (req) => collect(req.url()));
  page.on("response", async (res) => {
    const responseUrl = res.url();
    collect(responseUrl);
    if (!/\/api\/v2\/posts\/[^/]+\/videos/i.test(responseUrl)) return;
    if (!res.ok()) return;
    try {
      const data = await res.json();
      collectFromJson(data);
    } catch {
      // ignore JSON parse errors
    }
  });

  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForTimeout(8000);

  const domMedia = await page.evaluate(() => {
    const out = [];
    for (const node of document.querySelectorAll("video, source, img")) {
      for (const attr of ["src", "data-src", "data-video-src", "data-original", "data-lazy-src"]) {
        const v = node.getAttribute(attr);
        if (v) out.push(v);
      }
      for (const attr of ["srcset", "data-srcset"]) {
        const srcset = node.getAttribute(attr);
        if (!srcset) continue;
        for (const entry of srcset.split(",")) {
          const first = entry.trim().split(/\s+/, 2)[0];
          if (first) out.push(first);
        }
      }
    }
    return out;
  });
  domMedia.forEach((u) => collect(new URL(u, url).toString()));

  fs.writeFileSync(
    output,
    JSON.stringify(
      {
        videos: [...videos],
        images: [...images]
      },
      null,
      2
    )
  );
  await browser.close();
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});

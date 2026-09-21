import test from "node:test";
import assert from "node:assert/strict";

import {
  parseArgs,
  parseCookieHeader,
  pickBrowser,
  withBrowser
} from "../scripts/playwright_support.mjs";

test("parsing preserves equals in cookies and last argument value", () => {
  assert.deepEqual(parseCookieHeader(" a=b=c; invalid; x=y "), [
    { name: "a", value: "b=c" },
    { name: "x", value: "y" }
  ]);
  assert.deepEqual(
    parseArgs(["node", "helper", "--browser", "webkit", "--browser", "firefox"]),
    { browser: "firefox" }
  );

  const browsers = { chromium: {}, firefox: {}, webkit: {} };
  assert.equal(pickBrowser("FIREFOX", browsers), browsers.firefox);
  assert.equal(pickBrowser("unknown", browsers), browsers.chromium);
});

test("browser closes on success and exceptions", async () => {
  let closed = 0;
  const browser = { close: async () => { closed += 1; } };
  const type = {
    launch: async (options) => {
      assert.deepEqual(options, { headless: true });
      return browser;
    }
  };

  assert.equal(
    await withBrowser(type, async (value) => {
      assert.equal(value, browser);
      return 42;
    }),
    42
  );

  const failure = new Error("navigation failed");
  await assert.rejects(
    withBrowser(type, async () => { throw failure; }),
    (error) => error === failure
  );
  assert.equal(closed, 2);
});

test("browser closes once when the callback returns early", async () => {
  let closed = 0;
  const browser = { close: async () => { closed += 1; } };
  const type = { launch: async () => browser };

  const runFanboxBranch = () => withBrowser(type, async () => {
    return;
  });

  assert.equal(await runFanboxBranch(), undefined);
  assert.equal(closed, 1);
});

test("launch failure skips the callback", async () => {
  const failure = new Error("browser unavailable");
  let callbackCalled = false;
  const type = { launch: async () => { throw failure; } };

  await assert.rejects(
    withBrowser(type, async () => { callbackCalled = true; }),
    (error) => error === failure
  );
  assert.equal(callbackCalled, false);
});

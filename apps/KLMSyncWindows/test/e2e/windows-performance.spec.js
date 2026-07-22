const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { _electron: electron, expect, test } = require("@playwright/test");
const { FakeRelay, TEST_TOKEN } = require("./fake-relay.cjs");

const appRoot = path.resolve(__dirname, "../..");
const electronEntry = path.join(__dirname, "electron-entry.cjs");
const metricsPath = path.join(
  appRoot,
  "output",
  "playwright",
  "windows-2000-item-performance-metrics.json"
);
const expectedItemCount = 2_000;
const intentionalInitialRowCap = 120;
const thresholds = Object.freeze({
  initialReconciliationRenderMs: 2_500,
  searchInputToVisibleResultMs: 750,
  webSocketUpdateToVisibleResultMs: 1_000,
  maximumScrollDriftPx: 16
});

let electronApp;
let page;
let relay;
let fixture;
let testProfile;
const pageErrors = [];

test.beforeAll(async () => {
  relay = await FakeRelay.start();
  fixture = relay.seedPerformanceItems(expectedItemCount);
  testProfile = await fs.mkdtemp(path.join(os.tmpdir(), "klms-windows-performance-"));
  electronApp = await electron.launch({
    args: [electronEntry, "--disable-gpu"],
    cwd: appRoot,
    env: {
      ...process.env,
      KLMS_E2E_USER_DATA_DIR: testProfile,
      ELECTRON_DISABLE_SECURITY_WARNINGS: "true"
    }
  });
  page = await electronApp.firstWindow();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.waitForLoadState("domcontentloaded");
});

test.afterAll(async () => {
  await electronApp?.close();
  await relay?.close();
  if (testProfile) {
    await fs.rm(testProfile, { recursive: true, force: true });
  }
});

test("2,000 mixed items stay responsive through reconciliation, search, scroll focus and one WebSocket update", async () => {
  expect(fixture.itemCount).toBe(expectedItemCount);
  expect(fixture.searchIndex).toBeLessThan(expectedItemCount - intentionalInitialRowCap);

  await page.evaluate(({ relayURL, relayToken }) => {
    document.querySelector("#relayURL").value = relayURL;
    document.querySelector("#relayToken").value = relayToken;
    window.__klmsPerformanceInitialStart = performance.now();
    document.querySelector("#saveConnectionButton").click();
  }, { relayURL: relay.url, relayToken: TEST_TOKEN });
  await page.waitForFunction(({ itemCount, visibleItemCount, initialRowCap }) => (
    state.items.length === itemCount
      && document.querySelector("#listCount")?.textContent === `${visibleItemCount}개`
      && document.querySelectorAll("#itemList > .item-row").length === initialRowCap + 1
      && document.querySelector("#connectionState")?.textContent === "실시간 연결됨"
  ), {
    itemCount: expectedItemCount,
    visibleItemCount: fixture.visibleItemCount,
    initialRowCap: intentionalInitialRowCap
  });
  const initialReconciliationRenderMs = await page.evaluate(() => (
    performance.now() - window.__klmsPerformanceInitialStart
  ));

  const initialRenderState = await page.evaluate(({ searchItemID }) => ({
    stateItemCount: state.items.length,
    renderedDataRows: document.querySelectorAll("#itemList > .item-row:not(.show-more-row)").length,
    showMoreRows: document.querySelectorAll("#itemList > .show-more-row").length,
    searchTargetAlreadyRendered: Array.from(document.querySelectorAll("#itemList > .item-row"))
      .some((row) => row.dataset.focusKey === `item:${searchItemID}`),
    listCount: document.querySelector("#listCount")?.textContent || "",
    remainingText: document.querySelector("#itemList > .show-more-row .meta")?.textContent || ""
  }), { searchItemID: fixture.searchItemID });

  expect(initialRenderState.stateItemCount).toBe(expectedItemCount);
  expect(initialRenderState.renderedDataRows).toBe(intentionalInitialRowCap);
  expect(initialRenderState.showMoreRows).toBe(1);
  expect(initialRenderState.searchTargetAlreadyRendered).toBe(false);
  expect(initialRenderState.listCount).toBe(`${fixture.visibleItemCount}개`);
  expect(initialRenderState.remainingText).toBe(`${fixture.visibleItemCount - intentionalInitialRowCap}개 남음`);

  const searchInput = page.locator("#searchInput");
  await page.evaluate(({ searchItemID }) => {
    const input = document.querySelector("#searchInput");
    const list = document.querySelector("#itemList");
    window.__klmsPerformanceSearchResult = new Promise((resolve) => {
      let startedAt = 0;
      const completeWhenVisible = () => {
        if (!startedAt) return;
        const target = Array.from(list.querySelectorAll(".item-row"))
          .find((row) => row.dataset.focusKey === `item:${searchItemID}`);
        if (!target) return;
        observer.disconnect();
        resolve({
          elapsedMs: performance.now() - startedAt,
          renderedRows: list.querySelectorAll(".item-row:not(.show-more-row)").length,
          title: target.querySelector(".title")?.textContent || ""
        });
      };
      const observer = new MutationObserver(completeWhenVisible);
      input.addEventListener("input", () => {
        startedAt = performance.now();
        observer.observe(list, { childList: true, subtree: true });
        completeWhenVisible();
      }, { once: true });
    });
  }, { searchItemID: fixture.searchItemID });
  await searchInput.fill(fixture.searchQuery);
  const searchResult = await page.evaluate(() => window.__klmsPerformanceSearchResult);

  expect(searchResult.renderedRows).toBe(1);
  expect(searchResult.title).toBe(fixture.searchTitle);
  await expect(page.locator("#listCount")).toHaveText("1개");
  await expect(page.locator(`[data-focus-key="item:${fixture.searchItemID}"]`)).toBeVisible();

  await searchInput.fill("");
  await expect(page.locator("#listCount")).toHaveText(`${fixture.visibleItemCount}개`);
  const focusRow = page.locator(`[data-focus-key="item:${fixture.focusItemID}"]`);
  await expect(focusRow).toBeVisible();
  const scrollFocusBefore = await focusRow.evaluate((row) => {
    const list = row.closest("#itemList");
    list.scrollTop = Math.max(0, row.offsetTop - 24);
    row.focus({ preventScroll: true });
    return {
      focusKey: document.activeElement?.dataset?.focusKey || "",
      scrollTop: list.scrollTop,
      maximumScrollTop: list.scrollHeight - list.clientHeight
    };
  });
  expect(scrollFocusBefore.focusKey).toBe(`item:${fixture.focusItemID}`);
  expect(scrollFocusBefore.scrollTop).toBeGreaterThan(200);

  const requestsBeforeUpdate = relay.requestCount;
  await page.evaluate(({ focusItemID, focusUpdatedTitle }) => {
    const list = document.querySelector("#itemList");
    window.__klmsPerformanceWebSocketResult = new Promise((resolve) => {
      const startedAt = performance.now();
      const completeWhenVisible = () => {
        const target = Array.from(list.querySelectorAll(".item-row"))
          .find((row) => row.dataset.focusKey === `item:${focusItemID}`);
        if (!target?.textContent.includes(focusUpdatedTitle)) return;
        observer.disconnect();
        window.requestAnimationFrame(() => resolve({
          elapsedMs: performance.now() - startedAt,
          focusKey: document.activeElement?.dataset?.focusKey || "",
          scrollTop: list.scrollTop,
          targetTitle: target.querySelector(".title")?.textContent || ""
        }));
      };
      const observer = new MutationObserver(completeWhenVisible);
      observer.observe(list, { childList: true, subtree: true });
      completeWhenVisible();
    });
  }, {
    focusItemID: fixture.focusItemID,
    focusUpdatedTitle: fixture.focusUpdatedTitle
  });
  const publishedRevision = relay.publishItemUpdate(fixture.focusItemID, {
    title: fixture.focusUpdatedTitle,
    status: "실시간 반영"
  });
  const webSocketResult = await page.evaluate(() => window.__klmsPerformanceWebSocketResult);
  await page.waitForFunction((revision) => state.relayRevision === revision, publishedRevision);

  const requestCountAfterRealtimeUpdate = await waitForStableRequestCount(relay);
  await new Promise((resolve) => setTimeout(resolve, 750));
  const requestCountAfterIdle = relay.requestCount;
  const updateRequests = relay.requests.slice(requestsBeforeUpdate);
  const pollingRequests = relay.requests.filter((request) => (
    /events\/poll|waitSeconds/i.test(request.path)
  ));
  const environment = await electronApp.evaluate(() => ({
    platform: process.platform,
    architecture: process.arch,
    electron: process.versions.electron,
    chromium: process.versions.chrome,
    node: process.versions.node
  }));
  const scrollDriftPx = Math.abs(webSocketResult.scrollTop - scrollFocusBefore.scrollTop);
  const metrics = {
    schemaVersion: 1,
    fixture: {
      itemCount: fixture.itemCount,
      visibleItemCount: fixture.visibleItemCount,
      distribution: fixture.distribution,
      intentionalInitialRowCap,
      searchTargetIndex: fixture.searchIndex,
      searchTargetWasOutsideInitialRows: !initialRenderState.searchTargetAlreadyRendered
    },
    thresholdsMs: {
      initialReconciliationRender: thresholds.initialReconciliationRenderMs,
      searchInputToVisibleResult: thresholds.searchInputToVisibleResultMs,
      webSocketUpdateToVisibleResult: thresholds.webSocketUpdateToVisibleResultMs
    },
    measurementsMs: {
      initialReconciliationRender: rounded(initialReconciliationRenderMs),
      searchInputToVisibleResult: rounded(searchResult.elapsedMs),
      webSocketUpdateToVisibleResult: rounded(webSocketResult.elapsedMs)
    },
    scrollAndFocus: {
      focusKeyBefore: scrollFocusBefore.focusKey,
      focusKeyAfter: webSocketResult.focusKey,
      scrollTopBefore: rounded(scrollFocusBefore.scrollTop),
      scrollTopAfter: rounded(webSocketResult.scrollTop),
      scrollDriftPx: rounded(scrollDriftPx),
      maximumAllowedScrollDriftPx: thresholds.maximumScrollDriftPx
    },
    transport: {
      webSocketUpgradeCount: relay.upgrades.length,
      webSocketRevision: publishedRevision,
      realtimeHTTPRequests: updateRequests.map((request) => request.path),
      pollingRequestCount: pollingRequests.length,
      pollingObserved: pollingRequests.length > 0,
      idleHTTPBaseline: requestCountAfterRealtimeUpdate,
      idleHTTPAfter750ms: requestCountAfterIdle,
      idleHTTPDelta: requestCountAfterIdle - requestCountAfterRealtimeUpdate
    },
    environment
  };

  await fs.mkdir(path.dirname(metricsPath), { recursive: true });
  await fs.writeFile(metricsPath, `${JSON.stringify(metrics, null, 2)}\n`, "utf8");
  await test.info().attach("windows-2000-item-performance-metrics", {
    path: metricsPath,
    contentType: "application/json"
  });

  expect(initialReconciliationRenderMs).toBeLessThanOrEqual(thresholds.initialReconciliationRenderMs);
  expect(searchResult.elapsedMs).toBeLessThanOrEqual(thresholds.searchInputToVisibleResultMs);
  expect(webSocketResult.elapsedMs).toBeLessThanOrEqual(thresholds.webSocketUpdateToVisibleResultMs);
  expect(webSocketResult.targetTitle).toBe(fixture.focusUpdatedTitle);
  expect(webSocketResult.focusKey).toBe(scrollFocusBefore.focusKey);
  expect(scrollDriftPx).toBeLessThanOrEqual(thresholds.maximumScrollDriftPx);
  expect(publishedRevision).toBe(1);
  expect(relay.upgrades).toEqual(["/v1/events?role=client&sinceRevision=0"]);
  expect(updateRequests).toEqual([]);
  expect(pollingRequests).toEqual([]);
  expect(requestCountAfterIdle).toBe(requestCountAfterRealtimeUpdate);
  expect(pageErrors).toEqual([]);
});

async function waitForStableRequestCount(targetRelay, stableMilliseconds = 350, timeoutMilliseconds = 5_000) {
  const startedAt = Date.now();
  let stableSince = startedAt;
  let previousCount = targetRelay.requestCount;
  while (Date.now() - startedAt < timeoutMilliseconds) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    const currentCount = targetRelay.requestCount;
    if (currentCount !== previousCount) {
      previousCount = currentCount;
      stableSince = Date.now();
    } else if (Date.now() - stableSince >= stableMilliseconds) {
      return currentCount;
    }
  }
  throw new Error("performance relay HTTP requests did not become idle");
}

function rounded(value) {
  return Math.round(Number(value) * 10) / 10;
}

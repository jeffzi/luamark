// Run Defold HTML5 bundle in headless Chromium and verify test results.
// The Lua test script signals results via document.title (PASS/FAIL)
// because the Defold engine runs in a web worker whose console output
// is not visible to the browser's main thread.
// Usage: node test_html5.mjs <bundle_dir>

import { chromium } from "playwright";
import { createServer } from "http";
import { readFile } from "fs/promises";
import { join, extname } from "path";

const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".wasm": "application/wasm",
  ".json": "application/json",
};

const bundleDir = process.argv[2] || "bundle/luamark-defold-test";

const server = createServer(async (req, res) => {
  const filePath = join(bundleDir, req.url === "/" ? "index.html" : req.url);
  try {
    const data = await readFile(filePath);
    res.writeHead(200, {
      "Content-Type": MIME[extname(filePath)] || "application/octet-stream",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
});

await new Promise((resolve) => server.listen(0, resolve));
const url = `http://localhost:${server.address().port}`;
console.log(`Serving ${bundleDir} at ${url}`);

const browser = await chromium.launch({
  args: [
    "--use-gl=angle",
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
  ],
});
const page = await browser.newPage();

page.on("pageerror", (err) => console.error(`[pageerror] ${err.message}`));

await page.goto(url);

// Poll document.title for test result (set by Lua via html5.run).
const deadline = Date.now() + 60_000;
let title = "";
while (Date.now() < deadline) {
  title = await page.title();
  if (title.startsWith("PASS") || title.startsWith("FAIL")) break;
  await new Promise((r) => setTimeout(r, 500));
}

console.log(`Result: ${title}`);

await browser.close();
server.close();

if (title.startsWith("PASS")) {
  process.exit(0);
} else {
  console.error("FAIL: luamark tests did not pass in HTML5 build");
  process.exit(1);
}

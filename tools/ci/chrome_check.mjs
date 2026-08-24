// Chrome scope-duplication and provenance check (design note §Tests item 8).
//
// 1. No identifier exported by `window.ChorusChrome` may be re-declared as a
//    top-level `function`/`var`/`let`/`const` in client/renderer.js. A hoisted
//    game-side duplicate shadows the chrome one and nothing else notices
//    (cogame-tandem, 2026-08-23).
// 2. client/chrome.css must be byte-identical to
//    cogame-bullwhip/client/chrome.css outside the single appended
//    "chorus additions" block.
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

// cogame-bullwhip/client/chrome.css at the commit this repo forked from.
const INHERITED_BYTES = 11964;
const INHERITED_SHA256 =
  "2bfa94435b037f031c7b54db8c5515a0853c2259003d84a328df50cbf6e54190";
const MARKER = "/* ---------- chorus additions ---------- */";

let failed = 0;
function fail(message) {
  console.error("::error::" + message);
  failed = 1;
}

const chrome = readFileSync("client/chrome_common.js", "utf8");
const renderer = readFileSync("client/renderer.js", "utf8");

const exportBlock = chrome.match(
  /window\.ChorusChrome\s*=\s*\{([\s\S]*?)\n\s*\};/
);
if (!exportBlock) {
  fail("client/chrome_common.js does not export window.ChorusChrome");
} else {
  const keys = [...exportBlock[1].matchAll(/^\s*([A-Za-z_$][\w$]*)\s*:/gm)]
    .map((m) => m[1]);
  if (keys.length < 12) {
    fail("ChorusChrome exports only " + keys.length +
      " names; the inherited chrome surface is larger than that");
  }
  const shadowed = keys.filter((key) =>
    new RegExp("^\\s*(?:function|var|let|const)\\s+" + key + "\\b", "m")
      .test(renderer)
  );
  if (shadowed.length) {
    fail("client/renderer.js re-declares ChorusChrome name(s) at top level: " +
      shadowed.join(", ") +
      " — rename the game-side one (see buildChorusScrub / chorusMarkBeat)");
  }
  console.log("chrome exports checked: " + keys.length + " names, " +
    shadowed.length + " shadowed");
}

if (!/\bvar\s+C\s*=\s*window\.ChorusChrome\s*;/.test(renderer)) {
  fail("client/renderer.js must reach the chrome through " +
    "`var C = window.ChorusChrome;` rather than copying it");
}

const css = readFileSync("client/chrome.css");
const marker = css.indexOf(MARKER);
if (marker < 0) {
  fail("client/chrome.css is missing the '" + MARKER + "' banner");
} else {
  // The appended block starts with a blank line before the banner.
  const prefix = css.subarray(0, INHERITED_BYTES);
  const sha = createHash("sha256").update(prefix).digest("hex");
  if (sha !== INHERITED_SHA256) {
    fail("client/chrome.css's first " + INHERITED_BYTES + " bytes are no " +
      "longer cogame-bullwhip's chrome.css (sha256 " + sha + " != " +
      INHERITED_SHA256 + "). Chorus appends; it never edits an inherited rule.");
  }
  if (marker < INHERITED_BYTES) {
    fail("the chorus additions banner appears inside the inherited chrome");
  }
  console.log("chrome.css provenance ok: " + INHERITED_BYTES +
    " inherited bytes, additions start at byte " + marker);
}

process.exit(failed);

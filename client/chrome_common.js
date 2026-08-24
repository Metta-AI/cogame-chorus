// Chorus chrome module — the inherited cogame-bullwhip broadcast chrome.
//
// Every function and constant below is `cogame-bullwhip/client/renderer.js`'s
// own, copied character for character with no edits: assetUrl, loadImages,
// seatColor, ellipsize, hexToRgb, rgba, roundRect, wrapLines, escapeHtml,
// clampName, isBaselineFiller, makeNameMap, applyNames, makeEffects,
// bindFeedToggle, and the palette constants COLORS, COLOR_HEX, PAPER,
// PAPER_DIM, INK, AMBER, GHOST, STRIP.
//
// The only lines that are NOT the starter's are this IIFE wrapper, the
// `window.ChorusChrome` export at the bottom, and ONE clearly-marked added
// function, relayout(), which publishes --topband / --band / --hudscale on
// :root. Nothing transplanted is rewritten, reindented or renamed.
//
// client/renderer.js (the chorus game renderer) reads this module through a
// single `C` alias and never re-declares any name exported here: a hoisted
// game-side `function markBeat` shadowing a chrome alias is exactly how
// cogame-tandem shipped an unlabelled, unclickable scrubber with every static
// grep green (2026-08-23).
(function () {
  "use strict";

  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var STRIP = "rgba(242, 232, 216, 0.06)";

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  function makeEffects() {
    var seen = 0;
    var weekAt = null;
    var orderAt = [null, null, null, null];
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "week") {
            weekAt = animate ? now : null;
            orderAt = [null, null, null, null];
          } else if (event.kind === "order") {
            orderAt[event.stage] = animate ? now : null;
            if (event.say) {
              lastSay[event.stage] = event.say;
              sayAt[event.stage] = animate ? now : null;
            }
          }
        }
      },
      reset: function () {
        seen = 0; weekAt = null;
        orderAt = [null, null, null, null];
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
      },
      view: function () {
        return { effects: { weekAt: weekAt, orderAt: orderAt.slice(),
          sayAt: sayAt.slice(), lastSay: lastSay.slice() } };
      }
    };
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---------- chorus addition ----------
  // The one function in this file that is not the starter's. It measures the
  // chrome bands and publishes them on :root so every chorus-added measure
  // derives from --hudscale, never from the raw viewport. It runs on load, on
  // every resize, and — because bindFeedToggle dispatches a resize — after
  // every LOG toggle.
  function relayout() {
    var root = document.documentElement;
    var stage = document.getElementById("stage");
    var topband = document.getElementById("topband");
    var transport = document.getElementById("transport");
    var topH = topband ? topband.getBoundingClientRect().height : 0;
    var bandH = transport ? transport.getBoundingClientRect().height : 0;
    var stageW = stage ? stage.getBoundingClientRect().width :
      (window.innerWidth || 960);
    var scale = Math.max(0.7, Math.min(1.6, (stageW || 960) / 960));
    root.style.setProperty("--topband", Math.round(topH) + "px");
    root.style.setProperty("--band", Math.round(bandH) + "px");
    root.style.setProperty("--hudscale",
      String(Math.round(scale * 1000) / 1000));
  }
  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);
  // ---------- end chorus addition ----------

  window.ChorusChrome = {
    COLORS: COLORS,
    COLOR_HEX: COLOR_HEX,
    PAPER: PAPER,
    PAPER_DIM: PAPER_DIM,
    INK: INK,
    AMBER: AMBER,
    GHOST: GHOST,
    STRIP: STRIP,
    assetUrl: assetUrl,
    loadImages: loadImages,
    seatColor: seatColor,
    ellipsize: ellipsize,
    hexToRgb: hexToRgb,
    rgba: rgba,
    roundRect: roundRect,
    wrapLines: wrapLines,
    escapeHtml: escapeHtml,
    clampName: clampName,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    makeEffects: makeEffects,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();

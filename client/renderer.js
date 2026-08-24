// Chorus stage renderer + drivers.
//
// One canvas scene — the sequencer as the score itself: a chord ribbon over a
// four-lane piano roll (one lane per VOICE, blocks coloured by the SEAT that
// owns that voice, vertical position = pitch), an amber playhead sweeping the
// bar being read, and under it a score strip charting the piece score and the
// four counterfactual CREDIT lines against a zero rule — credit assignment,
// drawn.
//
// The broadcast chrome (palette, name mapping, feed toggle, layout variables)
// lives in client/chrome_common.js and is reached through the single `C`
// alias below. Nothing in this file re-declares a name that ChorusChrome
// exports; a hoisted duplicate would silently shadow the chrome one
// (cogame-tandem, 2026-08-23) and a CI step asserts the disjointness.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {seats:[{name,seat,voice,voiceName,base,score,onsets,bars[][],say,heard[],
//            notes,pending,lastTarget,lastEdit} ×4 by SEAT],
//    voiceSeat[4], grid[4][bars][16], chords[], chordNames[], key, mode, bpm,
//    steps, turn, turns, turnsPlayed, piece, parts{}, credits[4], history[],
//    phase:"bars|done", gameDone, reason}
(function () {
  "use strict";

  var C = window.ChorusChrome;

  var VOICE_NAMES = ["Bass", "Tenor", "Alto", "Soprano"];
  var STEP_COUNT = 16;
  var MAX_TOKEN = 13;
  var DEGREE_NAMES = ["tonic", "second", "third", "fourth", "fifth", "sixth",
    "seventh"];
  var SCALES = {
    ionian: [0, 2, 4, 5, 7, 9, 11],
    dorian: [0, 2, 3, 5, 7, 9, 10],
    aeolian: [0, 2, 3, 5, 7, 8, 10],
    mixolydian: [0, 2, 4, 5, 7, 9, 10]
  };
  // Timing of the bar transition, reusing the starter's eased-timer feel: a
  // freshly written bar glows, a rewritten one flashes its outline amber.
  var SLIDE_MS = 700;
  var SLIP_MS = 900;
  var TIMBRES = ["triangle", "sawtooth", "square", "sine"];
  var COMPACT_W = 560;

  function tokenMidi(base, mode, token) {
    var scale = SCALES[mode] || SCALES.ionian;
    return base + 12 * Math.floor(token / 7) + scale[token % 7];
  }

  function midiHz(midi) {
    return 440 * Math.pow(2, (midi - 69) / 12);
  }

  function signed(value) {
    var v = Math.round((value || 0) * 10) / 10;
    return (v >= 0 ? "+" : "−") + Math.abs(v).toFixed(1);
  }

  function one(value) {
    return (Math.round((value || 0) * 10) / 10).toFixed(1);
  }

  function two(value) {
    return (Math.round((value || 0) * 100) / 100).toFixed(2).replace("0.", ".");
  }

  function countOnsets(steps) {
    var n = 0;
    (steps || []).forEach(function (t) { if (t >= 0) n += 1; });
    return n;
  }

  function firstDegree(steps) {
    for (var i = 0; i < (steps || []).length; i++) {
      if (steps[i] >= 0) return DEGREE_NAMES[steps[i] % 7];
    }
    return null;
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Chorus's own transient effects: when each voice last wrote (its bar
  // glows), whether that write was an edit (amber outline + EDIT tag), when
  // the turn last opened (the playhead restarts), and each voice's last line.
  function makeChorusEffects() {
    var seen = 0;
    var turnAt = null;
    var writeAt = [null, null, null, null];
    var writeBar = [-1, -1, -1, -1];
    var writeEdit = [false, false, false, false];
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    return {
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "turn") {
            turnAt = animate ? now : null;
          } else if (event.kind === "bar") {
            writeAt[event.voice] = animate ? now : null;
            writeBar[event.voice] = event.target;
            writeEdit[event.voice] = !!event.edit;
            if (event.say) {
              lastSay[event.voice] = event.say;
              sayAt[event.voice] = animate ? now : null;
            }
          }
        }
      },
      reset: function () {
        seen = 0;
        turnAt = null;
        writeAt = [null, null, null, null];
        writeBar = [-1, -1, -1, -1];
        writeEdit = [false, false, false, false];
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
      },
      view: function () {
        return { effects: {
          turnAt: turnAt,
          writeAt: writeAt.slice(),
          writeBar: writeBar.slice(),
          writeEdit: writeEdit.slice(),
          sayAt: sayAt.slice(),
          lastSay: lastSay.slice()
        } };
      }
    };
  }

  // ---- Renderer ------------------------------------------------------------

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    C.loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  // Ribbon on top, four voice lanes in the middle, the score strip below.
  // Under COMPACT_W the lanes show only the LIVE bar full width, with a
  // one-line thumbnail of the whole piece under them.
  function computeLayout(width, height, bars) {
    var margin = 8;
    var compact = width < COMPACT_W;
    var ribbonH = Math.max(15, Math.min(26, height * 0.07));
    var stripH = Math.max(64, Math.min(height * 0.26, 180));
    var thumbH = compact ? Math.max(16, Math.min(26, height * 0.07)) : 0;
    var labelW = compact ? Math.min(58, width * 0.2) :
      Math.max(88, Math.min(168, width * 0.2));
    var gridTop = margin + ribbonH + 4;
    var gridH = height - stripH - thumbH - gridTop - margin * 2;
    var x0 = margin + labelW;
    var x1 = width - margin;
    var columns = compact ? STEP_COUNT : Math.max(1, bars) * STEP_COUNT;
    return {
      width: width, height: height, compact: compact, margin: margin,
      labelW: labelW, x0: x0, x1: x1, columns: columns,
      colW: (x1 - x0) / Math.max(1, columns),
      ribbon: { x: x0, y: margin, w: x1 - x0, h: ribbonH },
      gridTop: gridTop, gridH: gridH, laneH: gridH / 4,
      thumb: { x: x0, y: gridTop + gridH + 4, w: x1 - x0, h: thumbH },
      strip: { x: margin, y: height - stripH - margin, w: width - margin * 2,
        h: stripH }
    };
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    if (!w || !h) return;
    var bars = view.turns || (view.chords || []).length || 1;
    var L = computeLayout(w, h, bars);
    var now = view.now || Date.now();

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    ctx.save();
    ctx.fillStyle = C.STRIP;
    C.roundRect(ctx, 4, L.margin - 4, w - 8, L.gridTop + L.gridH -
      L.margin + 8, 10);
    ctx.fill();
    ctx.restore();

    drawRibbon(ctx, L, view);
    drawLanes(ctx, images, L, view, now, bars);
    if (L.compact) drawThumbnail(ctx, L, view, bars);
    drawScoreStrip(ctx, L.strip, view, bars, L.compact);
  }

  // One chip per bar, the live bar amber. In compact mode only the live chip
  // is drawn, full width.
  function drawRibbon(ctx, L, view) {
    var names = view.chordNames || [];
    var live = Math.min(view.turn || 0, Math.max(names.length - 1, 0));
    var r = L.ribbon;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (L.compact) {
      ctx.fillStyle = C.rgba(C.AMBER, 0.22);
      C.roundRect(ctx, r.x, r.y, r.w, r.h, 3);
      ctx.fill();
      ctx.fillStyle = C.AMBER;
      ctx.font = "700 " + Math.round(r.h * 0.62) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("BAR " + (view.turn || 0) + "  " + (names[live] || "") +
        "  ·  " + String(view.key || "") + " " +
        String(view.mode || "").toUpperCase(), r.x + r.w / 2, r.y + r.h / 2);
      ctx.restore();
      return;
    }
    var chipW = r.w / Math.max(1, names.length);
    ctx.font = "700 " + Math.round(Math.min(13, r.h * 0.6)) +
      "px 'rajdhani', system-ui, sans-serif";
    names.forEach(function (name, bar) {
      var x = r.x + bar * chipW;
      var isLive = bar === live;
      ctx.fillStyle = isLive ? C.rgba(C.AMBER, 0.26) :
        "rgba(242, 232, 216, 0.07)";
      C.roundRect(ctx, x + 1, r.y, chipW - 2, r.h, 3);
      ctx.fill();
      ctx.fillStyle = isLive ? C.AMBER : C.PAPER_DIM;
      ctx.fillText(name, x + chipW / 2, r.y + r.h / 2);
    });
    ctx.fillStyle = C.PAPER_DIM;
    ctx.textAlign = "left";
    ctx.font = "600 " + Math.round(Math.min(11, r.h * 0.5)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText("CHORD PLAN", L.margin, r.y + r.h / 2);
    ctx.restore();
  }

  function laneBounds(L, voice) {
    var top = L.gridTop + voice * L.laneH;
    return { top: top, bottom: top + L.laneH };
  }

  function drawLanes(ctx, images, L, view, now, bars) {
    var grid = view.grid || [[], [], [], []];
    var voiceSeat = view.voiceSeat || [0, 1, 2, 3];
    var seats = view.seats || [];
    var fx = view.effects || {};
    var liveBar = Math.min(view.turn || 0, Math.max(bars - 1, 0));
    var firstBar = L.compact ? liveBar : 0;
    var shownBars = L.compact ? 1 : bars;

    for (var v = 0; v < 4; v++) {
      var lane = laneBounds(L, v);
      var seatIndex = voiceSeat[v];
      var color = C.COLOR_HEX[C.seatColor(seatIndex)];
      ctx.save();
      ctx.fillStyle = v % 2 ? "rgba(242, 232, 216, 0.035)" :
        "rgba(242, 232, 216, 0.015)";
      ctx.fillRect(L.x0, lane.top, L.x1 - L.x0, L.laneH - 1);
      ctx.restore();

      drawLaneLabel(ctx, images, L, v, seatIndex, seats[seatIndex], color,
        lane, view);

      // Gridlines: every bar boundary bright, steps 0/4/8/12 ghosted.
      ctx.save();
      for (var b = 0; b < shownBars; b++) {
        for (var s = 0; s < STEP_COUNT; s += 2) {
          if (s % 4 !== 0) continue;
          var gx = L.x0 + (b * STEP_COUNT + s) * L.colW;
          ctx.strokeStyle = s === 0 ? "rgba(242, 232, 216, 0.26)" :
            "rgba(242, 232, 216, 0.08)";
          ctx.lineWidth = s === 0 ? 1.5 : 1;
          ctx.beginPath();
          ctx.moveTo(gx, lane.top);
          ctx.lineTo(gx, lane.bottom - 1);
          ctx.stroke();
        }
      }
      ctx.restore();

      // Notes.
      var pad = Math.max(2, L.laneH * 0.12);
      var span = Math.max(4, L.laneH - pad * 2 - 4);
      var blockH = Math.max(3, Math.min(8, L.laneH * 0.14));
      var blockW = Math.max(2, L.colW - 1.5);
      for (var bar = 0; bar < shownBars; bar++) {
        var source = (grid[v] || [])[firstBar + bar] || [];
        var glow = fx.writeAt && fx.writeBar &&
          fx.writeBar[v] === firstBar + bar &&
          typeof fx.writeAt[v] === "number" ?
          Math.max(0, 1 - (now - fx.writeAt[v]) / SLIDE_MS) : 0;
        if (glow > 0) {
          ctx.save();
          ctx.globalAlpha = 0.25 * glow;
          ctx.fillStyle = color;
          ctx.fillRect(L.x0 + bar * STEP_COUNT * L.colW, lane.top,
            STEP_COUNT * L.colW, L.laneH - 1);
          ctx.restore();
        }
        if (glow > 0 && fx.writeEdit && fx.writeEdit[v]) {
          ctx.save();
          ctx.strokeStyle = C.AMBER;
          ctx.lineWidth = 2;
          ctx.strokeRect(L.x0 + bar * STEP_COUNT * L.colW + 1, lane.top + 1,
            STEP_COUNT * L.colW - 2, L.laneH - 3);
          ctx.font = "700 10px 'rajdhani', system-ui, sans-serif";
          ctx.fillStyle = C.AMBER;
          ctx.textAlign = "left";
          ctx.textBaseline = "top";
          ctx.fillText("EDIT", L.x0 + bar * STEP_COUNT * L.colW + 4,
            lane.top + 3);
          ctx.restore();
        }
        for (var step = 0; step < STEP_COUNT; step++) {
          var token = source[step];
          if (typeof token !== "number" || token < 0) continue;
          var nx = L.x0 + (bar * STEP_COUNT + step) * L.colW;
          var ny = lane.bottom - pad -
            (token / MAX_TOKEN) * span - blockH;
          ctx.fillStyle = color;
          ctx.fillRect(nx + 0.5, ny, blockW, blockH);
          ctx.strokeStyle = "rgba(18, 13, 9, 0.55)";
          ctx.lineWidth = 1;
          ctx.strokeRect(nx + 0.5, ny, blockW, blockH);
        }
      }
    }

    drawPlayhead(ctx, L, view, now, bars, firstBar, shownBars);
  }

  function drawLaneLabel(ctx, images, L, voice, seatIndex, seat, color, lane,
      view) {
    ctx.save();
    var portrait = images["soldier_" + C.seatColor(seatIndex) +
      "_front.png"];
    var size = Math.min(L.laneH * 0.8, L.labelW * 0.42, 34);
    if (portrait && portrait.width && !L.compact) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(portrait, L.margin, lane.top + (L.laneH - size) / 2,
        size, size);
    }
    var textX = L.compact ? L.margin : L.margin + size + 5;
    var maxW = L.x0 - textX - 6;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(Math.min(12, L.laneH * 0.28)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = color;
    ctx.fillText(C.ellipsize(ctx, VOICE_NAMES[voice].toUpperCase(), maxW),
      textX, lane.top + L.laneH * 0.36);
    if (!L.compact && seat) {
      ctx.font = "600 " + Math.round(Math.min(11, L.laneH * 0.24)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = seat.pending && !view.gameDone ? C.AMBER : C.PAPER_DIM;
      ctx.fillText(C.ellipsize(ctx, C.clampName(seat.name || ""), maxW),
        textX, lane.top + L.laneH * 0.68);
    }
    ctx.restore();
  }

  // A vertical amber sweep. During playback it walks the bar being read at
  // 60 / bpm / 4 seconds a step; between events it rests on the live bar.
  function drawPlayhead(ctx, L, view, now, bars, firstBar, shownBars) {
    var fx = view.effects || {};
    var liveBar = Math.min(view.turn || 0, Math.max(bars - 1, 0));
    if (liveBar < firstBar || liveBar >= firstBar + shownBars) return;
    var bpm = view.bpm || 96;
    var stepMs = 60000 / bpm / 4;
    var step = 0;
    if (typeof fx.turnAt === "number") {
      step = Math.floor((now - fx.turnAt) / stepMs) % STEP_COUNT;
      if (step < 0) step = 0;
    }
    var x = L.x0 + ((liveBar - firstBar) * STEP_COUNT + step) * L.colW;
    ctx.save();
    ctx.strokeStyle = C.rgba(C.AMBER, 0.85);
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x, L.gridTop - 2);
    ctx.lineTo(x, L.gridTop + L.gridH);
    ctx.stroke();
    ctx.restore();
  }

  // Compact mode only: the whole piece squeezed into one strip so the
  // spectator still sees the shape of what has been written.
  function drawThumbnail(ctx, L, view, bars) {
    var t = L.thumb;
    if (!t.h) return;
    var grid = view.grid || [];
    var voiceSeat = view.voiceSeat || [0, 1, 2, 3];
    var colW = t.w / Math.max(1, bars * STEP_COUNT);
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    C.roundRect(ctx, t.x, t.y, t.w, t.h, 3);
    ctx.fill();
    for (var v = 0; v < 4; v++) {
      ctx.fillStyle = C.COLOR_HEX[C.seatColor(voiceSeat[v])];
      var laneY = t.y + 2 + v * ((t.h - 4) / 4);
      var laneH = Math.max(1.5, (t.h - 4) / 4 - 1);
      for (var b = 0; b < bars; b++) {
        var source = (grid[v] || [])[b] || [];
        for (var s = 0; s < STEP_COUNT; s++) {
          if (source[s] >= 0) {
            ctx.fillRect(t.x + (b * STEP_COUNT + s) * colW, laneY,
              Math.max(1, colW), laneH);
          }
        }
      }
    }
    var live = Math.min(view.turn || 0, Math.max(bars - 1, 0));
    ctx.strokeStyle = C.rgba(C.AMBER, 0.9);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(t.x + live * STEP_COUNT * colW, t.y);
    ctx.lineTo(t.x + live * STEP_COUNT * colW, t.y + t.h);
    ctx.stroke();
    ctx.restore();
  }

  // The score strip: the piece score per resolved turn on a 0–100 axis, and
  // the four seat-coloured counterfactual credits on a signed axis with a
  // zero rule. A line below zero is a cog the piece would be better without.
  function drawScoreStrip(ctx, rect, view, bars, compact) {
    var history = view.history || [];
    var voiceSeat = view.voiceSeat || [0, 1, 2, 3];
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    C.roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    var padL = compact ? 8 : 30;
    var padR = compact ? 8 : 66;
    var padT = 14;
    var padB = 8;
    var x0 = rect.x + padL;
    var x1 = rect.x + rect.w - padR;
    var pieceTop = rect.y + padT;
    var pieceBottom = rect.y + padT + (rect.h - padT - padB) * 0.52;
    var creditTop = pieceBottom + 6;
    var creditBottom = rect.y + rect.h - padB;
    var turns = Math.max(bars, 1);

    function px(turn) { return x0 + (x1 - x0) * turn / turns; }

    ctx.font = "700 10px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = C.PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("PIECE 0–100  ·  CREDIT PER COG", rect.x + 8, rect.y + 2);

    // Piece line.
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.beginPath();
    ctx.moveTo(x0, pieceBottom);
    ctx.lineTo(x1, pieceBottom);
    ctx.stroke();
    if (!compact) {
      ctx.fillStyle = C.GHOST;
      ctx.font = "600 9px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText("100", x0 - 4, pieceTop);
      ctx.fillText("0", x0 - 4, pieceBottom);
    }
    if (history.length) {
      ctx.strokeStyle = C.PAPER;
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.beginPath();
      history.forEach(function (row, i) {
        var y = pieceBottom - (pieceBottom - pieceTop) *
          Math.max(0, Math.min(100, row.piece || 0)) / 100;
        var x = px(row.turn || 0);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
    }

    // Credit lines on a symmetric signed axis.
    var extent = 6;
    history.forEach(function (row) {
      (row.credits || []).forEach(function (v) {
        extent = Math.max(extent, Math.abs(v || 0));
      });
    });
    extent = Math.ceil(extent * 1.15);
    var zeroY = (creditTop + creditBottom) / 2;
    ctx.strokeStyle = "rgba(242, 232, 216, 0.3)";
    ctx.setLineDash([3, 3]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x0, zeroY);
    ctx.lineTo(x1, zeroY);
    ctx.stroke();
    ctx.setLineDash([]);
    if (!compact) {
      ctx.fillStyle = C.GHOST;
      ctx.font = "600 9px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText("0", x0 - 4, zeroY);
    }
    for (var seat = 0; seat < 4; seat++) {
      if (history.length < 1) break;
      ctx.strokeStyle = C.COLOR_HEX[C.seatColor(seat)];
      ctx.lineWidth = 2;
      ctx.beginPath();
      history.forEach(function (row, i) {
        var value = (row.credits || [])[seat] || 0;
        var y = zeroY - (creditBottom - zeroY) * value / extent;
        var x = px(row.turn || 0);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
    }

    if (!compact) {
      var lx = x1 + 8;
      ctx.font = "600 9.5px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      for (var v = 0; v < 4; v++) {
        var seatIndex = voiceSeat[v];
        ctx.fillStyle = C.COLOR_HEX[C.seatColor(seatIndex)];
        ctx.fillRect(lx, creditTop + v * 12 - 3, 10, 6);
        ctx.fillStyle = C.PAPER_DIM;
        ctx.fillText(VOICE_NAMES[v].toUpperCase(), lx + 14,
          creditTop + v * 12);
      }
    }
    ctx.restore();
  }

  // ---- Audio ---------------------------------------------------------------

  // Four oscillator timbres, one per voice, straight into a compressor. Off
  // until the ♪ AUDIO button is clicked (the user gesture browser autoplay
  // policy requires), fully fenced in try/catch, and it NEVER gates
  // data-replay-loaded or touches the render loop.
  function makeChorusAudio() {
    var audio = null;
    var master = null;
    var timers = [];
    var nodes = [];
    var available = true;
    var playing = false;

    function ensure() {
      if (audio) return audio;
      var Ctor = window.AudioContext || window.webkitAudioContext;
      if (!Ctor) throw new Error("no AudioContext");
      audio = new Ctor();
      var comp = audio.createDynamicsCompressor();
      master = audio.createGain();
      master.gain.value = 0.25;
      comp.connect(master);
      master.connect(audio.destination);
      master.__comp = comp;
      return audio;
    }

    function stop() {
      playing = false;
      timers.forEach(function (t) { window.clearTimeout(t); });
      timers = [];
      nodes.forEach(function (n) {
        try { n.stop(); } catch (ignore) {}
      });
      nodes = [];
    }

    function note(voice, hz, at, dur) {
      var osc = audio.createOscillator();
      var gain = audio.createGain();
      osc.type = TIMBRES[voice % TIMBRES.length];
      osc.frequency.value = hz;
      gain.gain.setValueAtTime(0.0001, at);
      gain.gain.linearRampToValueAtTime(0.6, at + 0.005);
      gain.gain.exponentialRampToValueAtTime(0.0001, at + 0.12);
      osc.connect(gain);
      gain.connect(master.__comp);
      osc.start(at);
      osc.stop(at + Math.max(dur, 0.14));
      nodes.push(osc);
    }

    return {
      available: function () { return available; },
      playing: function () { return playing; },
      stop: stop,
      // Schedules at most ONE bar ahead; a seek or a STOP cancels every
      // scheduled node.
      play: function (state, muteVoice, onDone) {
        if (!available) return;
        try {
          ensure();
          if (audio.state === "suspended") audio.resume();
        } catch (error) {
          available = false;
          return;
        }
        stop();
        playing = true;
        var grid = state.grid || [];
        var seats = state.seats || [];
        var voiceSeat = state.voiceSeat || [0, 1, 2, 3];
        var mode = state.mode || "ionian";
        var bars = (grid[0] || []).length;
        var stepDur = 60 / (state.bpm || 96) / 4;
        var startAt = audio.currentTime + 0.08;

        function scheduleBar(bar) {
          if (!playing || bar >= bars) {
            if (playing && onDone) {
              timers.push(window.setTimeout(function () {
                playing = false;
                onDone();
              }, 400));
            }
            return;
          }
          try {
            for (var v = 0; v < 4; v++) {
              if (v === muteVoice) continue;
              var seat = seats[voiceSeat[v]] || {};
              var base = typeof seat.base === "number" ? seat.base :
                [36, 48, 60, 72][v];
              var source = (grid[v] || [])[bar] || [];
              for (var s = 0; s < STEP_COUNT; s++) {
                if (source[s] < 0 || typeof source[s] !== "number") continue;
                note(v, midiHz(tokenMidi(base, mode, source[s])),
                  startAt + (bar * STEP_COUNT + s) * stepDur, stepDur);
              }
            }
          } catch (error) {
            available = false;
            stop();
            return;
          }
          timers.push(window.setTimeout(function () {
            scheduleBar(bar + 1);
          }, Math.max(50, STEP_COUNT * stepDur * 1000 * 0.7)));
        }
        scheduleBar(0);
      }
    };
  }

  function bindAudioButton(button, audio, getState) {
    if (!button) return null;
    var on = false;
    function label() {
      if (!audio.available()) {
        button.textContent = "♪ AUDIO N/A";
        button.disabled = true;
        button.classList.remove("on");
        document.body.classList.remove("audio-on");
        return;
      }
      button.textContent = "♪ AUDIO";
      button.classList.toggle("on", on);
      document.body.classList.toggle("audio-on", on);
    }
    button.onclick = function () {
      on = !on;
      if (!on) {
        audio.stop();
      } else {
        var state = getState();
        if (state) audio.play(state, -1, null);
      }
      label();
    };
    label();
    return { isOn: function () { return on; }, refresh: label };
  }

  // ---- Scrubber ------------------------------------------------------------

  // One labelled, clickable button per emitted beat. Named chorusMarkBeat /
  // buildChorusScrub so no game-side name can shadow a ChorusChrome key.
  function chorusMarkBeat(container, index, total, kind, seatIndex, label,
      onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind +
      (typeof seatIndex === "number" && seatIndex >= 0 ?
        " seat" + (seatIndex % C.COLORS.length) : "");
    marker.style.left = (index / Math.max(total, 1) * 100) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(index);
    };
    container.appendChild(marker);
    return marker;
  }

  function buildChorusScrub(container, events, nameMap, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
    });
    events.forEach(function (event, i) {
      var at = i + 1;
      if (event.kind === "start") {
        chorusMarkBeat(container, at, events.length, "start", -1,
          "Studio call", onSeek);
      } else if (event.kind === "turn") {
        chorusMarkBeat(container, at, events.length, "turn", -1,
          "Bar " + event.turn + " — piece " + one(event.piece), onSeek);
      } else if (event.kind === "bar") {
        var who = C.clampName(nameMap.seat(event.seat));
        chorusMarkBeat(container, at, events.length,
          event.edit ? "edit" : "bar", event.seat,
          "Bar " + event.target + " — " + who + " (" +
            VOICE_NAMES[event.voice] + ") " +
            (event.edit ? "rewrites" : "writes") + " " +
            countOnsets(event.steps) + " notes", onSeek);
      } else if (event.kind === "end") {
        chorusMarkBeat(container, at, events.length, "end", -1,
          "Final — " + (event.text || "complete"), onSeek);
      }
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  // ---- Feed ----------------------------------------------------------------

  function describeEvent(event, nameMap, ctx) {
    function name(i) { return C.clampName(nameMap.seat(i)); }
    switch (event.kind) {
      case "start":
        return "Studio call — " + (ctx.key || "") + ", " + (ctx.bpm || "") +
          " BPM, " + (ctx.bars || 0) + " bars.";
      case "turn":
        if (event.turn === 0) return "The grid is empty. Write something.";
        return "BAR " + event.turn + " — piece " + one(event.piece) +
          " (cons " + two(event.parts ? event.parts[0] : 0) + " · lead " +
          two(event.parts ? event.parts[1] : 0) + " · rhy " +
          two(event.parts ? event.parts[2] : 0) + " · nov " +
          two(event.parts ? event.parts[3] : 0) + ")";
      case "bar":
        var notes = countOnsets(event.steps);
        var degree = firstDegree(event.steps);
        return name(event.seat) + " (" + VOICE_NAMES[event.voice] + ") " +
          (event.edit ? "edits" : "writes") + " bar " + event.target +
          " — " + notes + (notes === 1 ? " note" : " notes") +
          (degree ? ", starts on the " + degree : ", silent") +
          (event.scripted ? " ·" : "");
      case "end":
        if (event.text === "deadline") {
          return "Episode deadline — the piece was scored on " +
            (ctx.playedBars || 0) + " of " + (ctx.bars || 0) + " bars.";
        }
        return "FINAL — piece " + one(ctx.piece) + " · credits " +
          (ctx.credits || []).map(function (v, i) {
            return name(i) + " " + signed(v);
          }).join(", ");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "BAR " + block;
  }

  function renderFeed(element, events, nameMap, currentIndex, meta) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var info = meta || {};
    var html = "";
    var lastBlock = null;
    var ctx = {
      key: info.key || "", bpm: info.bpm || "", bars: info.bars || 0,
      piece: 0, credits: [0, 0, 0, 0], playedBars: 0
    };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      if (event.kind === "turn") {
        ctx.piece = event.piece;
        ctx.credits = event.credits || ctx.credits;
        ctx.playedBars = event.turn;
      }
      var text = describeEvent(event, nameMap, ctx);
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "bar" ? " seat" + (event.seat % C.COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + C.escapeHtml(text) + "</div>";
      if (event.kind === "bar" && event.say) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          C.escapeHtml(C.clampName(nameMap.seat(event.seat)) + " says: " +
            nameMap.text(event.say)) + "</div>";
      }
      if (event.kind === "bar" && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          C.escapeHtml(C.clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- Readouts ------------------------------------------------------------

  function matchHeader(state, results) {
    if (!state) return "";
    if (state.gameDone || state.done) {
      var line = "FINAL — PIECE " + one(state.piece);
      var reason = state.reason || (results && results.reason);
      if (reason === "deadline") line += " · DEADLINE";
      return line;
    }
    var parts = ["BAR " + (state.turn || 0) + " / " + (state.turns || 0)];
    // At embedded widths the key and the tempo are already on the chord
    // ribbon, and the bar count plus who the table is waiting on is what has
    // to stay readable at 360 px.
    if (!window.innerWidth || window.innerWidth >= COMPACT_W) {
      parts.push(String(state.key || "").toUpperCase() + " " +
        String(state.mode || "").toUpperCase());
      parts.push((state.bpm || 0) + " BPM");
    }
    var waiting = (state.seats || []).filter(function (s) {
      return s.pending;
    });
    parts.push(waiting.length ? "WAITING ON " + waiting.length : "BARS IN");
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + C.seatColor(index) + '">' +
        '<span class="plate-name">' +
        C.escapeHtml(C.clampName(plateName)) + "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + C.escapeHtml(signed(seat.score)) +
        "</span>" +
        '<span class="plate-label">' +
        C.escapeHtml((seat.voiceName || "").toUpperCase()) + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    if (results.reason === "deadline") {
      return "episode deadline: the piece was scored on " +
        (results.bars || 0) + " of " + (results.maxBars || results.bars || 0) +
        " bars";
    }
    return "";
  }

  // Final standings: ranked by credit, with the counterfactual spelled out
  // and a PLAY WITHOUT button per row when audio is available.
  function updateEndscreen(container, results, show, nameMap, extras) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var info = extras || {};
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var voices = results.voices || [];
    var onsets = results.onsets || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? C.seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      C.escapeHtml(String(names[topIndex]).toUpperCase()) +
        " CARRIED THE PIECE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.bars || 0) + " BAR" +
      ((results.bars || 0) === 1 ? "" : "S") + " · PIECE " +
      C.escapeHtml(one(results.piece)) + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + C.escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows chorus-end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">voice</span>' +
      '<span class="end-head">credit</span>' +
      '<span class="end-head">notes played</span>' +
      '<span class="end-head">piece without you</span>' +
      '<span class="end-head"></span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      var without = (results.piece || 0) - (scores[i] || 0);
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + C.seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' +
        C.escapeHtml(String(names[i])) + "</span>" +
        cell(C.escapeHtml(voices[i] || "")) +
        cell(C.escapeHtml(signed(scores[i]))) +
        cell(typeof onsets[i] === "number" ? onsets[i] : "–") +
        cell(C.escapeHtml(one(without))) +
        '<span class="end-cell">' +
        '<button type="button" class="end-mute" data-seat="' + i + '">' +
        "PLAY WITHOUT " + C.escapeHtml(C.clampName(String(names[i])))
          .toUpperCase() + "</button></span>";
    });
    html += '</div><div class="end-foot">Credits are leave-one-out ' +
      'differences and do not sum to the piece score.</div></div>';
    container.innerHTML = html;

    // The counterfactual, audible: replay the finished piece with one voice
    // muted. Hidden entirely when audio is off or unavailable.
    var buttons = container.querySelectorAll(".end-mute");
    for (var b = 0; b < buttons.length; b++) {
      (function (button) {
        button.onclick = function () {
          if (!info.audio || !info.state) return;
          var state = info.state();
          var seat = parseInt(button.dataset.seat, 10);
          var voice = (state.seats || [])[seat] ?
            state.seats[seat].voice : -1;
          if (button.dataset.on === "yes") {
            info.audio.stop();
            button.dataset.on = "";
            button.textContent = "PLAY WITHOUT " +
              C.clampName(String(names[seat])).toUpperCase();
            return;
          }
          info.audio.play(state, voice, function () {
            button.dataset.on = "";
            button.textContent = "PLAY WITHOUT " +
              C.clampName(String(names[seat])).toUpperCase();
          });
          button.dataset.on = "yes";
          button.textContent = "STOP";
        };
      })(buttons[b]);
    }
  }

  // The legend strip the appended game block put in the transport band: one
  // swatch per VOICE, tinted with the colour of the SEAT that owns it, and
  // labelled with that seat's rendered name.
  function updateLegend(state, nameMap) {
    var legend = document.getElementById("chorus-legend");
    if (!legend || !state) return;
    var voiceSeat = state.voiceSeat || [0, 1, 2, 3];
    var items = legend.querySelectorAll(".legend-item");
    for (var i = 0; i < items.length; i++) {
      var voice = parseInt(items[i].dataset.voice, 10);
      var seatIndex = voiceSeat[voice];
      var swatch = items[i].querySelector(".legend-swatch");
      var text = items[i].querySelector(".legend-text");
      if (swatch) {
        swatch.style.setProperty("--tc",
          C.COLOR_HEX[C.seatColor(seatIndex)]);
      }
      if (text) {
        text.textContent = VOICE_NAMES[voice].toUpperCase() + " " +
          C.clampName(nameMap ? nameMap.seat(seatIndex) : "");
      }
    }
  }

  function sweepLightpool(state) {
    var pool = document.getElementById("lightpool");
    if (!pool || !state || !state.seats || !state.seats.length) return;
    var best = 0;
    state.seats.forEach(function (seat, i) {
      if ((seat.score || 0) > (state.seats[best].score || 0)) best = i;
    });
    var voice = state.seats[best].voice;
    var at = typeof voice === "number" ? (voice + 0.5) / 4 * 100 : 50;
    pool.style.background =
      "radial-gradient(62% 46% at 50% " + at.toFixed(0) +
      "%, transparent 36%, rgba(12, 8, 5, 0.46) 100%)";
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = C.applyNames(state.seats, nameMap);
    view.voiceSeat = state.voiceSeat || [0, 1, 2, 3];
    view.grid = state.grid || [[], [], [], []];
    view.chords = state.chords || [];
    view.chordNames = state.chordNames || [];
    view.key = state.key || "";
    view.mode = state.mode || "";
    view.bpm = state.bpm || 96;
    view.turn = state.turn || 0;
    view.turns = state.turns || 0;
    view.turnsPlayed = state.turnsPlayed || 0;
    view.piece = state.piece || 0;
    view.credits = state.credits || [0, 0, 0, 0];
    view.history = state.history || [];
    view.phase = state.phase || "";
    view.gameDone = !!state.gameDone;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame ({seat:{...}}) becomes a four-seat state with the
  // own seat filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var bars = data.turns || 8;
    var grid = [[], [], [], []];
    var seats = [];
    for (var i = 0; i < 4; i++) {
      // The other three seats are placeholders: a player frame is redacted
      // to its own voice, so nothing here may claim to know theirs.
      seats.push({ name: "Seat " + i, seat: i, voice: i,
        voiceName: "", base: [36, 48, 60, 72][i], score: 0,
        onsets: 0, bars: [], pending: false, lastTarget: -1,
        lastEdit: false });
    }
    for (var v = 0; v < 4; v++) {
      for (var b = 0; b < bars; b++) {
        var empty = [];
        for (var s = 0; s < STEP_COUNT; s++) empty.push(-1);
        grid[v].push(empty);
      }
    }
    var voiceSeat = [0, 1, 2, 3];
    if (data.seat && typeof data.slot === "number") {
      var voice = data.seat.voice;
      seats[data.slot] = {
        name: data.name, seat: data.slot, voice: voice,
        voiceName: data.seat.voiceName, base: data.seat.base,
        score: data.seat.score, onsets: data.seat.onsets,
        bars: data.seat.bars || [], notes: data.seat.notes || "",
        pending: false, lastTarget: -1, lastEdit: false
      };
      voiceSeat = [0, 1, 2, 3].filter(function (s) { return s !== data.slot; });
      voiceSeat.splice(voice, 0, data.slot);
      grid[voice] = data.seat.bars || grid[voice];
    }
    var chordNames = [];
    for (var c = 0; c < bars; c++) chordNames.push("");
    return {
      seats: seats, voiceSeat: voiceSeat, grid: grid, chords: [],
      chordNames: chordNames, key: "", mode: "", bpm: 96,
      turn: data.turn || 0, turns: bars, turnsPlayed: data.turnsPlayed || 0,
      piece: data.piece || 0, credits: [0, 0, 0, 0], history: [],
      phase: data.done ? "done" : "bars", gameDone: !!data.done,
      reason: data.reason || "", events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = C.makeNameMap([], null);
      var effects = makeChorusEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = C.makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, { key: latest.key + " " + latest.mode,
                    bpm: latest.bpm, bars: latest.turns });
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, null);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              updateLegend(latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap, {});
              if (latest) sweepLightpool(latest);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      C.relayout();
      (function frame() {
        if (latest) {
          renderer.draw(stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          }));
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, audioButton, label, clock,
    //           scorebug, endscreen, assetBase, payload, onLoaded}
    // onLoaded (optional) runs once, immediately after the first frame is
    // drawn and data-replay-loaded is set -- i.e. once the clock, scorebug
    // and scrub really carry the replay. A host that samples the viewer on
    // that signal must not see the untouched shell, so it cannot be raised
    // from the call site: makeRenderer waits on loadImages, which can take
    // more than a second.
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = C.makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var audio = makeChorusAudio();

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeChorusEffects();

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", turn: 0 };
      }

      var scrub = buildChorusScrub(options.scrub, events, nameMap,
        function (next) {
          playing = false;
          audio.stop();
          setIndex(next, true);
        });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }
      bindAudioButton(options.audioButton ||
        document.getElementById("audio"), audio, currentState);

      var meta = {
        key: (states[0] && states[0].key ? states[0].key + " " +
          states[0].mode : ""),
        bpm: states[0] && states[0].bpm,
        bars: config.bars || (states[0] && states[0].turns) || 0
      };

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, meta);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(),
            payload.results);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateLegend(currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap,
          { audio: audio, state: currentState });
        if (index >= events.length && events.length > 0) {
          sweepLightpool(currentState());
        }
      }
      setIndex(0, true);
      C.relayout();

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a turn head gets
        // read (the score strip grows), a bar less so, the endcard longest.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "turn" ? 1200 :
          shown && shown.kind === "bar" ? 600 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw(stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        }));
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
      if (options.onLoaded) options.onLoaded();
    });
  }

  window.ChorusRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: C.bindFeedToggle,
    relayout: C.relayout
  };
})();

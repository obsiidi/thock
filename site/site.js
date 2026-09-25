// thock website — dot-matrix graphics and the key-force demo.
// Ported from the Claude Design canvas component. No network, no storage.
(function () {
  'use strict';

  var INK = '#edede7';
  var DENSITY = 1;
  var MAGNET = 3.4;
  var MAGNET_RADIUS = 0;
  var TRACKING = 0.01;
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var REACTIVE = !reduced;

  var state = { sound: false, force: 62 };
  var pulse = 0, levels = null, col = 0, force = 0, raf = 0, now = 0, ac = null;
  var cvs = [];
  var ro = new ResizeObserver(function () { refresh(); });

  // --- input -------------------------------------------------------------
  function onKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    hit(0.3 + Math.random() * 0.7);
  }
  function onMove(e) {
    var cv = e.currentTarget, r = cv.getBoundingClientRect();
    cv.__p = { x: e.clientX - r.left, y: e.clientY - r.top };
    cv.__lp = cv.__p;
    kick();
  }
  function onLeave(e) { e.currentTarget.__p = null; kick(); }

  function collect() {
    cvs = Array.prototype.slice.call(document.querySelectorAll('canvas[data-dots]'));
    cvs.forEach(function (cv) {
      if (cv.__bound) return;
      cv.__bound = true;
      if (cv.dataset.mode === 'mark' || cv.dataset.mode === 'photo') {
        cv.addEventListener('pointermove', onMove);
        cv.addEventListener('pointerleave', onLeave);
      }
      ro.observe(cv);
    });
  }

  function refresh() {
    cvs.forEach(function (cv) { measure(cv); draw(cv); });
  }

  function hit(f0) {
    var f = f0 * (0.45 + (state.force / 100) * 0.9);
    force = Math.min(1, f);
    pulse = Math.min(1, 0.45 + f * 0.55);
    if (levels) {
      levels[col % levels.length] = Math.min(1, f);
      col++;
    }
    if (state.sound) click(Math.min(1, f));
    kick();
  }

  // --- synthesised click (only when the visitor switches sound on) --------
  function click(f) {
    try {
      if (!ac) ac = new (window.AudioContext || window.webkitAudioContext)();
      var t = ac.currentTime;
      var len = Math.floor(ac.sampleRate * 0.06);
      var buf = ac.createBuffer(1, len, ac.sampleRate);
      var d = buf.getChannelData(0);
      for (var i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.5);
      var src = ac.createBufferSource(); src.buffer = buf;
      var bp = ac.createBiquadFilter();
      bp.type = 'bandpass'; bp.frequency.value = 1100 + f * 1600; bp.Q.value = 1.1;
      var g = ac.createGain();
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.12 + f * 0.3, t + 0.004);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.07);
      src.connect(bp); bp.connect(g); g.connect(ac.destination);
      src.start(t); src.stop(t + 0.09);
      var osc = ac.createOscillator(), og = ac.createGain();
      osc.type = 'sine'; osc.frequency.setValueAtTime(150 + f * 60, t);
      osc.frequency.exponentialRampToValueAtTime(70, t + 0.06);
      og.gain.setValueAtTime(0.0001, t);
      og.gain.exponentialRampToValueAtTime(0.1 + f * 0.22, t + 0.006);
      og.gain.exponentialRampToValueAtTime(0.0001, t + 0.08);
      osc.connect(og); og.connect(ac.destination);
      osc.start(t); osc.stop(t + 0.1);
    } catch (e) { /* audio unavailable */ }
  }

  // --- animation loop ------------------------------------------------------
  function kick() {
    if (raf) return;
    var loop = function () {
      raf = 0;
      now = performance.now();
      pulse = pulse > 0.004 ? pulse * 0.9 : 0;
      var live = pulse > 0;
      if (levels) {
        for (var i = 0; i < levels.length; i++) {
          if (levels[i] > 0.004) { levels[i] *= 0.955; live = true; }
          else levels[i] = 0;
        }
      }
      var pulsing = pulse > 0;
      cvs.forEach(function (cv) {
        var mode = cv.dataset.mode;
        if (mode === 'bars') return;
        var tgt = cv.__p ? 1 : 0;
        var h = cv.__h || 0;
        cv.__h = h + (tgt - h) * 0.14;
        var easing = Math.abs(tgt - cv.__h) > 0.004;
        if (cv.__p) {
          var s = cv.__ps || { x: cv.__p.x, y: cv.__p.y };
          cv.__ps = { x: s.x + (cv.__p.x - s.x) * 0.22, y: s.y + (cv.__p.y - s.y) * 0.22 };
          live = true;
        }
        if (easing) live = true;
        if (cv.__p || easing || pulsing || mode === 'force') draw(cv);
      });
      if (live) raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
  }

  // --- layout: sample the word into a dot grid ------------------------------
  function measure(cv) {
    var w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return;
    var step = Math.max(2, (parseFloat(cv.dataset.step) || 7) / DENSITY);
    var mode = cv.dataset.mode || 'mark';
    var cols = Math.max(1, Math.floor(w / step)), rows = Math.max(1, Math.floor(h / step));
    var ox = (w - (cols - 1) * step) / 2, oy = (h - (rows - 1) * step) / 2;

    if (mode === 'photo') {
      measurePhoto(cv, w, h);
      return;
    }

    if (mode !== 'mark') {
      cv.__grid = { w: w, h: h, step: step, cols: cols, rows: rows, ox: ox, oy: oy, mode: mode, seed: parseFloat(cv.dataset.seed) || 1 };
      if (mode === 'force' && (!levels || levels.length !== cols)) levels = new Float32Array(cols);
      return;
    }

    var text = cv.dataset.text || 'thock';
    var S = 2;
    var off = document.createElement('canvas');
    off.width = Math.round(w * S); off.height = Math.round(h * S);
    var o = off.getContext('2d', { willReadFrequently: true });
    o.fillStyle = '#000'; o.fillRect(0, 0, off.width, off.height);
    o.fillStyle = '#fff';
    o.textAlign = 'center'; o.textBaseline = 'alphabetic';
    var fam = '"Archivo", "Helvetica Neue", Helvetica, Arial, sans-serif';
    var hasLS = 'letterSpacing' in o;
    var apply = function (size) {
      o.font = '800 ' + size + 'px ' + fam;
      if (hasLS) o.letterSpacing = (size * TRACKING) + 'px';
    };
    apply(100);
    var unit = o.measureText(text).width / 100;
    var fsW = (off.width * 0.9) / Math.max(0.01, unit);
    var fsH = off.height * 0.95;
    var fs = Math.min(fsW, fsH);
    apply(fs);
    var m = o.measureText(text);
    var asc = m.actualBoundingBoxAscent || fs * 0.72;
    var desc = m.actualBoundingBoxDescent || fs * 0.1;
    o.fillText(text, off.width / 2 - (hasLS ? fs * TRACKING / 2 : 0), (off.height + (asc - desc)) / 2);

    var img = o.getImageData(0, 0, off.width, off.height).data;
    var cov = new Float32Array(cols * rows);
    var N = 3, half = step / 2;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        var cx = ox + c * step, cy = oy + r * step;
        var sum = 0;
        for (var sy = 0; sy < N; sy++) {
          for (var sx = 0; sx < N; sx++) {
            var px = Math.min(off.width - 1, Math.max(0, Math.round((cx - half + (sx + 0.5) * step / N) * S)));
            var py = Math.min(off.height - 1, Math.max(0, Math.round((cy - half + (sy + 0.5) * step / N) * S)));
            sum += img[(py * off.width + px) * 4] / 255;
          }
        }
        cov[r * cols + c] = sum / (N * N);
      }
    }
    var glow = new Float32Array(cols * rows);
    var K = 4;
    for (r = 0; r < rows; r++) {
      for (c = 0; c < cols; c++) {
        var s = 0, n = 0;
        for (var dr = -K; dr <= K; dr++) {
          var rr = r + dr; if (rr < 0 || rr >= rows) continue;
          for (var dc = -K; dc <= K; dc++) {
            var cc = c + dc; if (cc < 0 || cc >= cols) continue;
            s += cov[rr * cols + cc]; n++;
          }
        }
        glow[r * cols + c] = n ? s / n : 0;
      }
    }
    var total = cols * rows;
    var rad0 = new Float32Array(total), al0 = new Float32Array(total), keep = new Uint8Array(total);
    var hash = function (c, r) { var v = Math.sin(c * 127.1 + r * 311.7) * 43758.5453; return v - Math.floor(v); };
    for (r = 0; r < rows; r++) {
      for (c = 0; c < cols; c++) {
        var i = r * cols + c;
        var a = Math.min(1, cov[i] * 1.12);
        if (a <= 0.035) {
          if (glow[i] > 0.03 && hash(c, r) > 0.8) {
            keep[i] = 1; rad0[i] = step * 0.16; al0[i] = Math.min(0.3, glow[i] * 2.2) * 0.6;
          }
        } else {
          keep[i] = 1; rad0[i] = step * 0.54 * Math.pow(a, 0.58); al0[i] = 0.28 + 0.72 * a;
        }
      }
    }
    cv.__grid = { w: w, h: h, step: step, cols: cols, rows: rows, ox: ox, oy: oy, cov: cov, glow: glow, rad0: rad0, al0: al0, keep: keep, mode: mode };
  }

  // --- photo: an image shown 1:1, lit by the cursor, rippled by typing -------
  var photos = {};
  function measurePhoto(cv, w, h) {
    var src = cv.dataset.src;
    var img = photos[src];
    if (!img) {
      img = photos[src] = new Image();
      img.onload = function () { measure(cv); draw(cv); };
      img.src = src;
    }
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    cv.__grid = { w: w, h: h, mode: 'photo', dpr: dpr, img: img, glow: document.createElement('canvas') };
  }

  function drawPhoto(cv, g) {
    var img = g.img;
    var pw = Math.round(g.w * g.dpr), ph = Math.round(g.h * g.dpr);
    if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph; }
    var ctx = cv.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, pw, ph);
    if (!img.complete || !img.naturalWidth) return;
    ctx.imageSmoothingQuality = 'high';
    var hv = REACTIVE ? (cv.__h || 0) : 0;
    var pp = cv.__ps || cv.__p || cv.__lp;
    var lit = REACTIVE && pp && hv > 0.002;
    var pl = REACTIVE ? pulse : 0;
    // Untouched, the picture is drawn exactly as it is. With the cursor on
    // it (or while a keystroke ripples) the rest dims and the light restores it.
    ctx.globalAlpha = 1 - 0.5 * hv - 0.3 * pl;
    ctx.drawImage(img, 0, 0, pw, ph);
    ctx.globalAlpha = 1;
    if (!lit && pl <= 0) return;

    // Glow layer: the picture again, masked by a light shape, added on top —
    // only the existing dots brighten, the dark background stays dark.
    var gl = g.glow;
    if (gl.width !== pw || gl.height !== ph) { gl.width = pw; gl.height = ph; }
    var gx = gl.getContext('2d');
    gx.globalCompositeOperation = 'source-over';
    gx.clearRect(0, 0, pw, ph);
    if (lit) {
      var cx = pp.x * g.dpr, cy = pp.y * g.dpr, rad = 150 * g.dpr;
      var lamp = gx.createRadialGradient(cx, cy, 0, cx, cy, rad);
      lamp.addColorStop(0, 'rgba(255,255,255,' + (0.95 * hv) + ')');
      lamp.addColorStop(0.55, 'rgba(255,255,255,' + (0.35 * hv) + ')');
      lamp.addColorStop(1, 'rgba(255,255,255,0)');
      gx.fillStyle = lamp;
      gx.fillRect(0, 0, pw, ph);
    }
    if (pl > 0) {
      var mx = pw / 2, my = ph * 0.45;
      var maxR = Math.hypot(pw, ph) * 0.6;
      var r0 = (1 - pl) * maxR, ring = 70 * g.dpr;
      var wave = gx.createRadialGradient(mx, my, Math.max(0, r0 - ring), mx, my, r0 + ring);
      wave.addColorStop(0, 'rgba(255,255,255,0)');
      wave.addColorStop(0.5, 'rgba(255,255,255,' + (0.8 * pl) + ')');
      wave.addColorStop(1, 'rgba(255,255,255,0)');
      gx.fillStyle = wave;
      gx.fillRect(0, 0, pw, ph);
    }
    gx.globalCompositeOperation = 'destination-in';
    gx.drawImage(img, 0, 0, pw, ph);
    ctx.globalCompositeOperation = 'lighter';
    ctx.drawImage(gl, 0, 0);
    ctx.globalCompositeOperation = 'source-over';
  }

  // --- draw -----------------------------------------------------------------
  function draw(cv) {
    var g = cv.__grid; if (!g) return;
    if (g.mode === 'photo') { drawPhoto(cv, g); return; }
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    var pw = Math.round(g.w * dpr), ph = Math.round(g.h * dpr);
    if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph; }
    var ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, g.w, g.h);
    var rnd = function (c, r) { var v = Math.sin(c * 127.1 + r * 311.7 + (g.seed || 0) * 57.3) * 43758.5453; return v - Math.floor(v); };
    ctx.fillStyle = INK;
    var c, r;

    if (g.mode === 'bars') {
      for (c = 0; c < g.cols; c++) {
        var dk = 0.2 + rnd(91, 7) * 0.5;
        var att = Math.min(1, c / Math.max(1, g.cols * 0.045));
        var env = att * Math.exp(-c / (g.cols * dk));
        var amp = env * (0.5 + rnd(c, 3) * 0.75);
        if (amp < 0.07) continue;
        var on = Math.max(0, Math.round(amp * (g.rows - 1) * 0.72));
        for (r = 0; r < g.rows; r++) {
          var mid = (g.rows - 1) / 2;
          var dist = Math.abs(r - mid);
          if (dist > on + 0.2) continue;
          ctx.globalAlpha = 0.5 + 0.5 * (1 - dist / Math.max(1, on + 1));
          ctx.beginPath(); ctx.arc(g.ox + c * g.step, g.oy + r * g.step, g.step * 0.3, 0, 6.2832); ctx.fill();
        }
      }
      ctx.globalAlpha = 1;
      return;
    }

    if (g.mode === 'force') {
      for (c = 0; c < g.cols; c++) {
        var level = levels ? levels[c] : 0;
        var lit = level * (g.rows - 1);
        for (r = 0; r < g.rows; r++) {
          var fromBottom = g.rows - 1 - r;
          var isOn = fromBottom <= lit;
          var head = Math.abs(fromBottom - lit) < 1.1;
          ctx.globalAlpha = isOn ? (head ? 1 : 0.35 + 0.5 * level) : 0.085;
          var rad = g.step * (isOn ? (head ? 0.4 : 0.3) : 0.13);
          ctx.beginPath(); ctx.arc(g.ox + c * g.step, g.oy + r * g.step, rad, 0, 6.2832); ctx.fill();
        }
      }
      ctx.globalAlpha = 1;
      return;
    }

    var hv = REACTIVE ? (cv.__h || 0) : 0;
    var pp = REACTIVE ? (cv.__ps || cv.__p || cv.__lp) : null;
    var pl = REACTIVE ? pulse : 0;
    var maxD = Math.hypot(g.w, g.h) / 2;
    var waveR = (1 - pl) * maxD * 1.15, ringW = g.step * 7;
    var cxm = g.w / 2, cym = g.h / 2;
    var R = g.step * 11 + MAGNET_RADIUS;
    var reach = R * 2.6, reach2 = reach * reach, inv2R2 = 1 / (2 * R * R);
    var tt = (now || performance.now()) / 1000;
    var active = pp && hv > 0.002;

    for (r = 0; r < g.rows; r++) {
      var y = g.oy + r * g.step;
      var dyp = active ? y - pp.y : 0;
      for (c = 0; c < g.cols; c++) {
        var i = r * g.cols + c;
        if (!g.keep[i]) continue;
        var x = g.ox + c * g.step;
        var dx = 0, dy = 0, f = 0;
        if (active) {
          var vx = x - pp.x, dd = vx * vx + dyp * dyp;
          if (dd < reach2) {
            var d = Math.max(1, Math.sqrt(dd));
            f = Math.exp(-dd * inv2R2) * hv;
            var breathe = 1 + 0.14 * Math.sin(tt * 0.9 + d * 0.012);
            var push = f * g.step * MAGNET * breathe;
            dx = (vx / d) * push; dy = (dyp / d) * push;
            var phs = rnd(c, r) * 6.2832;
            var sw = f * g.step * 0.6;
            dx += sw * Math.sin(tt * 1.5 + phs);
            dy += sw * Math.cos(tt * 1.15 + phs * 1.7);
          }
        }
        var wave = 0;
        if (pl > 0) {
          var dm = Math.hypot(x - cxm, y - cym);
          var t = (dm - waveR) / ringW;
          wave = Math.exp(-t * t) * pl;
        }
        var rr2 = g.rad0[i] * (1 + 1.1 * f + 0.7 * wave);
        ctx.globalAlpha = Math.min(1, g.al0[i] + 0.45 * f + 0.35 * wave);
        ctx.beginPath(); ctx.arc(x + dx, y + dy, rr2, 0, 6.2832); ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
  }

  // --- controls ---------------------------------------------------------------
  var toggle = document.getElementById('soundToggle');
  var range = document.getElementById('forceRange');
  if (toggle) {
    toggle.addEventListener('click', function () {
      state.sound = !state.sound;
      toggle.textContent = state.sound ? 'sound on' : 'sound off';
      toggle.setAttribute('aria-pressed', state.sound ? 'true' : 'false');
      if (state.sound) hit(0.7);
    });
  }
  if (range) {
    range.addEventListener('input', function () { state.force = +range.value; });
  }

  window.addEventListener('keydown', onKey);
  collect();
  refresh();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(refresh);
})();

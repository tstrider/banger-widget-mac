/* Banger Widget for Mac. Landing page. Plain JS, no build step.
   Parts: Sound, Party (the full-page celebration), Widget (the working list),
   then one small block per page section. */
(() => {
'use strict';

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const RM = window.matchMedia('(prefers-reduced-motion: reduce)');
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const rand = (a, b) => a + Math.random() * (b - a);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const outCubic = u => 1 - Math.pow(1 - clamp(u, 0, 1), 3);
const outBack = (u, s = 1.7) => { const x = clamp(u, 0, 1) - 1; return 1 + (s + 1) * x * x * x + s * x * x; };
const smooth = u => { u = clamp(u, 0, 1); return u * u * (3 - 2 * u); };
const centre = el => { const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };

/* The row pop uses the app's spring (response 0.5, damping 0.55), sampled into CSS linear(). */
(() => {
  if (!(window.CSS && CSS.supports && CSS.supports('transition-timing-function', 'linear(0, 1)'))) return;
  const w = 2 * Math.PI / 0.5, z = 0.55, wd = w * Math.sqrt(1 - z * z), dur = 0.85, n = 40, pts = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n * dur;
    pts.push((1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + z * w / wd * Math.sin(wd * t))).toFixed(3));
  }
  pts[n] = '1';
  document.documentElement.style.setProperty('--spring', `linear(${pts.join(',')})`);
})();

/* ───────────────────────── Sound ───────────────────────── */

const Sound = (() => {
  const names = ['standard', 'building', 'finalTask', 'streak'];
  const url = n => `assets/sounds/banger_${n}.wav`;
  const raw = {}, buf = {};
  let ctx = null, gain = null, muted = false;
  try { muted = localStorage.getItem('banger-muted') === '1'; } catch (e) { /* private mode */ }

  // Opened straight from a folder (file://) there is no fetch, so plain <audio> plays instead.
  const canFetch = /^https?:$/.test(location.protocol);
  function load() {
    names.forEach(n => {
      if (!raw[n]) raw[n] = canFetch ? fetch(url(n)).then(r => r.ok ? r.arrayBuffer() : null).catch(() => null) : Promise.resolve(null);
    });
  }
  const warm = () => { load(); const idle = window.requestIdleCallback || (f => setTimeout(f, 600)); idle(() => unlock(true)); };
  if (document.readyState === 'complete') warm(); else addEventListener('load', warm, { once: true });

  // Browsers only allow sound after a click or key press, so nothing is created before one.
  function unlock(quiet) {
    if (ctx) { if (quiet !== true && ctx.state === 'suspended') ctx.resume().catch(() => {}); return; }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    try { ctx = new AC(); } catch (e) { ctx = null; return; }
    gain = ctx.createGain(); gain.gain.value = 0.9; gain.connect(ctx.destination);
    load();
    names.forEach(n => {
      buf[n] = raw[n].then(ab => ab ? new Promise(res => ctx.decodeAudioData(ab.slice(0), res, () => res(null))) : null);
    });
  }
  function fallback(n) {
    try { const a = new Audio(url(n)); a.volume = 0.9; a.play().catch(() => {}); } catch (e) { /* no audio */ }
  }
  function play(n) {
    if (muted) return;
    unlock();
    if (!ctx || !buf[n]) return fallback(n);
    buf[n].then(b => {
      if (!b) return fallback(n);
      const s = ctx.createBufferSource(); s.buffer = b; s.connect(gain); s.start();
    });
  }
  function setMuted(m) {
    muted = m;
    try { localStorage.setItem('banger-muted', m ? '1' : '0'); } catch (e) { /* private mode */ }
  }
  addEventListener('pointerdown', unlock, { capture: true, passive: true });
  addEventListener('keydown', unlock, { capture: true, passive: true });
  const state = async () => ({ ctx: ctx ? ctx.state : 'none', decoded: (await Promise.all(names.map(n => buf[n] || null))).map(b => b ? +b.duration.toFixed(2) : 0) });
  return { play, setMuted, state, get muted() { return muted; } };
})();

/* ───────────────────────── Party ─────────────────────────
   The full-page celebration, on one canvas. Each level has its own shape, as in the app:
   a normal task is a fan, the last task adds a line struck through the checkbox,
   and the last task on a streak adds a ring first, then the line. */

const Party = (() => {
  const cv = $('#party'), g = cv.getContext('2d'), flashEl = $('#flash');
  const PAL = ['#0DD9BF', '#FFC71F', '#FF4D6B', '#738CFF', '#B3FF59', '#FFFFFF'];
  const WB = [0.45, 0.22, 0.15, 0.08, 0.05, 0.05];        // the burst: teal leads
  const WT = [0.615, 0.185, 0.075, 0, 0, 0.125];          // ring and line: teal, gold, pink, white
  const WK = [0.53, 0.21, 0.095, 0, 0, 0.165];            // the back of a chip
  const WS = [0.3, 0.45, 0.05, 0, 0, 0.2];                // sparks run gold
  const CAP = 900;
  const parts = [], fx = [], sched = [];
  let W = 0, H = 0, D = 1, S = 1, G = 2500, raf = 0, last = 0, clock = 0, frozen = false;

  function size() {
    W = window.innerWidth; H = window.innerHeight;
    D = Math.min(window.devicePixelRatio || 1, 2, Math.max(1, Math.sqrt(2.6e6 / (W * H))));
    const cw = Math.round(W * D), ch = Math.round(H * D);
    if (cv.width !== cw || cv.height !== ch) { cv.width = cw; cv.height = ch; }
    S = clamp(Math.sqrt(W * H) / 1150, 0.62, 1.2);
    G = 2500 * S;
  }
  addEventListener('resize', size);
  size();

  const pick = w => { let r = Math.random(); for (let i = 0; i < w.length; i++) { r -= w[i]; if (r <= 0) return i; } return 0; };
  const at = (t, f) => sched.push({ t, f });

  // k: 0 chip, 1 dot, 2 thin line, 3 ribbon, 4 spark
  function add(x, y, vx, vy, o) {
    if (parts.length >= CAP) return null;
    o = o || {};
    let k = o.k;
    if (k == null) { const r = Math.random(); k = r < 0.66 ? 0 : r < 0.8 ? 1 : 2; }
    const z = (o.z || 1) * S;
    const p = { k, x, y, vx, vy, rot: rand(0, 6.283), vr: rand(-8, 8), flip: Math.random(), vf: rand(0.9, 3.2),
                c: pick(o.pal || WB), b: pick(WK), vt: rand(430, 860) * S, age: 0, ph: rand(0, 6.283),
                life: 0, w: 0, h: 0, ring: null, hide: false };
    if (k === 0) { p.w = rand(8, 13) * z; p.h = p.w * rand(1, 1.8); }
    else if (k === 1) { p.w = rand(3, 5.2) * z; p.vt *= 1.15; }
    else if (k === 2) { p.w = rand(1.6, 2.4) * z; p.h = rand(18, 34) * z; p.vt *= 1.1; }
    else if (k === 3) { p.w = rand(3.6, 5.2) * z; p.h = rand(26, 44) * z; p.vt = rand(330, 520) * S; p.vr = rand(-3, 3); }
    else { p.w = rand(2.4, 3.8) * z; p.h = rand(8, 15) * z; p.life = rand(0.2, 0.36); p.vt = rand(210, 330) * S; p.rot = Math.atan2(vy, vx) + Math.PI / 2; p.vr = 0; }
    parts.push(p);
    return p;
  }

  function fan(x, y, n, axis, spread, k, pal) {
    for (let i = 0; i < n; i++) {
      const a = axis + (Math.random() + Math.random() - 1) * spread;
      const v = (0.22 + 0.78 * Math.pow(Math.random(), 0.8)) * 2300 * S * k;
      add(x, y, Math.cos(a) * v, Math.sin(a) * v, { pal });
    }
  }
  function sparks(x, y, n, axis, spread, k) {
    for (let i = 0; i < n; i++) {
      const a = axis + (Math.random() * 2 - 1) * spread, v = rand(500, 1900) * S * k;
      add(x, y, Math.cos(a) * v, Math.sin(a) * v, { k: 4, pal: WS });
    }
  }
  function ribbons(x, y, n, axis, k) {
    for (let i = 0; i < n; i++) {
      const a = axis + (Math.random() * 2 - 1) * 1.1, v = rand(700, 1900) * S * k;
      add(x, y, Math.cos(a) * v, Math.sin(a) * v, { k: 3 });
    }
  }

  function shock(x, y, R) {
    fx.push({ t0: clock, dur: 0.34, draw(t) {
      const u = t / 0.34;
      g.strokeStyle = `rgba(255,245,214,${0.85 * (1 - u)})`;
      g.lineWidth = Math.max(0.1, 6 * S * (1 - u));
      g.beginPath(); g.arc(x, y, R * outCubic(u), 0, 6.283); g.stroke();
    } });
  }

  // A ring of chips blooms off the checkbox, overshoots, settles, and lets go.
  function ring(x, y, t0, n, k) {
    const R = clamp(Math.min(W, H) * 0.3, 120, 330) * k;
    for (let i = 0; i < n; i++) {
      const p = add(x, y, 0, 0, { k: Math.random() < 0.85 ? 0 : 1, pal: WT, z: 1.2 });
      if (!p) break;
      p.hide = true;
      p.ring = { x, y, a: i / n * 6.283 + rand(-0.03, 0.03), R: R * rand(0.94, 1.06), t0: t0 + (i / n) * 0.1 + rand(0, 0.02), rel: rand(0.03, 0.12) };
    }
    fx.push({ t0, dur: 0.44, draw(t) {
      const w = 4 * S * (1 - smooth((t - 0.12) / 0.3));
      if (w <= 0.05) return;
      g.strokeStyle = 'rgba(13,217,191,.9)'; g.lineWidth = w;
      g.beginPath(); g.arc(x, y, R * outBack(t / 0.2) * 1.02, 0, 6.283); g.stroke();
    } });
  }

  function lens(x0, x1, mx, y, w) {
    g.beginPath(); g.moveTo(x0, y);
    g.quadraticCurveTo(mx, y - w, x1, y);
    g.quadraticCurveTo(mx, y + w, x0, y);
    g.fill();
  }

  // One line struck through the checkbox and across the page, throwing chips as it goes.
  function strike(x, y, t0, n) {
    const dir = x > W / 2 ? -1 : 1;
    const xs = x - dir * Math.min(110 * S, dir < 0 ? W - x : x);
    const xe = dir < 0 ? -30 : W + 30;
    const T = 0.22, order = [];
    for (let i = 0; i < n; i++) order.push(Math.random());
    order.sort((a, b) => a - b);
    let idx = 0;
    fx.push({ t0, dur: 0.6,
      update(t) {
        const head = outCubic(t / T);
        while (idx < n && order[idx] <= head) {
          const f = order[idx++], up = Math.random() < 0.74;
          const r = Math.random();
          add(xs + (xe - xs) * f, y,
              dir * rand(-60, 300) * S + rand(-140, 140) * S,
              up ? -rand(260, 1500) * S : rand(80, 460) * S,
              { pal: WT, z: 1.22, k: r < 0.8 ? 0 : r < 0.9 ? 1 : 3 });
        }
      },
      draw(t) {
        const hx = xs + (xe - xs) * outCubic(t / T);
        const w = 11 * S * (1 - smooth((t - 0.26) / 0.3));
        if (w < 0.1) return;
        const mx = xs + (hx - xs) * 0.72;
        g.globalCompositeOperation = 'lighter';
        g.fillStyle = 'rgba(13,217,191,.22)'; lens(xs, hx, mx, y, w * 3.4);
        g.globalCompositeOperation = 'source-over';
        g.fillStyle = '#0DD9BF'; lens(xs, hx, mx, y, w);
        g.fillStyle = 'rgba(255,245,214,.92)'; lens(xs, hx, mx, y, w * 0.34);
      } });
  }

  function star(n, R, r, rot, seed) {
    g.beginPath();
    for (let i = 0; i < n * 2; i++) {
      const a = rot + i * Math.PI / n;
      const rad = i % 2 ? r : R * (1 + 0.2 * Math.sin(seed + i * 2.4));
      const px = Math.cos(a) * rad, py = Math.sin(a) * rad;
      if (i) g.lineTo(px, py); else g.moveTo(px, py);
    }
    g.closePath(); g.fill();
  }

  // The ending: the app icon's starburst lands on the box it all started from.
  function accent(x, y, t0) {
    at(t0, () => {
      sparks(x, y, 44, 0, Math.PI, 1.1);
      for (let i = 0; i < 30; i++) {
        const a = rand(0, 6.283), v = rand(300, 1100) * S;
        add(x, y, Math.cos(a) * v, Math.sin(a) * v - 200 * S, { pal: WT, z: 1.1 });
      }
    });
    fx.push({ t0, dur: 0.64, draw(t) {
      const sc = (0.25 + 0.75 * outBack(t / 0.16, 2.2)) * (1 + 0.25 * smooth((t - 0.3) / 0.32)) * S;
      g.globalAlpha = 1 - smooth((t - 0.34) / 0.28);
      g.translate(x, y); g.scale(sc, sc);
      g.fillStyle = '#FFC71F'; star(12, 62, 35, 0.2, 1);
      g.fillStyle = '#0b0b0d'; star(8, 41, 26, 0.5, 3);
      g.fillStyle = '#FF4D6B'; star(8, 35, 22, 0.5, 3);
      g.fillStyle = '#0b0b0d'; star(5, 21, 12.5, -0.3, 5);
      g.fillStyle = '#0DD9BF'; star(5, 16, 9.5, -0.3, 5);
      g.globalAlpha = 1;
    } });
  }

  function step(dt) {
    clock += dt;
    for (let i = sched.length - 1; i >= 0; i--) {
      if (sched[i].t <= clock) { const f = sched[i].f; sched.splice(i, 1); f(); }
    }
    for (let i = fx.length - 1; i >= 0; i--) {
      const e = fx[i], t = clock - e.t0;
      if (t >= 0 && e.update) e.update(t);
      if (t > e.dur) fx.splice(i, 1);
    }
    for (let i = parts.length - 1; i >= 0; i--) {
      const p = parts[i];
      if (p.ring) {
        const r = p.ring, t = clock - r.t0;
        if (t < 0) continue;
        p.hide = false; p.rot += p.vr * dt; p.flip += p.vf * dt;
        if (t < 0.185 + r.rel) {
          const rr = r.R * outBack(t / 0.185);
          p.x = r.x + Math.cos(r.a) * rr; p.y = r.y + Math.sin(r.a) * rr;
          continue;
        }
        const v = rand(160, 520) * S;
        p.vx = Math.cos(r.a) * v; p.vy = Math.sin(r.a) * v - 140 * S; p.ring = null;
      }
      p.age += dt;
      // Quadratic drag with a terminal fall speed: the burst opens fast, then drifts down.
      let vt = p.vt;
      if (p.k === 0) vt *= 1.4 - 0.4 * Math.abs(Math.cos(p.flip * 6.283));
      const f = 1 / (1 + G / (vt * vt) * Math.hypot(p.vx, p.vy) * dt);
      p.vx *= f; p.vy = p.vy * f + G * dt;
      if (p.k !== 4) p.vx += Math.sin(p.age * 2.6 + p.ph) * 90 * S * dt;
      p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.vr * dt; p.flip += p.vf * dt;
      if ((p.k === 4 && p.age > p.life) || p.y > H + 50 || p.x < -90 || p.x > W + 90) {
        parts[i] = parts[parts.length - 1]; parts.pop();
      }
    }
  }

  function draw() {
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, cv.width, cv.height);
    for (const e of fx) {
      const t = clock - e.t0;
      if (t >= 0 && t <= e.dur) { g.setTransform(D, 0, 0, D, 0, 0); e.draw(t); }
    }
    g.lineCap = 'round'; g.lineJoin = 'round';
    for (const p of parts) {
      if (p.hide) continue;
      const c = Math.cos(p.rot) * D, s = Math.sin(p.rot) * D;
      g.setTransform(c, s, -s, c, p.x * D, p.y * D);
      if (p.k === 0) {
        const face = Math.cos(p.flip * 6.283), w = p.w * Math.max(0.1, Math.abs(face));
        g.fillStyle = PAL[face < 0 ? p.b : p.c];
        g.fillRect(-w / 2, -p.h / 2, w, p.h);
      } else if (p.k === 1) {
        g.fillStyle = PAL[p.c]; g.beginPath(); g.arc(0, 0, p.w, 0, 6.283); g.fill();
      } else if (p.k === 2) {
        g.fillStyle = PAL[p.c]; g.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
      } else if (p.k === 3) {
        g.strokeStyle = PAL[p.c]; g.lineWidth = p.w;
        g.beginPath();
        for (let j = 0; j <= 8; j++) {
          const u = j / 8, xx = (u - 0.5) * p.h, yy = Math.sin(u * 7.2 + p.age * 7 + p.ph) * p.w * 1.5;
          if (j) g.lineTo(xx, yy); else g.moveTo(xx, yy);
        }
        g.stroke();
      } else {
        const u = 1 - p.age / p.life;
        g.globalAlpha = Math.min(1, u * 2.2);
        g.fillStyle = PAL[p.c]; g.fillRect(-p.w / 2, -p.h / 2, p.w, p.h * (0.4 + 0.6 * u));
        g.globalAlpha = 1;
      }
    }
  }

  function frame(now) {
    const dt = Math.min(0.034, (now - last) / 1000);
    last = now;
    step(dt); draw();
    if (parts.length || fx.length || sched.length) raf = requestAnimationFrame(frame);
    else { raf = 0; g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, cv.width, cv.height); }
  }
  function kick() {
    if (raf || frozen) return;
    last = performance.now();
    raf = requestAnimationFrame(frame);
  }

  function flash(tier, x, y) {
    const calm = RM.matches;
    const A = { standard: 0.16, building: 0.2, final: 0.34, streak: 0.42 }[tier] * (calm ? 0.5 : 1);
    const R = { standard: 38, building: 46, final: 95, streak: 120 }[tier];
    flashEl.style.background = `radial-gradient(circle at ${x}px ${y}px, rgba(255,245,214,${A}) 0, rgba(13,217,191,${A * 0.45}) ${R * 0.35}vmax, rgba(13,217,191,0) ${R}vmax)`;
    if (flashEl.animate) {
      flashEl.animate([{ opacity: 1 }, { opacity: 0 }],
        { duration: calm ? 700 : (tier === 'standard' ? 340 : 560), easing: 'cubic-bezier(.2,.7,.2,1)' });
    }
  }
  // The stand-in for the trackpad thump: the page drops a few pixels and comes back.
  function thump(tier, el) {
    if (RM.matches || !el || !el.animate) return;
    const d = { standard: 3, building: 4, final: 7, streak: 9 }[tier];
    el.animate([{ transform: 'translateY(0)' }, { transform: `translateY(${d}px)`, offset: 0.18 }, { transform: 'translateY(0)' }],
      { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }

  function fire(tier, x, y, card) {
    flash(tier, x, y);
    thump(tier, card);
    if (RM.matches) return;   // the calmer version is the flash alone
    const [n, sp, rb, k] = { standard: [105, 56, 6, 1], building: [135, 70, 8, 1.06], final: [190, 96, 13, 1.2], streak: [235, 118, 18, 1.32] }[tier];
    const t0 = clock;
    const axis = -Math.PI / 2 + clamp((W / 2 - x) / (W / 2), -1, 1) * 0.32;
    fan(x, y, Math.round(n * 0.74), axis, 1.22, k, WB);
    sparks(x, y, sp, axis, 1.5, k);
    ribbons(x, y, rb, axis, k);
    shock(x, y, (150 + 190 * (k - 1)) * S * 1.3);
    at(t0 + 0.32, () => fan(x, y, Math.round(n * 0.26), -Math.PI / 2 + 0.05, 0.3, k * 1.15, WB));
    if (tier === 'building') ring(x, y, t0 + 0.4, 84, 0.8);
    if (tier === 'final') { strike(x, y, t0 + 0.4, 230); accent(x, y, t0 + 0.79); }
    if (tier === 'streak') {
      ring(x, y, t0 + 0.4, 150, 1);
      strike(x, y, t0 + 0.7, 230);
      at(t0 + 0.78, () => fan(x, y, 40, -Math.PI / 2, 0.5, k * 1.2, WB));
      accent(x, y, t0 + 1.07);
    }
    kick();
  }

  // Test hook: draw one still frame of a level, `ms` after it fires.
  function still(tier, x, y, ms) {
    frozen = true;
    fire(tier, x, y);
    for (let t = 0; t < ms; t += 1000 / 60) step(1 / 60);
    draw();
  }

  return { fire, still, get count() { return parts.length; }, get running() { return !!raf; } };
})();

const SOUND_FOR = { standard: 'standard', building: 'building', final: 'finalTask', streak: 'streak' };
const BUZZ = { standard: 12, building: [12, 40, 12], final: [14, 40, 24], streak: [14, 40, 24, 40, 34] };

function celebrate(tier, x, y, card) {
  Party.fire(tier, x, y, card);
  Sound.play(SOUND_FOR[tier]);
  try { if (navigator.vibrate && !RM.matches) navigator.vibrate(BUZZ[tier]); } catch (e) { /* no haptics */ }
}

/* ───────────────────────── The checkbox ───────────────────────── */

const BOX = (() => {
  const speeds = [1.00, 0.66, 1.24, 0.82, 1.08, 0.58, 0.90];
  const spins = [18, -12, 26, -21, 9, -28, 14];
  const r0 = 8.25, stepDeg = 360 / 7, half = (stepDeg - 10.4) / 2;
  let s = '<svg viewBox="0 0 18 18" aria-hidden="true"><circle class="bx-ring" cx="9" cy="9" r="8.25"/>';
  for (let i = 0; i < 7; i++) {
    const mid = i * stepDeg + stepDeg / 2;
    const a0 = (mid - half) * Math.PI / 180, a1 = (mid + half) * Math.PI / 180, am = mid * Math.PI / 180;
    const p = a => `${(9 + r0 * Math.cos(a)).toFixed(2)} ${(9 + r0 * Math.sin(a)).toFixed(2)}`;
    const d = r0 * 0.9 * speeds[i];
    s += `<path class="bx-shard${i % 2 ? ' is-gold' : ''}" pathLength="1" d="M${p(a0)} A${r0} ${r0} 0 0 1 ${p(a1)}" style="--dx:${(Math.cos(am) * d).toFixed(2)}px;--dy:${(Math.sin(am) * d).toFixed(2)}px;--rot:${spins[i]}deg"/>`;
  }
  s += '<circle class="bx-disc" cx="9" cy="9" r="9"/><circle class="bx-rim" cx="9" cy="9" r="8"/>'
     + '<path class="bx-tick" pathLength="1" d="M4.23 9.36 L7.65 12.78 L13.95 5.58"/>'
     + '<circle class="bx-shock" cx="9" cy="9" r="9"/></svg>';
  return s;
})();
const PLUS = '<svg viewBox="0 0 18 18" aria-hidden="true"><path d="M9 3.6v10.8M3.6 9h10.8" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/></svg>';
const CHECK = '<svg viewBox="0 0 18 18" aria-hidden="true"><path d="M4.2 9.4l3.4 3.4 6.3-7.2" fill="none" stroke="#051212" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// Shared gradient for the streak-level ring.
document.body.insertAdjacentHTML('beforeend',
  '<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs><linearGradient id="g-fire" x1="0" y1="1" x2="1" y2="0">'
  + '<stop offset="0" stop-color="#FF4D8C"/><stop offset=".5" stop-color="#FF8029"/><stop offset="1" stop-color="#FFC71F"/></linearGradient></defs></svg>');

function restart(el, cls, ms) { restartAll([[el, cls, ms]]); }
// Start several CSS animations. A forced layout is only needed when one is still running
// and has to start over; otherwise the browser picks the classes up on its next frame.
function restartAll(list) {
  list = list.filter(x => x[0]);
  let live = false;
  for (const [el, cls] of list) if (el.classList.contains(cls)) { live = true; el.classList.remove(cls); }
  if (live) void list[0][0].offsetWidth;
  for (const [el, cls, ms] of list) {
    el.classList.add(cls);
    clearTimeout(el._t && el._t[cls]);
    (el._t || (el._t = {}))[cls] = setTimeout(() => el.classList.remove(cls), ms);
  }
}

function makeRow(text) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'bw-row';
  b.setAttribute('role', 'checkbox');
  b.setAttribute('aria-checked', 'false');
  b.innerHTML = `<span class="bw-row-in"><i class="bw-rail"></i><span class="bw-box">${BOX}</span>`
    + `<span class="bw-label"><span class="bw-text"></span></span><span class="bw-badge"><em>LAST ONE</em>${CHECK}</span></span>`;
  $('.bw-text', b).textContent = text;
  return b;
}

/* ───────────────────────── The streak pill ───────────────────────── */

const tierOf = n => n < 3 ? 'spark' : n < 7 ? 'ember' : n < 30 ? 'blaze' : n < 100 ? 'inferno' : n < 365 ? 'supernova' : 'legend';

function renderPill(el, { streak, atRisk = false, freeMiss = 'none' }) {
  if (streak <= 0) { el.hidden = true; return; }
  el.hidden = false;
  [...el.classList].forEach(c => { if (c.startsWith('pill--') || c === 'is-cold') el.classList.remove(c); });
  el.classList.add('pill--' + tierOf(streak));
  if (atRisk) el.classList.add('is-cold');
  const label = Math.min(streak, 9999).toLocaleString('en-US') + (streak > 9999 ? '+' : '');
  let extra = '', say = `${streak} day streak`;
  if (freeMiss === 'ready') { extra = '<i class="pill-shield"></i>'; say += ', free miss ready'; }
  else if (freeMiss === 'saved' && !atRisk) { extra = '<span class="pill-saved"><i class="pill-shield"></i><em>SAVED</em></span>'; say += ', saved by your free miss yesterday'; }
  if (atRisk) say += ', at risk';
  el.innerHTML = `<i class="pill-flame"></i><b>${label}</b>${extra}`;
  el.setAttribute('role', 'img');
  el.setAttribute('aria-label', say);
}

/* ───────────────────────── The widget ───────────────────────── */

const RAMP = [[13, 217, 191], [77, 158, 255], [255, 77, 140], [255, 199, 31]];
function rampAt(t) {
  const x = clamp(t, 0, 1) * 3, i = Math.min(2, Math.floor(x)), f = x - i, a = RAMP[i], b = RAMP[i + 1];
  return [0, 1, 2].map(j => Math.round(a[j] + (b[j] - a[j]) * f));
}

const SHELL = '<div class="bw-clip"><i class="bw-bloom"></i></div><i class="bw-edge"></i><i class="bw-rim2"></i><i class="bw-sweep"></i>';
const CHEV_UP = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M1.5 6.8L5 3.2l3.5 3.6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const CHEV_DOWN = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M1.5 3.2L5 6.8l3.5-3.6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// A progress ladder for a card that is not the widget's fixed width: each segment
// carries its own slice of the ramp.
function freeLadder(el, n, done) {
  const rgb = t => `rgb(${rampAt(t).join(',')})`;
  el.style.setProperty('--n', n);
  el.innerHTML = Array.from({ length: n }, (_, i) =>
    `<span class="bw-seg${i < done ? ' is-on' : ''}${i === done ? ' is-next' : ''}" style="--g:linear-gradient(90deg,${rgb(i / n)},${rgb((i + 1) / n)});--nc:rgba(${rampAt((i + 0.5) / n).join(',')},.55)"><i></i></span>`).join('')
    + '<span class="bw-merged"></span>';
  el.style.setProperty('--tip', done ? `rgba(${rampAt(done / n).join(',')},.55)` : 'transparent');
}

class Widget {
  constructor(el, opts = {}) {
    this.el = el;
    this.o = opts;
    this.max = opts.family === 'medium' ? 4 : 9;   // rows each size shows
    this.limit = 24;
    this.tasks = [];
    this.streak = 0;
    this.seq = 0;
    this.uid = 0;
    this.scroll = null;
    this.rows = new Map();
    el.innerHTML = SHELL
      + '<div class="bw-pad"><div class="bw-head"><span class="bw-num"><b class="bw-count">0</b><span class="bw-of"></span></span>'
      + '<span class="bw-cleared">CLEARED</span><span class="pill" hidden></span>'
      + `<button type="button" class="bw-add" aria-label="Add a task">${PLUS}</button></div>`
      + '<div class="bw-ladder"></div><div class="bw-list" role="group" aria-label="Today\'s list"></div><div class="bw-arrows"></div>'
      + `<div class="bw-empty"><button type="button" class="bw-add" aria-label="Add a task">${PLUS}</button>`
      + '<div><b>Nothing on today\'s list</b><span>Hit + , or ⌃⌥⌘N from anywhere.</span></div></div></div>';
    this.list = $('.bw-list', el);
    this.ladder = $('.bw-ladder', el);
    this.arrows = $('.bw-arrows', el);
    this.pill = $('.pill', el);
    $$('.bw-add', el).forEach(b => b.addEventListener('click', () => {
      if (this.tasks.length >= this.limit) return restart(b, 'is-full', 320);
      QuickAdd.open(this);
    }));
    this.arrows.addEventListener('click', e => {
      const b = e.target.closest('.bw-arrow');
      if (b) this.scrollTo(+b.dataset.to);
    });
    this.set(opts.tasks || [], opts.streak || 0);
  }

  set(tasks, streak = 0) {
    this.rows.forEach(r => r.remove());
    this.rows.clear();
    this.seq = 0;
    this.scroll = null;
    this.streak = streak;
    this.tasks = tasks.map(t => ({ id: 't' + (++this.uid), text: t.text, done: !!t.done, at: t.done ? ++this.seq : 0 }));
    this.render();
  }

  get done() { return this.tasks.filter(t => t.done).length; }
  get cleared() { return this.tasks.length > 0 && this.done === this.tasks.length; }

  add(text) {
    if (this.tasks.length >= this.limit) return false;
    this.tasks.push({ id: 't' + (++this.uid), text, done: false, at: 0, fresh: true });
    this.render();
    restart(this.el, 'is-arrive', 950);
    return true;
  }

  order() {
    const done = this.tasks.filter(t => t.done).sort((a, b) => a.at - b.at);
    return done.concat(this.tasks.filter(t => !t.done));
  }

  // Which rows are in view. A list that fits shows all of it. A longer one gives its
  // last line to the arrows and rests just past the finished tasks, as the app does.
  plan(n) {
    if (n <= this.max) return { scrolls: false, visible: n, offset: 0 };
    const visible = this.max - 1, maxOff = n - visible, rest = Math.min(this.done, maxOff);
    return { scrolls: true, visible, maxOff, rest, offset: clamp(this.scroll == null ? rest : this.scroll, 0, maxOff) };
  }

  scrollTo(to) {
    const p = this.plan(this.tasks.length);
    this.scroll = to === p.rest ? null : to;
    clearTimeout(this._rest);
    // Five minutes after the last click the list slides back on its own.
    if (this.scroll != null) this._rest = setTimeout(() => { this.scroll = null; this.render(); }, 5 * 60 * 1000);
    this.render();
  }

  header() {
    const n = this.tasks.length, done = this.done, cleared = this.cleared;
    this.el.classList.toggle('is-empty', n === 0);
    this.el.classList.toggle('is-cleared', cleared);
    $('.bw-count', this.el).textContent = done;
    $('.bw-of', this.el).textContent = 'of ' + n;
    renderPill(this.pill, { streak: this.streak });
    const segs = Math.max(1, Math.min(n, 12));
    if (this.ladder.childElementCount !== segs + 1) {
      this.ladder.innerHTML = Array.from({ length: segs }, (_, i) => `<span class="bw-seg" style="--i:${i}"><i></i></span>`).join('') + '<span class="bw-merged"></span>';
      this.ladder.style.setProperty('--n', segs);
    }
    const filled = n ? Math.floor(done / n * segs + 1e-9) : 0;
    $$('.bw-seg', this.ladder).forEach((s, i) => {
      s.classList.toggle('is-on', i < filled);
      const next = i === filled && filled < segs;
      s.classList.toggle('is-next', next);
      if (next) s.style.setProperty('--nc', `rgba(${rampAt((i + 0.5) / segs).join(',')},.55)`);
    });
    this.ladder.style.setProperty('--tip', done ? `rgba(${rampAt(n ? done / n : 0).join(',')},.55)` : 'transparent');
    if (this.o.onChange) this.o.onChange(this);
  }

  // Row state without moving anything. The move comes a beat later, as in the app.
  states() {
    const open = this.tasks.filter(t => !t.done);
    const lastOpen = open.length === 1 && this.tasks.length > 1 ? open[0] : null;
    let closing = lastOpen;
    if (!closing && this.cleared && this.tasks.length > 1) closing = this.tasks.reduce((a, b) => (b.at > a.at ? b : a));
    this.tasks.forEach(t => {
      const r = this.rows.get(t.id);
      if (!r) return;
      r.classList.toggle('is-done', t.done);
      r.classList.toggle('is-last', t === lastOpen);
      r.classList.toggle('has-badge', t === closing);
      r.setAttribute('aria-checked', t.done ? 'true' : 'false');
    });
  }

  render() {
    const order = this.order(), p = this.plan(order.length);
    order.forEach((t, i) => {
      const y = i - p.offset, off = p.scrolls && (y < 0 || y >= p.visible);
      let r = this.rows.get(t.id);
      if (!r) {
        r = makeRow(t.text);
        r.addEventListener('click', () => this.toggle(t));
        r.style.setProperty('--yi', y);
        this.rows.set(t.id, r);
        this.list.appendChild(r);
        if (t.fresh) { t.fresh = false; this.pop(r, true); }
      } else if (t.rose && i < r._i && !off && !RM.matches) {
        // It leaves its old spot and bounces into the new one near the top.
        const ghost = r.cloneNode(true);
        ghost.classList.add('bw-ghost');
        ghost.setAttribute('aria-hidden', 'true');
        ghost.tabIndex = -1;
        this.list.appendChild(ghost);
        setTimeout(() => ghost.remove(), 240);
        r.style.transition = 'none';
        r.style.setProperty('--yi', y);
        void r.offsetWidth;
        r.style.transition = '';
        this.pop(r, false);
      } else {
        r.style.setProperty('--yi', y);
      }
      r._i = i;
      r.classList.toggle('is-off', off);
      r.tabIndex = off ? -1 : 0;
      if (off) r.setAttribute('aria-hidden', 'true'); else r.removeAttribute('aria-hidden');
      t.rose = false;
    });
    this.el.classList.toggle('is-scroll', p.scrolls);
    this.list.style.height = `calc(var(--pitch) * ${p.visible})`;
    if (p.scrolls) {
      const step = Math.max(1, p.visible - 1), below = order.length - p.offset - p.visible;
      let up = Math.max(0, p.offset - step), down = Math.min(p.maxOff, p.offset + step);
      if (p.offset > p.rest && up < p.rest) up = p.rest;       // the resting place is one tap away
      if (p.offset < p.rest && down > p.rest) down = p.rest;
      this.arrows.innerHTML =
        (p.offset > 0 ? `<button type="button" class="bw-arrow" data-to="${up}">${CHEV_UP}<span>${p.offset} ${p.offset <= this.done ? 'done' : 'above'}</span></button>` : '')
        + (below > 0 ? `<button type="button" class="bw-arrow is-down" data-to="${down}"><span>${below} more</span>${CHEV_DOWN}</button>` : '');
    } else this.arrows.innerHTML = '';
    this.states();
    this.header();
  }

  pop(r, isNew) {
    const inner = $('.bw-row-in', r);
    inner.classList.remove('is-pop', 'is-new');
    void inner.offsetWidth;
    inner.classList.add('is-pop');
    if (isNew) inner.classList.add('is-new');
    setTimeout(() => inner.classList.remove('is-pop', 'is-new'), 1150);
  }

  toggle(t) {
    const r = this.rows.get(t.id);
    if (t.done) {            // unchecking is quiet
      t.done = false; t.at = 0; t.rose = false;
      clearTimeout(this._move);
      this.render();
      return;
    }
    t.done = true; t.at = ++this.seq; t.rose = true;
    const n = this.tasks.length, done = this.done, cleared = done === n;
    const tier = cleared ? (this.streak > 0 ? 'streak' : 'final') : (done / n > 0.6 ? 'building' : 'standard');

    const [x, y] = centre($('.bw-box', r));
    const card = this.el.getBoundingClientRect();
    this.el.style.setProperty('--ix', (x - card.left) + 'px');
    this.el.style.setProperty('--iy', (y - card.top) + 'px');
    this.el.style.setProperty('--reach', cleared ? 1 : 0.42);

    // Everything lands on the same frame: the tick, the count, the bar.
    this.states();
    this.header();
    const seg = cleared ? null : $$('.bw-seg', this.ladder)[Math.floor(done / n * Math.min(n, 12) + 1e-9) - 1];
    restartAll([[r, 'is-firing', 460], [this.el, 'is-firing', 460], [seg, 'is-landing', 340]]);

    clearTimeout(this._move);
    this._move = setTimeout(() => this.render(), RM.matches ? 0 : 300);
    if (this.o.onCheck) this.o.onCheck({ tier, x, y, cleared, widget: this });
  }

  checkFirstOpen() {
    const t = this.tasks.find(t => !t.done);
    if (t) this.toggle(t);
    return !!t;
  }
}

/* ───────────────────────── Quick add ───────────────────────── */

const QuickAdd = (() => {
  const el = $('#qa'), form = $('#qa-form'), input = $('#qa-input');
  let target = null, back = null;
  function open(widget) {
    target = widget;
    back = document.activeElement;
    input.value = '';
    el.classList.add('is-open');
    el.setAttribute('aria-hidden', 'false');
    input.focus({ preventScroll: true });
  }
  function close() {
    if (!el.classList.contains('is-open')) return;
    el.classList.remove('is-open');
    el.setAttribute('aria-hidden', 'true');
    input.blur();
    if (back && back.focus) back.focus({ preventScroll: true });
  }
  form.addEventListener('submit', e => {
    e.preventDefault();
    const text = input.value.trim();
    if (text && target) target.add(text);
    close();
  });
  el.addEventListener('pointerdown', e => { if (e.target === el) close(); });
  addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
  return { open, close, get isOpen() { return el.classList.contains('is-open'); } };
})();

/* ───────────────────────── Hero ───────────────────────── */

const HERO_TASKS = [
  { text: 'Reply to Sam', done: true },
  { text: 'Pay the water bill', done: true },
  { text: 'Back up the laptop', done: true },
  { text: 'Book the van' },
  { text: 'Mix down the B-side' },
  { text: 'Water the plants' },
  { text: 'Renew the passport' },
  { text: 'Email the landlord' },
  { text: 'Take out the recycling' },
];

const navLedger = $('#nav-ledger'), navLadder = $('#nav-ladder');
const streakBtn = $('#hero-streak'), streakLabel = $('#hero-streak-label');
let streakMode = false;

const hero = new Widget($('#hero-widget'), {
  tasks: HERO_TASKS,
  onCheck({ tier, x, y, cleared, widget }) {
    celebrate(tier, x, y, widget.el);
    if (cleared && !streakMode) streakBtn.classList.add('is-hot');
  },
  onChange(w) {
    // The same list, riding along in the nav once the widget has scrolled away.
    const n = w.tasks.length, done = w.done;
    $('#nav-count').textContent = done;
    $('#nav-of').textContent = 'of ' + n;
    navLadder.innerHTML = Array.from({ length: Math.max(1, Math.min(n, 12)) }, (_, i) =>
      `<i class="${i < done ? 'is-on' : ''}" style="--c:rgb(${rampAt(n > 1 ? i / (n - 1) : 0).join(',')})"></i>`).join('');
  },
});

function heroReset() {
  hero.set(HERO_TASKS, streakMode ? 12 : 0);
  streakBtn.classList.remove('is-hot');
}
$('#hero-reset').addEventListener('click', heroReset);
streakBtn.addEventListener('click', () => {
  streakMode = !streakMode;
  streakBtn.setAttribute('aria-pressed', streakMode ? 'true' : 'false');
  streakLabel.textContent = streakMode ? 'Try it with no streak' : 'Try it on a 12-day streak';
  heroReset();
});

if ('IntersectionObserver' in window) {
  new IntersectionObserver(([e]) => navLedger.classList.toggle('is-in', !e.isIntersecting), { rootMargin: '-68px 0px 0px 0px' })
    .observe($('#hero-widget'));
}
const nav = $('#nav');
const onScroll = () => nav.classList.toggle('is-stuck', window.scrollY > 12);
addEventListener('scroll', onScroll, { passive: true });
onScroll();

/* Mute */
const muteBtn = $('#mute');
function paintMute() {
  muteBtn.setAttribute('aria-pressed', Sound.muted ? 'true' : 'false');
  muteBtn.setAttribute('aria-label', Sound.muted ? 'Turn sound on' : 'Mute sound');
}
muteBtn.addEventListener('click', () => { Sound.setMuted(!Sound.muted); paintMute(); });
paintMute();

/* The loose confetti behind the page. Placed by script so no piece starts on the hero text
   or the widget. It leans with the pointer, and as the page scrolls each piece rises at its
   own speed: near ones fast, far ones slow. A piece that leaves the top comes back at the bottom. */
(() => {
  const host = $('.scatter'), heroEl = $('.hero');
  const SQ = '<path d="M6 20c6-16 14-16 20-4s14 12 28-6"/>';
  const calm = RM.matches;
  let bits = [], mx = 0, my = 0, cx = 0, cy = 0, sy = window.scrollY, csy = sy, raf = 0, field = 1, shownOp = '';
  // Fixed behind everything, outside <main>, so the page's thump does not carry it along.
  if (!calm) { document.body.prepend(host); host.classList.add('is-fixed'); }

  function seeded(a) {
    return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  }
  function paint() {
    // Past the hero the pieces pass behind the text, so they drop back to a quiet level.
    const op = (1 - 0.62 * clamp(csy / (window.innerHeight * 0.5), 0, 1)).toFixed(2);
    if (op !== shownOp) host.style.opacity = shownOp = op;
    for (const b of bits) {
      const px = -cx * 34 * b.d;
      let y = b.y - csy * (0.1 + 0.45 * b.d);
      y = ((y + 80) % field + field) % field - 80;
      b.el.style.transform = `translate3d(${(b.x + px).toFixed(1)}px,${(y - cy * 26 * b.d).toFixed(1)}px,0) rotate(${(b.r + csy * b.w).toFixed(1)}deg) scale(${b.s})`;
    }
  }
  function place() {
    host.innerHTML = ''; bits = [];
    const R = heroEl.getBoundingClientRect(), W = R.width, H = R.height;
    field = Math.max(H, window.innerHeight) + 160;
    const blocks = [...$$('.hero-copy > *'), ...$$('.hero-stage > *')].map(e => {
      const r = e.getBoundingClientRect();
      return [r.left - R.left, r.top - R.top, r.right - R.left, r.bottom - R.top];
    });
    const M = 70, rnd = seeded(11), want = Math.round(clamp(W * H / 46000, 0, 30));
    const colors = ['#0DD9BF', '#0DD9BF', '#FFC71F', '#FFC71F', '#FF4D6B', '#738CFF', '#B3FF59', '#FFFFFF'];
    for (let tries = 0; bits.length < want && tries < 900; tries++) {
      const x = 20 + rnd() * (W - 40), y = 96 + rnd() * (H - 130), d = 0.25 + 0.75 * rnd(), kind = rnd(), col = colors[Math.floor(rnd() * colors.length)], rot = Math.round(rnd() * 360);
      if (blocks.some(b => x > b[0] - M && x < b[2] + M && y > b[1] - M && y < b[3] + M)) continue;
      if (bits.some(o => Math.hypot(o.x - x, o.y - y) < 84)) continue;
      let el;
      if (kind < 0.24) { el = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); el.setAttribute('viewBox', '0 0 60 30'); el.setAttribute('class', 'sc sc-sq'); el.innerHTML = SQ; }
      else { el = document.createElement('i'); el.className = 'sc ' + (kind < 0.52 ? 'sc-dot' : 'sc-chip'); }
      el.style.setProperty('--c', col);
      // Far pieces are small, dim and soft. Near ones are large and crisp.
      el.style.opacity = (0.28 + 0.72 * d).toFixed(2);
      if (d < 0.5) el.style.filter = `blur(${(1.6 * (0.5 - d) / 0.25).toFixed(1)}px)`;
      host.appendChild(el);
      bits.push({ el, x, y, d, r: rot, w: (rnd() - 0.5) * 0.16, s: +(0.5 + 0.75 * d).toFixed(2) });
    }
    paint();
  }
  function tick() {
    cx += (mx - cx) * 0.07; cy += (my - cy) * 0.07; csy += (sy - csy) * 0.14;
    paint();
    raf = (Math.abs(mx - cx) + Math.abs(my - cy) > 0.002 || Math.abs(sy - csy) > 0.5) ? requestAnimationFrame(tick) : 0;
  }
  const wake = () => { if (!raf && !calm) raf = requestAnimationFrame(tick); };
  if (!calm) {
    addEventListener('pointermove', e => {
      if (e.pointerType === 'touch') return;
      mx = e.clientX / window.innerWidth - 0.5; my = e.clientY / window.innerHeight - 0.5; wake();
    }, { passive: true });
    addEventListener('scroll', () => { sy = window.scrollY; wake(); }, { passive: true });
  }
  let rt = 0;
  addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(place, 160); });
  (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(() => setTimeout(place, 700));
})();

/* ───────────────────────── The difference ───────────────────────── */

(() => {
  const dull = $('#dull-box');
  let dullTimer = 0;
  dull.addEventListener('change', () => {
    clearTimeout(dullTimer);
    if (dull.checked) dullTimer = setTimeout(() => { dull.checked = false; }, 2600);
  });

  const card = $('#duo-banger');
  card.innerHTML = '<div class="bw-clip"><i class="bw-bloom"></i></div><i class="bw-edge"></i><i class="bw-sweep"></i><div class="bw-pad"></div>';
  const row = makeRow('Send the invoice');
  $('.bw-pad', card).appendChild(row);
  let timer = 0;
  row.addEventListener('click', () => {
    clearTimeout(timer);
    if (row.classList.contains('is-done')) {
      row.classList.remove('is-done'); row.setAttribute('aria-checked', 'false');
      return;
    }
    const [x, y] = centre($('.bw-box', row));
    const r = card.getBoundingClientRect();
    card.style.setProperty('--ix', (x - r.left) + 'px');
    card.style.setProperty('--iy', (y - r.top) + 'px');
    card.style.setProperty('--reach', 0.6);
    row.classList.add('is-done'); row.setAttribute('aria-checked', 'true');
    restartAll([[row, 'is-firing', 460], [card, 'is-firing', 460]]);
    celebrate('standard', x, y, card);
    timer = setTimeout(() => { row.classList.remove('is-done'); row.setAttribute('aria-checked', 'false'); }, 2600);
  });
})();

/* ───────────────────────── Three levels ─────────────────────────
   Three pieces of the real widget, each a size up from the last. */

$$('.lv').forEach(card => {
  const tier = card.dataset.tier, big = tier === 'streak', last = tier !== 'standard';
  card.innerHTML = SHELL + '<div class="bw-pad">'
    + (big ? '<div class="bw-head"><span class="bw-num"><b class="bw-count">4</b><span class="bw-of">of 5</span></span><span class="bw-cleared">CLEARED</span><span class="pill"></span></div><div class="bw-ladder bw-ladder--free"></div>' : '')
    + '</div>';
  const row = makeRow(card.dataset.text);
  $('.bw-pad', card).appendChild(row);
  const count = $('.bw-count', card), ladder = $('.bw-ladder', card);
  if (big) renderPill($('.pill', card), { streak: 12 });
  let timer = 0;
  function rest() {
    clearTimeout(timer);
    row.classList.remove('is-done');
    row.classList.toggle('is-last', last);
    row.classList.toggle('has-badge', last);
    row.setAttribute('aria-checked', 'false');
    card.classList.remove('is-cleared');
    if (big) { count.textContent = '4'; freeLadder(ladder, 5, 4); }
  }
  rest();
  row.addEventListener('click', () => {
    if (row.classList.contains('is-done')) return rest();
    const [x, y] = centre($('.bw-box', row));
    const r = card.getBoundingClientRect();
    card.style.setProperty('--ix', (x - r.left) + 'px');
    card.style.setProperty('--iy', (y - r.top) + 'px');
    card.style.setProperty('--reach', last ? 1 : 0.5);
    row.classList.add('is-done');
    row.classList.remove('is-last');
    row.setAttribute('aria-checked', 'true');
    if (last) card.classList.add('is-cleared');
    if (big) { count.textContent = '5'; freeLadder(ladder, 5, 5); }
    restartAll([[row, 'is-firing', 460], [card, 'is-firing', 460]]);
    celebrate(tier, x, y, card);
    clearTimeout(timer);
    timer = setTimeout(rest, 3000);
  });
});

/* ───────────────────────── Streak ───────────────────────── */

(() => {
  const slider = $('#days'), out = $('#days-out'), pill = $('#big-pill'), stage = pill.parentElement;
  const missBtn = $('#miss'), lateBtn = $('#late'), status = $('#streak-status');
  // Each step of the flame gets the same share of the slider.
  const POS = [0, 40, 200, 360, 520, 680, 900, 1000];
  const DAY = [0, 1, 3, 7, 30, 100, 365, 400];
  const TIERS = ['spark', 'ember', 'blaze', 'inferno', 'supernova', 'legend'];
  const GLOW = { spark: 'rgba(13,217,191,.2)', ember: 'rgba(255,128,41,.24)', blaze: 'rgba(255,77,140,.26)', inferno: 'rgba(255,77,140,.34)', supernova: 'rgba(255,199,31,.34)', legend: 'rgba(255,199,31,.46)' };
  const toDay = v => { for (let i = 1; i < POS.length; i++) if (v <= POS[i]) return Math.round(DAY[i - 1] + (DAY[i] - DAY[i - 1]) * (v - POS[i - 1]) / (POS[i] - POS[i - 1])); return 400; };
  const toPos = d => { for (let i = 1; i < DAY.length; i++) if (d <= DAY[i]) return Math.round(POS[i - 1] + (POS[i] - POS[i - 1]) * (d - DAY[i - 1]) / (DAY[i] - DAY[i - 1])); return 1000; };
  const st = { streak: 4, miss: 'ready', since: 0, late: false };
  let shown = '';

  function paint() {
    out.textContent = st.streak;
    const atRisk = st.late && st.streak > 0;
    if (st.streak > 0) {
      const tier = tierOf(st.streak), key = tier + (atRisk ? '-cold' : '') + st.miss;
      renderPill(pill, { streak: st.streak, atRisk, freeMiss: st.miss });
      pill.classList.remove('is-out');
      if (key !== shown && shown) restart(pill, 'is-bump', 600);   // the flame steps up
      shown = key;
      stage.style.setProperty('--stage-glow', atRisk ? 'rgba(140,209,255,.2)' : GLOW[tier]);
      stage.style.setProperty('--gs', (0.5 + 0.1 * TIERS.indexOf(tier)).toFixed(2));
    } else {
      pill.classList.add('is-out');
      shown = 'none';
      stage.style.setProperty('--stage-glow', 'transparent');
    }
    missBtn.disabled = st.streak <= 0;
  }
  slider.addEventListener('input', () => {
    const d = toDay(+slider.value);
    let msg = '';
    if (d > st.streak && st.miss !== 'ready') {
      st.since += d - st.streak;
      if (st.since >= 7) { st.miss = 'ready'; msg = 'Seven days on, the free miss is back.'; }
      else if (st.miss === 'saved') st.miss = 'none';
    }
    st.streak = d;
    status.textContent = msg;
    paint();
  });
  missBtn.addEventListener('click', () => {
    if (st.streak <= 0) return;
    if (st.miss === 'ready') {
      st.miss = 'saved'; st.since = 0;
      status.textContent = 'Missed a day. The streak keeps its number.';
    } else {
      st.streak = 0; st.miss = 'none'; st.since = 0; slider.value = 0;
      status.textContent = 'A second miss within seven days. Back to zero.';
    }
    paint();
  });
  lateBtn.addEventListener('click', () => {
    st.late = !st.late;
    lateBtn.setAttribute('aria-pressed', st.late ? 'true' : 'false');
    paint();
  });
  slider.value = toPos(st.streak);
  paint();
})();

/* ───────────────────────── Assistant ───────────────────────── */

const agent = new Widget($('#agent-widget'), {
  family: 'medium',
  onCheck({ tier, x, y, widget }) { celebrate(tier, x, y, widget.el); },
});

(() => {
  const body = $('#term-body');
  const add = text => ({ cmd: `bangerctl add "${text}" --source iris`, run: () => agent.add(text) });
  const LINES = [
    add('Call the realtor'),
    add('Export the invoices'),
    add('Order printer ink'),
    add('Stretch for ten minutes'),
    { cmd: 'bangerctl done 1', wait: true, run: () => agent.checkFirstOpen() },
  ];
  const RETURN = '<svg viewBox="0 0 18 18" aria-hidden="true"><path d="M14 4v5.5H5M8 6.2L4.7 9.5 8 12.8" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const paintCmd = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/("[^"]*"?)/g, '<span class="q">$1</span>').replace(/(--\w+)/g, '<span class="f">$1</span>');
  let run = 0;

  function line() {
    const el = document.createElement('div');
    el.className = 'term-line';
    el.innerHTML = '<span class="term-cmd"></span>';
    body.appendChild(el);
    return el;
  }
  async function type(el, text, id) {
    const cmd = $('.term-cmd', el);
    if (RM.matches) { cmd.innerHTML = paintCmd(text); return; }
    for (let i = 1; i <= text.length; i++) {
      if (id !== run) return;
      cmd.innerHTML = paintCmd(text.slice(0, i)) + '<i class="term-caret"></i>';
      await sleep(text[i - 1] === ' ' ? 46 : 20 + Math.random() * 22);
    }
    cmd.innerHTML = paintCmd(text);
  }
  async function play() {
    const id = ++run;
    body.innerHTML = '';
    agent.set([]);
    await sleep(RM.matches ? 0 : 500);
    for (const L of LINES) {
      if (id !== run) return;
      const el = line();
      await type(el, L.cmd, id);
      if (id !== run) return;
      if (L.wait) {
        const btn = document.createElement('button');
        btn.type = 'button'; btn.className = 'term-run';
        btn.innerHTML = RETURN + '<span>Return</span>';
        el.appendChild(btn);
        await new Promise(res => btn.addEventListener('click', res, { once: true }));
        if (id !== run) return;
        btn.remove();
      } else {
        await sleep(RM.matches ? 0 : 240);
      }
      L.run();
      await sleep(RM.matches ? 0 : 420);
    }
    if (id !== run) return;
    $('.term-cmd', line()).innerHTML = '<i class="term-caret"></i>';
  }
  $('#term-replay').addEventListener('click', play);

  // Start typing when the terminal comes into view, once.
  let started = false;
  const start = () => { if (!started) { started = true; play(); } };
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) { io.disconnect(); start(); } }, { threshold: 0.45 });
    io.observe($('#term'));
  } else start();

  // The quick-add shortcut. The keycaps open it; so does the real key combination.
  const keys = $('#keys');
  keys.addEventListener('click', () => QuickAdd.open(agent));
  addEventListener('keydown', e => {
    if (!(e.ctrlKey && e.altKey && e.metaKey && e.code === 'KeyN')) return;
    e.preventDefault();
    const r = $('#agent-widget').getBoundingClientRect();
    const agentInView = r.top < window.innerHeight * 0.8 && r.bottom > window.innerHeight * 0.2;
    restart(keys, 'is-down', 180);
    QuickAdd.open(agentInView ? agent : hero);
  });
})();

/* ───────────────────────── Install ─────────────────────────
   The steps are a Banger list. Tick the last one and the page throws its biggest party. */

(() => {
  const card = $('#todo'), steps = $$('.step', card), count = $('#todo-count'), ladder = $('#todo-ladder');
  let lastDone = null;
  steps.forEach(s => {
    $('.bw-box', s).innerHTML = BOX;
    $('.bw-badge', s).insertAdjacentHTML('beforeend', CHECK);
  });
  function paint() {
    const open = steps.filter(s => !s.classList.contains('is-done')), done = steps.length - open.length;
    count.textContent = done;
    freeLadder(ladder, steps.length, done);
    card.classList.toggle('is-cleared', open.length === 0);
    steps.forEach(s => {
      const isLast = open.length === 1 && s === open[0];
      s.classList.toggle('is-last', isLast);
      s.classList.toggle('has-badge', isLast || (open.length === 0 && s === lastDone));
      $('.step-box', s).setAttribute('aria-checked', s.classList.contains('is-done') ? 'true' : 'false');
    });
    return done;
  }
  steps.forEach(s => $('.step-box', s).addEventListener('click', () => {
    if (s.classList.contains('is-done')) { s.classList.remove('is-done'); paint(); return; }
    s.classList.add('is-done');
    lastDone = s;
    const done = paint(), all = done === steps.length;
    const [x, y] = centre($('.step-box', s));
    const r = card.getBoundingClientRect();
    card.style.setProperty('--ix', (x - r.left) + 'px');
    card.style.setProperty('--iy', (y - r.top) + 'px');
    card.style.setProperty('--reach', all ? 1.6 : 0.6);
    restartAll([[s, 'is-firing', 460], [card, 'is-firing', 460]]);
    celebrate(all ? 'streak' : done / steps.length > 0.6 ? 'building' : 'standard', x, y, card);
  }));
  paint();

  const btn = $('#copy'), code = $('#install-code');
  btn.addEventListener('click', async () => {
    const text = code.textContent;
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {
      try {
        const ta = document.createElement('textarea');
        ta.value = text; ta.style.cssText = 'position:fixed;opacity:0';
        document.body.appendChild(ta); ta.select();
        ok = document.execCommand('copy'); ta.remove();
      } catch (e2) { ok = false; }
    }
    btn.textContent = ok ? 'Copied' : 'Select and copy';
    btn.classList.toggle('is-done', ok);
    setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('is-done'); }, 1600);
  });
})();

/* ───────────────────────── Test hook ─────────────────────────
   index.html?still=final,450 checks off the hero list and draws one frozen frame of that
   level, 450 ms in. Used for screenshots and the link preview image. */
(() => {
  const m = /[?&]still=(standard|building|final|streak),(\d+)/.exec(location.search);
  window.__banger = { Party, Sound, hero, agent, celebrate };
  if (/[?&]og\b/.test(location.search)) document.documentElement.classList.add('is-og');
  if (!m) return;
  const go = () => requestAnimationFrame(() => {
    if (m[1] === 'streak') { streakMode = true; hero.set(HERO_TASKS, 12); }
    const open = hero.tasks.filter(t => !t.done);
    const upTo = m[1] === 'standard' ? 1 : m[1] === 'building' ? 4 : open.length;
    let last = null;
    open.slice(0, upTo).forEach(t => { t.done = true; t.at = ++hero.seq; last = t; });
    hero.render();
    document.documentElement.classList.add('is-still');
    requestAnimationFrame(() => {
      const [x, y] = centre($('.bw-box', hero.rows.get(last.id)));
      Party.still(m[1], x, y, +m[2]);
    });
  });
  (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(go);
})();

})();

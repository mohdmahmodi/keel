const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Download links point at the latest release page; swap in the disk image itself when GitHub answers.
(async () => {
  try {
    let rel = JSON.parse(sessionStorage.getItem('keel-rel') || 'null');
    if (!rel) {
      const r = await fetch('https://api.github.com/repos/mohdmahmodi/keel/releases/latest', { headers: { Accept: 'application/vnd.github+json' } });
      if (!r.ok) return;
      const j = await r.json();
      const dmg = (j.assets || []).find(a => a.name.endsWith('.dmg'));
      rel = { tag: j.tag_name, url: dmg ? dmg.browser_download_url : j.html_url, size: dmg ? dmg.size : 0 };
      sessionStorage.setItem('keel-rel', JSON.stringify(rel));
    }
    $$('[data-download]').forEach(a => { a.href = rel.url; });
    const meta = $('[data-dl-meta]');
    if (meta && rel.tag) {
      const mb = rel.size ? ` · ${Math.max(1, Math.round(rel.size / 1048576))} MB` : '';
      meta.textContent = `${rel.tag.replace(/^v/, 'Version ')}${mb} · MIT license`;
    }
  } catch { /* the release page link still works */ }
})();

// Docked call to action: visible once the hero is gone, hidden again at the final section.
{
  const dock = $('#dock-cta');
  const hero = $('.hero'), final = $('.final');
  let heroOut = false, finalIn = false;
  const update = () => dock.classList.toggle('show', heroOut && !finalIn);
  new IntersectionObserver(([e]) => { heroOut = !e.isIntersecting; update(); }, { threshold: 0.05 }).observe(hero);
  new IntersectionObserver(([e]) => { finalIn = e.isIntersecting; update(); }, { threshold: 0.2 }).observe(final);
}

// Benchmark comparison: before and after, scaled per row.
const results = [
  { name: 'Dock reveal delay', a: 500, b: 0, unit: 'ms', note: 'macOS default vs Keel', verdict: 'Instant' },
  { name: 'Window resize animation', a: 200, b: 1, unit: 'ms', note: 'macOS default vs Keel', verdict: '200× faster' },
  { name: 'DNS lookup, median', a: 35.2, b: 24.7, unit: 'ms', note: 'Measured, M4 Pro', verdict: '30% faster' },
  { name: 'Free disk space', a: 40, b: 300, unit: 'GB', note: 'After Cleanup, M4 Pro', verdict: '7× more', up: true },
];
{
  const fmt = v => (v >= 100 || Number.isInteger(v)) ? Math.round(v).toLocaleString('en-US') : v.toFixed(1);
  $('#cmp').innerHTML = results.map(r => {
    const max = Math.max(r.a, r.b) || 1;
    const w = v => Math.max(v / max * 100, v > 0 ? 1.5 : 0);
    return `<div class="cmp-row">
      <div class="cmp-label"><span class="cmp-name">${r.name}</span><span class="cmp-note">${r.note}</span></div>
      <div class="cmp-bars" aria-hidden="true">
        <div class="bar before"><i style="width:${w(r.a)}%"></i><em>${fmt(r.a)} ${r.unit}</em></div>
        <div class="bar after"><i style="width:${w(r.b)}%"></i><em>${fmt(r.b)} ${r.unit}</em></div>
      </div>
      <div class="cmp-verdict">${r.verdict}</div>
    </div>`;
  }).join('');
}

// Tweak catalog
const state = { q: '', cat: '', who: '', rec: false, gem: false, nopw: false, all: false, open: new Set() };
let tweaks = [];
const PAGE = 12;
const order = ['Performance', 'Memory', 'Storage', 'Background apps', 'Network', 'Developer', 'AI tools', 'Battery & Power', 'Privacy & Security', 'Visual responsiveness', 'Finder & desktop', 'Keyboard, trackpad & sound'];

const matches = t => {
  if (state.cat && t.cat !== state.cat) return false;
  if (state.who && !t.who.includes(state.who)) return false;
  if (state.rec && !t.rec) return false;
  if (state.gem && !t.gem) return false;
  if (state.nopw && t.admin) return false;
  if (state.q) {
    const hay = (t.name + ' ' + t.summary + ' ' + t.cat + ' ' + t.cmds.join(' ')).toLowerCase();
    return state.q.split(/\s+/).every(w => hay.includes(w));
  }
  return true;
};

const row = t => {
  const open = state.open.has(t.id);
  const flags = (t.rec ? '<span class="tag rec">REC</span>' : '') + (t.gem ? '<span class="tag gem">GEM</span>' : '');
  const meta = [
    t.admin ? ['i-lock', 'c-amber', 'Needs administrator rights'] : ['i-unlock', 'c-green', 'No password'],
    t.restarts && ['i-undo', 'c-sky', `Restarts ${t.restarts}`],
    t.manual && ['i-arrow', 'c-gray', 'Opens System Settings'],
    t.once && ['i-sparkle', 'c-orange', 'Runs once'],
  ].filter(Boolean).map(([i, c, l]) => `<li class="chip"><svg class="ic ${c}"><use href="#${i}"/></svg>${esc(l)}</li>`).join('')
    + t.who.map(w => `<li class="chip">${esc(w)}</li>`).join('');
  const cmds = t.cmds.length ? `<div class="t-cmds"><pre><code>${esc(t.cmds.join('\n'))}</code></pre></div>` : '';
  return `<div class="trow${open ? ' open' : ''}" data-id="${t.id}">
    <button type="button" aria-expanded="${open}">
      <div><div class="t-name">${esc(t.name)}${flags}</div><p class="t-sum">${esc(t.summary)}</p></div>
      <span class="t-cat">${esc(t.cat)}</span>
      <span class="t-tags"><span class="tag ${t.risk.toLowerCase()}">${t.risk}</span><span class="tag ${t.impact.toLowerCase()}">${t.impact}</span></span>
      <svg class="ic chev" aria-hidden="true"><use href="#i-chevron"/></svg>
    </button>
    <div class="t-detail"><div><div class="t-inner">
      <div><h4><span class="dot on"></span>What you'll notice</h4><p>${esc(t.benefit)}</p></div>
      <div><h4><span class="dot partly"></span>What you give up</h4><p>${esc(t.tradeoff)}</p></div>
      ${cmds}
      <ul class="chips t-meta">${meta}</ul>
    </div></div></div>
  </div>`;
};

const render = () => {
  const list = tweaks.filter(matches);
  const filtered = state.q || state.cat || state.who || state.rec || state.gem || state.nopw;
  const shown = filtered || state.all ? list : list.slice(0, PAGE);
  $('#cat-list').innerHTML = shown.length ? shown.map(row).join('') : '<p class="empty">No tweaks match. Try fewer filters.</p>';
  $('#cat-count').textContent = filtered || state.all ? `Showing ${list.length} of ${tweaks.length}` : `Showing ${Math.min(PAGE, list.length)} of ${tweaks.length}`;
  const more = $('#cat-more');
  more.hidden = filtered || state.all || list.length <= PAGE;
  more.textContent = `Show all ${tweaks.length}`;
  $$('#cats .chip-btn').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.cat === state.cat)));
  $$('.who .chip-btn').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.who === state.who)));
};

const renderCats = () => {
  const counts = Object.fromEntries(order.map(c => [c, tweaks.filter(t => t.cat === c).length]));
  $('#cats').innerHTML = `<button class="chip chip-btn" type="button" data-cat="">All<small>${tweaks.length}</small></button>` +
    order.filter(c => counts[c]).map(c => `<button class="chip chip-btn" type="button" data-cat="${esc(c)}">${esc(c)}<small>${counts[c]}</small></button>`).join('');
};

(async () => {
  try {
    const r = await fetch('tweaks.json');
    tweaks = await r.json();
  } catch {
    $('#cat-list').innerHTML = '<p class="empty">The list could not be loaded. It is also in the <a href="https://github.com/mohdmahmodi/keel/tree/main/Sources/Keel/Core/Tweaks">source on GitHub</a>.</p>';
    return;
  }
  tweaks.sort((a, b) => (b.rec - a.rec) || (b.gem - a.gem) || order.indexOf(a.cat) - order.indexOf(b.cat));
  renderCats();
  render();
  $$('[data-n-who]').forEach(el => { el.textContent = tweaks.filter(t => t.who.includes(el.dataset.nWho)).length; });
  const n = { rec: t => t.rec, gem: t => t.gem, nopw: t => !t.admin };
  $$('[data-n]').forEach(el => { el.textContent = tweaks.filter(n[el.dataset.n]).length; });
})();

let qTimer;
$('#q').addEventListener('input', e => {
  clearTimeout(qTimer);
  qTimer = setTimeout(() => { state.q = e.target.value.trim().toLowerCase(); render(); }, 90);
});
$$('.who .chip-btn').forEach(b => b.addEventListener('click', () => {
  state.who = state.who === b.dataset.who ? '' : b.dataset.who;
  render();
}));
$$('[data-flag]').forEach(b => b.addEventListener('click', () => {
  const k = b.dataset.flag;
  state[k] = !state[k];
  b.setAttribute('aria-pressed', String(state[k]));
  render();
}));
$('#cats').addEventListener('click', e => {
  const b = e.target.closest('[data-cat]');
  if (!b) return;
  state.cat = state.cat === b.dataset.cat ? '' : b.dataset.cat;
  render();
});
$('#cat-more').addEventListener('click', () => { state.all = true; render(); });
$('#cat-list').addEventListener('click', e => {
  const btn = e.target.closest('.trow > button');
  if (!btn) return;
  const rowEl = btn.parentElement, id = rowEl.dataset.id;
  const open = !rowEl.classList.contains('open');
  open ? state.open.add(id) : state.open.delete(id);
  rowEl.classList.toggle('open', open);
  btn.setAttribute('aria-expanded', String(open));
});
// The light on the step line travels from the first node to the last.
{
  const flow = $('.flow');
  const set = () => flow.style.setProperty('--travel', `${flow.clientWidth * 0.75 - 140}px`);
  new ResizeObserver(set).observe(flow);
}

// Scroll animations
window.addEventListener('load', () => {
  const { gsap, ScrollTrigger } = window;
  if (!gsap || !ScrollTrigger || reduced) return;
  gsap.registerPlugin(ScrollTrigger);

  const up = (targets, trigger, extra = {}) => gsap.from(targets, {
    y: 28, opacity: 0, duration: 0.9, ease: 'power3.out', stagger: 0.07, clearProps: 'transform,opacity',
    scrollTrigger: { trigger, start: 'top 82%' }, ...extra,
  });
  $$('.block .head').forEach(h => up(h.children, h));
  up('.stat', '.stats');
  up('.flow-step', '.flow', { stagger: 0.12 });
  up('#tweaks .split > *', '#tweaks .split');
  $$('.split-even .copy').forEach(c => up(c.children, c));
  up('.limits li', '.limits', { stagger: 0.05 });
  up('.protect', '.protect');
  up('.faq-split > *', '.faq-split');
  up('.final-copy > *', '.final-card');

  gsap.from('.shot-confirm img', { y: 60, rotateX: 14, opacity: 0, duration: 1.2, ease: 'power3.out', transformPerspective: 1200, clearProps: 'transform,opacity', scrollTrigger: { trigger: '#undo', start: 'top 75%' } });
  gsap.from('.wide-shot', { y: 70, opacity: 0, duration: 1.2, ease: 'power3.out', clearProps: 'transform,opacity', scrollTrigger: { trigger: '.wide-shot', start: 'top 88%' } });
  gsap.from('.compare', { y: 40, opacity: 0, duration: 1.1, ease: 'power3.out', clearProps: 'transform,opacity', scrollTrigger: { trigger: '.results', start: 'top 80%' } });
  gsap.from('.menubar-card', { y: 40, opacity: 0, duration: 1.1, ease: 'power3.out', clearProps: 'transform,opacity', scrollTrigger: { trigger: '#privacy', start: 'top 75%' } });
  gsap.to('.tilt', { rotateX: 14, rotateZ: -8, rotateY: 2, ease: 'none', scrollTrigger: { trigger: '.tilt-card', start: 'top bottom', end: 'bottom 30%', scrub: 0.6 } });
  gsap.to('.hero-back', { y: -60, ease: 'none', scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub: 0.5 } });
  gsap.to('.hero-front', { y: -120, ease: 'none', scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub: 0.5 } });

  $$('[data-count]').forEach(el => {
    const end = +el.dataset.count, suffix = el.dataset.suffix || '';
    const o = { v: 0 };
    gsap.to(o, { v: end, duration: 1.6, ease: 'power2.out', scrollTrigger: { trigger: el, start: 'top 90%' },
      onUpdate: () => { el.textContent = Math.round(o.v) + suffix; } });
  });

  $$('.cmp-bars i').forEach((f, i) => gsap.from(f, { scaleX: 0, transformOrigin: 'left center', duration: 1.1, delay: i * 0.05, ease: 'power3.out', clearProps: 'transform', scrollTrigger: { trigger: '#cmp', start: 'top 80%' } }));
  up('.baseline li', '.baseline', { stagger: 0.1 });
  up('.result', '.result-grid', { stagger: 0.06 });
});

// Shaders (three.js), loaded after the page so they never delay content.
const GLOW_FRAG = /* glsl */`
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform vec2 uSun; uniform float uSize;
float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p){ vec2 i = floor(p), f = fract(p); vec2 u = f*f*(3.0-2.0*f);
  return mix(mix(hash(i), hash(i+vec2(1,0)), u.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), u.x), u.y); }
float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a*noise(p); p *= 2.03; a *= 0.5; } return v; }
void main(){
  vec2 frag = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  vec2 d = (frag - uSun) / uSize;
  d.y *= 2.1;
  float r = length(d);
  float ang = atan(d.y, d.x);
  float rays = fbm(vec2(ang * 3.2, r * 1.4 - uTime * 0.05)) * 0.55 + 0.45;
  float core = exp(-r * r * 7.0);
  float mid = exp(-r * 2.1) * rays;
  float wide = exp(-r * 0.85) * 0.5;
  float shimmer = 0.92 + 0.08 * sin(uTime * 0.6 + r * 3.0);
  float above = smoothstep(0.25, -0.05, d.y);
  vec3 col = vec3(1.0, 0.9, 0.74) * core * 1.05
           + vec3(1.0, 0.5, 0.25) * mid * 0.8
           + vec3(0.45, 0.16, 0.06) * wide * 0.9;
  col *= shimmer * mix(0.35, 1.0, above);
  col += (hash(frag + uTime) - 0.5) * 0.018;
  gl_FragColor = vec4(max(col, 0.0), 1.0);
}`;

const ORB_FRAG = /* glsl */`
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform vec2 uMouse;
float hash(vec3 p){ return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p){ vec3 i = floor(p), f = fract(p); vec3 u = f*f*(3.0-2.0*f);
  return mix(mix(mix(hash(i), hash(i+vec3(1,0,0)), u.x), mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), u.x), u.y),
             mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), u.x), mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), u.x), u.y), u.z); }
float box(vec3 r, vec3 dir, float w, float h){
  vec3 d = normalize(dir); vec3 x = normalize(cross(vec3(0,1,0), d)); vec3 y = cross(d, x);
  float f = dot(r, d); if (f <= 0.0) return 0.0;
  vec2 q = vec2(dot(r, x), dot(r, y)) / f;
  return smoothstep(w, w * 0.35, abs(q.x)) * smoothstep(h, h * 0.35, abs(q.y));
}
vec3 env(vec3 r){
  // A studio: bright sky fading to a dark floor, a crisp horizon, two soft boxes.
  float sky = smoothstep(-0.02, 0.85, r.y);
  float floorGlow = smoothstep(-0.1, -0.95, r.y) * 0.3 + 0.04;
  float horizon = exp(-pow(r.y * 26.0, 2.0)) * 0.8;
  float key = box(r, vec3(-0.8, 0.45, 0.6), 0.55, 0.3) * 2.4;
  float fill = box(r, vec3(0.9, 0.1, 0.35), 0.25, 0.7) * 1.1;
  return vec3(1.0, 0.9, 0.8) * sky * 0.85 + vec3(1.0, 0.7, 0.45) * horizon + vec3(0.9, 0.5, 0.3) * floorGlow
       + vec3(1.0, 0.95, 0.88) * key + vec3(1.0, 0.62, 0.35) * fill;
}
void main(){
  vec2 uv = (gl_FragCoord.xy - 0.5 * uRes) / (0.5 * min(uRes.x, uRes.y));
  float R = 0.78;
  float r2 = dot(uv, uv), d = sqrt(r2);
  vec3 col = vec3(0.0); float alpha = 0.0;
  if (d < R) {
    vec3 n = vec3(uv, sqrt(R * R - r2)) / R;
    // Fine brushed grain that drifts slowly, so the surface reads as machined metal.
    float g = noise(vec3(n.x * 3.0, n.y * 160.0, uTime * 0.05)) - 0.5;
    n = normalize(n + vec3(0.0, g * 0.012, 0.0));
    vec3 v = vec3(0.0, 0.0, 1.0);
    vec3 r = reflect(-v, n);
    float a = uTime * 0.12 + uMouse.x * 0.6;
    r = vec3(cos(a) * r.x + sin(a) * r.z, r.y, -sin(a) * r.x + cos(a) * r.z);
    vec3 copper = vec3(0.98, 0.56, 0.3);
    float fres = pow(1.0 - max(n.z, 0.0), 4.0);
    vec3 refl = env(r);
    col = refl * mix(copper, vec3(1.0), fres * 0.6) * 0.95 + copper * 0.035;
    col += vec3(1.0, 0.5, 0.2) * fres * 0.35;
    alpha = smoothstep(R, R - 0.005, d);
  }
  float halo = exp(-max(d - R, 0.0) * 10.0) * smoothstep(R - 0.01, R + 0.004, d);
  col += vec3(1.0, 0.45, 0.15) * halo * 0.4;
  alpha = max(alpha, halo * 0.4);
  col = col / (1.0 + col * 0.45);
  col = pow(col, vec3(0.92));
  gl_FragColor = vec4(col * alpha, alpha);
}`;

const VERT = 'void main(){ gl_Position = vec4(position.xy, 0.0, 1.0); }';

const startShaders = async () => {
  let THREE;
  try { THREE = await import('https://cdn.jsdelivr.net/npm/three@0.169.0/build/three.module.min.js'); }
  catch { return; }

  const make = (canvas, frag, opts) => {
    let renderer;
    try { renderer = new THREE.WebGLRenderer({ canvas, alpha: opts.alpha, antialias: false, powerPreference: 'low-power', premultipliedAlpha: true }); }
    catch { return null; }
    renderer.setPixelRatio(Math.min(devicePixelRatio, opts.dpr));
    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    const uniforms = { uRes: { value: new THREE.Vector2() }, uTime: { value: 0 }, ...opts.uniforms };
    const mat = new THREE.ShaderMaterial({ vertexShader: VERT, fragmentShader: frag, uniforms, transparent: opts.alpha, depthTest: false });
    scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat));
    const resize = () => {
      const w = canvas.clientWidth, h = canvas.clientHeight;
      if (!w || !h) return;
      renderer.setSize(w, h, false);
      const pr = renderer.getPixelRatio();
      uniforms.uRes.value.set(w * pr, h * pr);
      opts.onResize?.(uniforms, pr);
    };
    let visible = false, raf = 0;
    const t0 = performance.now();
    const frame = () => {
      uniforms.uTime.value = (performance.now() - t0) / 1000;
      opts.onFrame?.(uniforms);
      renderer.render(scene, camera);
      if (visible && !reduced) raf = requestAnimationFrame(frame);
    };
    new ResizeObserver(() => { resize(); if (!visible || reduced) frame(); }).observe(canvas);
    new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      cancelAnimationFrame(raf);
      if (visible) frame();
    }).observe(canvas);
    resize(); frame();
    canvas.classList.add('on');
    return uniforms;
  };

  // Hero glow rises from the top edge of the main screenshot and follows it as it moves.
  const hero = $('.hero'), back = $('.hero-back');
  let pr = 1;
  make($('#glow'), GLOW_FRAG, {
    alpha: false, dpr: 1,
    uniforms: { uSun: { value: new THREE.Vector2() }, uSize: { value: 400 } },
    onResize: (u, ratio) => { pr = ratio; },
    onFrame: u => {
      const h = hero.getBoundingClientRect(), b = back.getBoundingClientRect();
      const right = Math.min(b.right, h.right);
      u.uSun.value.set(((b.left + right) / 2 - h.left) * pr, (b.top - h.top + 2) * pr);
      u.uSize.value = Math.max(240, (right - b.left) * 0.5) * pr;
    },
  });

  const mouse = { x: 0, y: 0, tx: 0 };
  addEventListener('pointermove', e => { mouse.tx = (e.clientX / innerWidth - 0.5) * 2; }, { passive: true });
  make($('#orb'), ORB_FRAG, {
    alpha: true, dpr: 1.75,
    uniforms: { uMouse: { value: new THREE.Vector2() } },
    onFrame: u => { mouse.x += (mouse.tx - mouse.x) * 0.04; u.uMouse.value.set(mouse.x, 0); },
  });
};

const idle = window.requestIdleCallback || (cb => setTimeout(cb, 300));
window.addEventListener('load', () => idle(startShaders, { timeout: 1500 }));

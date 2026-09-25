#!/usr/bin/env bash
set -uo pipefail

# Builds results/dashboard.html: every run in results/ as one browsable page.
# Data is embedded, so the file works offline and can be published as-is.
#
#   ./report.sh            → results/dashboard.html
#   ./report.sh open       → also opens it in the browser

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${DIR}/results"
OUT="${RESULTS}/dashboard.html"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# ── collect: one compact record per run ──────────────────────
: > "${TMP}/runs.jsonl"
for f in "${RESULTS}"/suite-*/runs/*.json "${RESULTS}"/*.json; do
    [[ -f "${f}" ]] || continue
    [[ "$(basename "${f}")" == "summary.json" ]] && continue
    suite="$(basename "$(dirname "$(dirname "${f}")")")"
    [[ "${suite}" == results ]] && suite="(standalone)"
    jq -c --arg suite "${suite}" --arg file "${f#${DIR}/}" '
        ([.nodes[] | select(.role == "host")]) as $h |
        ([.nodes[] | select(.role == "generator")]) as $g |
        def sum(f): map(f) | add // 0;
        def merge(sel; key): [.nodes[] | select(sel) | .[key] // {} | to_entries[]]
            | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries;
        {
          suite: $suite, file: $file, label: .label, scenario: .scenario,
          topology: "\(.topology.gens)g×\(.topology.hosts)h",
          blocks: .blocks, txs: .txs, window: .window.seconds, at: .window.to,
          images: .images, pass: .pass, checks: .checks,
          per_block: .per_block, per_tx: .per_tx, totals: .totals,
          max_lag: .max_lag_blocks, catchup: .catchup_seconds,
          miss_rate: ([$h[] | .car.miss_rate // empty] | if length == 0 then null else (add / length) end),
          car: {
            fetched: ($h | sum(.car.fetched // 0)), missed: ($h | sum(.car.missed // 0)),
            syncDAG: ($h | sum(.car.syncDAG // 0)), built: (.nodes | sum(.car.built // 0)),
            cacheHits: (.nodes | sum(.car.cacheHits // 0))
          },
          fetch_outcomes: merge(.role == "host"; "fetch_outcomes"),
          serve_outcomes: merge(.role == "generator"; "serve_outcomes"),
          stats: .stats_total,
          nodes: [.nodes[] | {
            name, role, image,
            rx, tx, cpu_sec, mem_peak, disk,
            fetched: (.car.fetched // null), missed: (.car.missed // null),
            syncDAG: (.car.syncDAG // 0), built: (.car.built // 0), cacheHits: (.car.cacheHits // 0),
            miss_rate: (.car.miss_rate // null)
          }]
        }' "${f}" >> "${TMP}/runs.jsonl" 2>/dev/null
done

count="$(wc -l < "${TMP}/runs.jsonl" | tr -d ' ')"
[[ "${count}" != "0" ]] || { echo "no run results found under ${RESULTS}"; exit 1; }

# ── page ─────────────────────────────────────────────────────
{
cat <<'HTML_HEAD'
<title>Shinzo Mesh Benchmarks</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,700&family=IBM+Plex+Mono:wght@400;500;600&family=Source+Sans+3:ital,wght@0,400;0,600;1,400&display=swap">
<style>
  :root {
    --ground: #eef1f3;
    --surface: #ffffff;
    --surface-2: #f6f8f9;
    --line: #d7dee1;
    --line-strong: #b6c2c7;
    --ink: #101a1d;
    --ink-2: #47585e;
    --ink-3: #6f8188;
    --accent: #0f766e;
    --accent-soft: #d5e9e6;
    --good: #15803d;
    --warn: #a16207;
    --bad: #b91c1c;
    --good-soft: #dcf0e2;
    --warn-soft: #f7ecd2;
    --bad-soft: #f7dcda;
    --shadow: 0 1px 2px rgba(16, 26, 29, .06), 0 8px 24px -16px rgba(16, 26, 29, .35);
    --mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
    --body: "Source Sans 3", system-ui, -apple-system, Segoe UI, sans-serif;
    --display: "Bricolage Grotesque", "Source Sans 3", system-ui, sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --ground: #0b1113;
      --surface: #121b1e;
      --surface-2: #172327;
      --line: #24343a;
      --line-strong: #35494f;
      --ink: #e8eff0;
      --ink-2: #a9bcc1;
      --ink-3: #7d9298;
      --accent: #4bb3a6;
      --accent-soft: #14312f;
      --good: #5fc27e;
      --warn: #dbab4a;
      --bad: #ef6a63;
      --good-soft: #14281c;
      --warn-soft: #2c2413;
      --bad-soft: #2e1817;
      --shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 10px 30px -18px rgba(0, 0, 0, .8);
    }
  }
  :root[data-theme="dark"] {
    --ground: #0b1113; --surface: #121b1e; --surface-2: #172327;
    --line: #24343a; --line-strong: #35494f;
    --ink: #e8eff0; --ink-2: #a9bcc1; --ink-3: #7d9298;
    --accent: #4bb3a6; --accent-soft: #14312f;
    --good: #5fc27e; --warn: #dbab4a; --bad: #ef6a63;
    --good-soft: #14281c; --warn-soft: #2c2413; --bad-soft: #2e1817;
    --shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 10px 30px -18px rgba(0, 0, 0, .8);
  }

  body { background: var(--ground); color: var(--ink); font-family: var(--body); line-height: 1.5; }
  * { box-sizing: border-box; }
  h1, h2, h3 { font-family: var(--display); font-weight: 600; margin: 0; text-wrap: balance; letter-spacing: -.01em; }
  .mono, td.num, th.num { font-family: var(--mono); font-variant-numeric: tabular-nums; }

  header.top {
    position: sticky; top: env(safe-area-inset-top, 0px); z-index: 20;
    background: color-mix(in srgb, var(--surface) 92%, transparent);
    backdrop-filter: blur(8px); border-bottom: 1px solid var(--line);
    display: flex; align-items: baseline; gap: 16px; flex-wrap: wrap;
    padding: 14px 20px;
  }
  header.top h1 { font-size: 19px; }
  header.top .sub { color: var(--ink-3); font-size: 13px; }
  header.top .spacer { flex: 1 1 auto; }

  .wrap { display: grid; grid-template-columns: minmax(260px, 340px) 1fr; gap: 0; align-items: start; }
  @media (max-width: 860px) { .wrap { grid-template-columns: 1fr; } }

  .rail { border-right: 1px solid var(--line); background: var(--surface); min-height: 60vh; padding-block: 12px; }
  @media (max-width: 860px) { .rail { border-right: 0; border-bottom: 1px solid var(--line); } }
  .rail .controls { display: flex; gap: 8px; padding: 0 16px 12px; flex-wrap: wrap; }
  .rail input[type="search"] {
    flex: 1 1 140px; min-width: 0; font: inherit; color: var(--ink);
    background: var(--surface-2); border: 1px solid var(--line); border-radius: 7px; padding: 6px 9px;
  }
  .suite-group { padding: 10px 16px 4px; }
  .suite-group h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .09em; color: var(--ink-3); font-family: var(--body); font-weight: 600; }
  .run-row {
    display: grid; grid-template-columns: auto 1fr auto; gap: 10px; align-items: center;
    width: 100%; text-align: left; border: 0; background: none; color: inherit; font: inherit;
    padding: 9px 16px; cursor: pointer; border-left: 3px solid transparent;
  }
  .run-row:hover { background: var(--surface-2); }
  .run-row[aria-current="true"] { background: var(--accent-soft); border-left-color: var(--accent); }
  .run-row .nm { font-weight: 600; font-size: 13.5px; }
  .run-row .meta { color: var(--ink-3); font-size: 12px; }
  .run-row .fig { font-family: var(--mono); font-size: 12px; color: var(--ink-2); font-variant-numeric: tabular-nums; }
  .dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
  .dot.ok { background: var(--good); } .dot.no { background: var(--bad); }
  .cmp { accent-color: var(--accent); }

  main { padding: 20px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; box-shadow: var(--shadow); }
  .card > .hd { padding: 14px 16px; border-bottom: 1px solid var(--line); display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap; }
  .card > .bd { padding: 14px 16px; overflow-x: auto; }
  .card > .hd h2 { font-size: 16px; }
  .card > .hd .note { color: var(--ink-3); font-size: 12.5px; }

  .chips { display: flex; gap: 6px; flex-wrap: wrap; }
  .chip { font-size: 11.5px; padding: 2px 8px; border-radius: 999px; border: 1px solid var(--line-strong); color: var(--ink-2); white-space: nowrap; }
  .chip.ok { background: var(--good-soft); border-color: transparent; color: var(--good); }
  .chip.no { background: var(--bad-soft); border-color: transparent; color: var(--bad); }
  .chip.warn { background: var(--warn-soft); border-color: transparent; color: var(--warn); }

  .flags { display: flex; flex-direction: column; gap: 8px; }
  .flag { display: flex; gap: 10px; padding: 10px 12px; border-radius: 8px; font-size: 13.5px; align-items: flex-start; }
  .flag.warn { background: var(--warn-soft); color: var(--warn); }
  .flag.bad { background: var(--bad-soft); color: var(--bad); }
  .flag.ok { background: var(--good-soft); color: var(--good); }
  .flag b { font-weight: 600; }

  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 1px; background: var(--line); }
  .tile { background: var(--surface); padding: 13px 14px; display: flex; flex-direction: column; gap: 3px; }
  .tile .k { font-size: 11px; text-transform: uppercase; letter-spacing: .07em; color: var(--ink-3); }
  .tile .v { font-family: var(--mono); font-size: 21px; font-weight: 500; font-variant-numeric: tabular-nums; }
  .tile .h { font-size: 11.5px; color: var(--ink-3); }

  table { border-collapse: collapse; width: 100%; font-size: 13px; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
  th { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink-3); font-weight: 600; }
  td.num, th.num { text-align: right; }
  tbody tr:last-child td { border-bottom: 0; }
  tr.gen td:first-child::before, tr.host td:first-child::before {
    content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 2px; margin-right: 7px; vertical-align: middle;
  }
  tr.gen td:first-child::before { background: var(--accent); }
  tr.host td:first-child::before { background: var(--ink-3); }

  .bar { display: flex; height: 22px; border-radius: 5px; overflow: hidden; border: 1px solid var(--line); }
  .bar span { display: block; height: 100%; }
  .legend { display: flex; flex-wrap: wrap; gap: 10px 16px; margin-top: 10px; font-size: 12.5px; color: var(--ink-2); }
  .legend i { width: 9px; height: 9px; border-radius: 2px; display: inline-block; margin-right: 6px; }

  .gate { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; font-size: 13px; }
  .gate select, .gate input { font: inherit; color: var(--ink); background: var(--surface-2); border: 1px solid var(--line); border-radius: 7px; padding: 5px 8px; }
  .verdict { font-family: var(--display); font-size: 15px; padding: 3px 12px; border-radius: 999px; }
  .verdict.ok { background: var(--good-soft); color: var(--good); }
  .verdict.no { background: var(--bad-soft); color: var(--bad); }

  .delta.better { color: var(--good); } .delta.worse { color: var(--bad); } .delta.same { color: var(--ink-3); }
  .empty { color: var(--ink-3); padding: 40px 16px; text-align: center; }
  footer { padding: 18px 20px 28px; color: var(--ink-3); font-size: 12.5px; }
  code { font-family: var(--mono); font-size: 12px; background: var(--surface-2); padding: 1px 5px; border-radius: 4px; }
  button:focus-visible, input:focus-visible, select:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
</style>

<header class="top">
  <h1>Shinzo Mesh Benchmarks</h1>
  <span class="sub" id="counts"></span>
  <span class="spacer"></span>
  <span class="sub">tick two runs to compare</span>
</header>

<div class="wrap">
  <nav class="rail" aria-label="runs">
    <div class="controls">
      <input type="search" id="q" placeholder="filter runs…" aria-label="filter runs">
      <label class="chip"><input type="checkbox" id="failsOnly" class="cmp"> failures</label>
    </div>
    <div id="index"></div>
  </nav>
  <main id="main"></main>
</div>

<footer>
  Regenerate with <code>./report.sh</code> after a run. Raw results stay in <code>results/&lt;suite&gt;/runs/*.json</code>.
</footer>

<script id="run-data" type="application/json">
HTML_HEAD

jq -s '.' "${TMP}/runs.jsonl"

cat <<'HTML_TAIL'
</script>
<script>
(function () {
  var RUNS = JSON.parse(document.getElementById('run-data').textContent);
  RUNS.sort(function (a, b) { return (b.at || '').localeCompare(a.at || ''); });

  // Metrics the page can gate on. Lower is better for every one of them, which is
  // why "better" is a straight sign test rather than a per-metric rule.
  var METRICS = [
    { id: 'mesh_bytes',   label: 'mesh bytes/block',  get: function (r) { return r.per_block && r.per_block.mesh_bytes; },    fmt: bytes, why: 'All P2P bytes every node received, per block. The egress and billing number.' },
    { id: 'miss_rate',    label: 'CAR miss rate',     get: function (r) { return r.miss_rate; },                              fmt: pct,   why: 'Heads no peer served, which fell back to a block-by-block DAG walk.' },
    { id: 'syncdag',      label: 'DAG walks/block',   get: function (r) { return perBlock(r, r.car && r.car.syncDAG); },      fmt: num2,  why: 'Fallback walks per block. Should be ~0 when the CAR exchange is healthy.' },
    { id: 'host_rx',      label: 'host rx/block',     get: function (r) { return r.per_block && r.per_block.host_rx_bytes; }, fmt: bytes, why: 'What each partner downloads per block — their ingress cost.' },
    { id: 'cpu_ms',       label: 'CPU ms/block',      get: function (r) { return r.per_block && r.per_block.cpu_ms; },        fmt: num1,  why: 'CPU across all six nodes per block.' },
    { id: 'max_lag',      label: 'max host lag',      get: function (r) { return r.max_lag; },                                fmt: num0,  why: 'Furthest the slowest host fell behind the chain head, in blocks.' },
    { id: 'catchup',      label: 'catch-up seconds',  get: function (r) { return r.catchup; },                                fmt: num0,  why: 'Seconds for every node to reach the head after load stopped.' }
  ];

  var selected = [];
  var gateId = 'mesh_bytes', gatePct = 5;

  function perBlock(r, v) { return (v == null || !r.blocks) ? null : v / r.blocks; }
  function bytes(v) {
    if (v == null) return '—';
    if (v >= 1048576) return (v / 1048576).toFixed(2) + ' MiB';
    if (v >= 1024) return (v / 1024).toFixed(1) + ' KiB';
    return Math.round(v) + ' B';
  }
  function pct(v) { return v == null ? '—' : (v * 100).toFixed(0) + '%'; }
  function num0(v) { return v == null ? '—' : Math.round(v).toString(); }
  function num1(v) { return v == null ? '—' : (Math.round(v * 10) / 10).toString(); }
  function num2(v) { return v == null ? '—' : (Math.round(v * 100) / 100).toString(); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // What looks off — so the numbers that need attention find the reader.
  function flags(r) {
    var out = [];
    var failed = Object.keys(r.checks || {}).filter(function (k) { return r.checks[k] === false; });
    if (failed.length) out.push({ kind: 'bad', t: 'Failed checks', d: failed.join(', ') });
    if (r.checks && r.checks.car_invariants === false) out.push({ kind: 'bad', t: 'Counter invariants broken', d: 'CAR totals do not reconcile — treat these figures as indicative only.' });
    if (r.checks && r.checks.parity === false) out.push({ kind: 'bad', t: 'Document parity failed', d: 'Nodes hold different documents; something was lost.' });
    if (r.miss_rate != null && r.miss_rate > 0.05) out.push({ kind: 'warn', t: pct(r.miss_rate) + ' of heads fell back to DAG walks', d: 'The CAR exchange is not serving most heads.' });
    if (r.max_lag > 10) out.push({ kind: 'warn', t: 'Lag reached ' + r.max_lag + ' blocks', d: 'Nodes struggled to keep up — check CPU and memory before trusting timings.' });
    var top = topOutcome(r.fetch_outcomes);
    if (top && /QueueFull|ResourceLimited|RequestFailed|Timeout|Backoff/.test(top[0])) {
      out.push({ kind: 'warn', t: 'Dominant CAR outcome is ' + top[0], d: top[1] + ' occurrences — this is where heads are being lost.' });
    }
    if (!out.length) out.push({ kind: 'ok', t: 'Nothing anomalous', d: 'All checks passed and no outcome pattern stands out.' });
    return out;
  }
  function topOutcome(o) {
    var e = Object.entries(o || {}).filter(function (x) { return !/Fetched$/.test(x[0]); });
    e.sort(function (a, b) { return b[1] - a[1]; });
    return e[0];
  }

  function outcomeColor(k) {
    if (/Fetched$/.test(k)) return 'var(--good)';
    if (/NotServed|notHeld/.test(k)) return 'var(--ink-3)';
    if (/QueueFull|ResourceLimited/.test(k)) return 'var(--bad)';
    if (/Backoff/.test(k)) return 'var(--warn)';
    return 'var(--accent)';
  }

  function renderIndex() {
    var q = document.getElementById('q').value.toLowerCase();
    var failsOnly = document.getElementById('failsOnly').checked;
    var host = document.getElementById('index');
    host.textContent = '';
    var shown = 0, suite = null;
    RUNS.forEach(function (r, i) {
      var hay = (r.suite + ' ' + r.label + ' ' + r.scenario + ' ' + r.topology).toLowerCase();
      if (q && hay.indexOf(q) === -1) return;
      if (failsOnly && r.pass) return;
      if (r.suite !== suite) { suite = r.suite; var g = el('div', 'suite-group'); g.appendChild(el('h2', null, suite)); host.appendChild(g); }
      var row = el('button', 'run-row');
      row.type = 'button';
      row.setAttribute('aria-current', selected.indexOf(i) === 0 ? 'true' : 'false');
      var box = document.createElement('input');
      box.type = 'checkbox'; box.className = 'cmp'; box.checked = selected.indexOf(i) !== -1;
      box.setAttribute('aria-label', 'compare ' + r.label);
      box.addEventListener('click', function (ev) {
        ev.stopPropagation();
        var at = selected.indexOf(i);
        if (at !== -1) selected.splice(at, 1);
        else { selected.push(i); if (selected.length > 2) selected.shift(); }
        render();
      });
      var mid = el('div');
      mid.appendChild(el('div', 'nm', r.label));
      mid.appendChild(el('div', 'meta', r.topology + ' · ' + r.scenario + ' · ' + r.blocks + ' blocks'));
      var right = el('div');
      right.style.textAlign = 'right';
      right.appendChild(el('div', 'fig', bytes(r.per_block && r.per_block.mesh_bytes) + '/blk'));
      var d = el('div');
      d.appendChild(el('span', 'dot ' + (r.pass ? 'ok' : 'no')));
      d.appendChild(el('span', 'fig', ' ' + (r.miss_rate == null ? '' : pct(r.miss_rate) + ' miss')));
      right.appendChild(d);
      row.appendChild(box); row.appendChild(mid); row.appendChild(right);
      row.addEventListener('click', function () { selected = [i]; render(); });
      host.appendChild(row);
      shown++;
    });
    if (!shown) host.appendChild(el('div', 'empty', 'No runs match.'));
    document.getElementById('counts').textContent = RUNS.length + ' runs · ' + shown + ' shown';
  }

  function card(title, note) {
    var c = el('section', 'card'), hd = el('div', 'hd');
    hd.appendChild(el('h2', null, title));
    if (note) hd.appendChild(el('span', 'note', note));
    c.appendChild(hd);
    var bd = el('div', 'bd');
    c.appendChild(bd);
    c._bd = bd;
    return c;
  }

  function renderDetail(r) {
    var main = document.getElementById('main');
    var head = card(r.label, r.suite + ' · ' + r.topology + ' · ' + r.scenario + ' · ' + r.window + 's window · ' + (r.at || '').replace('T', ' ').replace('Z', ''));
    var chips = el('div', 'chips');
    chips.appendChild(el('span', 'chip ' + (r.pass ? 'ok' : 'no'), r.pass ? 'PASS' : 'FAIL'));
    Object.keys(r.checks || {}).forEach(function (k) {
      var v = r.checks[k];
      chips.appendChild(el('span', 'chip ' + (v === false ? 'no' : v === null ? 'warn' : 'ok'), k + '=' + v));
    });
    head._bd.appendChild(chips);
    var imgs = el('div', 'meta');
    imgs.style.cssText = 'margin-top:10px;color:var(--ink-3);font-size:12.5px';
    imgs.textContent = 'images: ' + Array.from(new Set(Object.values(r.images || {}))).join(', ');
    head._bd.appendChild(imgs);
    main.appendChild(head);

    var fl = card('What stands out');
    var list = el('div', 'flags');
    flags(r).forEach(function (f) {
      var d = el('div', 'flag ' + f.kind);
      var b = el('div');
      b.appendChild(el('b', null, f.t));
      b.appendChild(el('div', null, f.d));
      d.appendChild(b);
      list.appendChild(d);
    });
    fl._bd.appendChild(list);
    main.appendChild(fl);

    var tilesCard = card('Headline metrics', 'lower is better for all of these');
    tilesCard._bd.style.padding = '0';
    var tiles = el('div', 'tiles');
    METRICS.forEach(function (m) {
      var t = el('div', 'tile');
      t.appendChild(el('div', 'k', m.label));
      t.appendChild(el('div', 'v', m.fmt(m.get(r))));
      t.appendChild(el('div', 'h', m.why));
      tiles.appendChild(t);
    });
    tilesCard._bd.appendChild(tiles);
    main.appendChild(tilesCard);

    var oc = card('CAR fetch outcomes', 'every head a host needed, by what happened to it');
    var entries = Object.entries(r.fetch_outcomes || {}).sort(function (a, b) { return b[1] - a[1]; });
    if (!entries.length) oc._bd.appendChild(el('div', 'empty', 'No CAR outcome counters — this image predates them.'));
    else {
      var total = entries.reduce(function (s, e) { return s + e[1]; }, 0);
      var bar = el('div', 'bar');
      entries.forEach(function (e) {
        var s = el('span');
        s.style.width = (e[1] / total * 100) + '%';
        s.style.background = outcomeColor(e[0]);
        s.title = e[0] + ' = ' + e[1];
        bar.appendChild(s);
      });
      oc._bd.appendChild(bar);
      var lg = el('div', 'legend');
      entries.forEach(function (e) {
        var s = el('span');
        var i = el('i');
        i.style.background = outcomeColor(e[0]);
        s.appendChild(i);
        s.appendChild(document.createTextNode(e[0] + ' ' + e[1]));
        lg.appendChild(s);
      });
      oc._bd.appendChild(lg);
    }
    main.appendChild(oc);

    var nt = card('Per node');
    var tb = el('table');
    tb.innerHTML = '<thead><tr><th>node</th><th class="num">p2p rx</th><th class="num">p2p tx</th><th class="num">cpu s</th><th class="num">mem peak</th><th class="num">fetched</th><th class="num">missed</th><th class="num">DAG</th><th class="num">built</th><th class="num">cache hits</th></tr></thead>';
    var body = el('tbody');
    (r.nodes || []).forEach(function (n) {
      var tr = el('tr', n.role === 'generator' ? 'gen' : 'host');
      [[n.name], [bytes(n.rx), 1], [bytes(n.tx), 1], [num1(n.cpu_sec), 1], [bytes(n.mem_peak), 1],
       [n.fetched == null ? '—' : n.fetched, 1], [n.missed == null ? '—' : n.missed, 1],
       [n.syncDAG, 1], [n.built, 1], [n.cacheHits, 1]].forEach(function (c) {
        var td = el('td', c[1] ? 'num mono' : null, String(c[0]));
        tr.appendChild(td);
      });
      body.appendChild(tr);
    });
    tb.appendChild(body);
    nt._bd.appendChild(tb);
    main.appendChild(nt);
  }

  function renderCompare(a, b) {
    var main = document.getElementById('main');
    var c = card('Comparison', a.label + '  →  ' + b.label);
    var gate = el('div', 'gate');
    gate.appendChild(el('span', null, 'Pass/fail decided by'));
    var sel = document.createElement('select');
    sel.id = 'gateSel';
    METRICS.forEach(function (m) {
      var o = document.createElement('option');
      o.value = m.id; o.textContent = m.label; o.selected = m.id === gateId;
      sel.appendChild(o);
    });
    sel.addEventListener('change', function () { gateId = sel.value; render(); });
    gate.appendChild(sel);
    gate.appendChild(el('span', null, 'improving by at least'));
    var inp = document.createElement('input');
    inp.type = 'number'; inp.min = '0'; inp.max = '99'; inp.value = String(gatePct); inp.id = 'gatePct';
    inp.style.width = '68px';
    inp.addEventListener('change', function () { gatePct = Number(inp.value) || 0; render(); });
    gate.appendChild(inp);
    gate.appendChild(el('span', null, '%'));

    var m = METRICS.filter(function (x) { return x.id === gateId; })[0];
    var av = m.get(a), bv = m.get(b);
    var ok = av != null && bv != null && bv < av * (1 - gatePct / 100) && b.pass;
    var v = el('span', 'verdict ' + (ok ? 'ok' : 'no'), ok ? 'PASS' : 'FAIL');
    gate.appendChild(v);
    c._bd.appendChild(gate);
    var why = el('div', 'note');
    why.style.cssText = 'margin-top:8px;color:var(--ink-3);font-size:12.5px';
    why.textContent = m.why + (b.pass ? '' : '  Candidate also failed its correctness checks.');
    c._bd.appendChild(why);

    var tb = el('table');
    tb.style.marginTop = '14px';
    tb.innerHTML = '<thead><tr><th>metric</th><th class="num">' + a.label + '</th><th class="num">' + b.label + '</th><th class="num">delta</th><th>verdict</th></tr></thead>';
    var body = el('tbody');
    METRICS.forEach(function (x) {
      var p = x.get(a), q = x.get(b), tr = el('tr');
      var d = '—', verdict = 'n/a', cls = 'same';
      if (p != null && q != null && p !== 0) {
        var pctd = (q - p) / p * 100;
        d = (pctd > 0 ? '+' : '') + pctd.toFixed(1) + '%';
        if (Math.abs(pctd) < 5) { verdict = 'same'; cls = 'same'; }
        else if (pctd < 0) { verdict = 'better'; cls = 'better'; }
        else { verdict = 'worse'; cls = 'worse'; }
      }
      tr.appendChild(el('td', x.id === gateId ? 'mono' : null, x.label + (x.id === gateId ? '  ← gate' : '')));
      tr.appendChild(el('td', 'num mono', x.fmt(p)));
      tr.appendChild(el('td', 'num mono', x.fmt(q)));
      tr.appendChild(el('td', 'num mono delta ' + cls, d));
      tr.appendChild(el('td', 'delta ' + cls, verdict));
      body.appendChild(tr);
    });
    tb.appendChild(body);
    c._bd.appendChild(tb);
    main.appendChild(c);

    [a, b].forEach(function (r) {
      var f = card('What stands out — ' + r.label);
      var list = el('div', 'flags');
      flags(r).forEach(function (x) {
        var d = el('div', 'flag ' + x.kind);
        var bb = el('div');
        bb.appendChild(el('b', null, x.t));
        bb.appendChild(el('div', null, x.d));
        d.appendChild(bb);
        list.appendChild(d);
      });
      f._bd.appendChild(list);
      main.appendChild(f);
    });
  }

  function render() {
    renderIndex();
    var main = document.getElementById('main');
    main.textContent = '';
    if (selected.length === 2) renderCompare(RUNS[selected[0]], RUNS[selected[1]]);
    else if (selected.length === 1) renderDetail(RUNS[selected[0]]);
    else main.appendChild(el('div', 'empty', 'Pick a run on the left. Tick two to compare them.'));
  }

  document.getElementById('q').addEventListener('input', renderIndex);
  document.getElementById('failsOnly').addEventListener('change', render);
  if (RUNS.length) selected = [0];
  render();
})();
</script>
HTML_TAIL
} > "${OUT}"

echo "wrote ${OUT} (${count} runs)"
[[ "${1:-}" == open ]] && open "${OUT}"
exit 0

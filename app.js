// app.js — static Plotly.js dashboard for the Newtrinos.jl global-fit results
// Loads data/results.json (see export_results.jl) and wires up the same controls:
// parameter x/y, dataset toggles, NO/IO toggles, CL slider + "show all", best-fit markers,
// 1D/2D profile switching, and PDF/CSV/JSON export.

// Keyed by the longest matching prefix actually used — both the dataset/results.json name
// (e.g. "IceCube Deepcore") and the residuals series label prefix (e.g. "DeepCore (...)",
// "ORCA (...)") need their own entry, since those two naming schemes don't always agree.
const COLORS = {
  "Daya Bay": "#2f5fd0",
  "MINOS": "#d08a2f",
  "KamLAND": "#1f8a4c",
  "IceCube Deepcore": "#c9a227",
  "DeepCore": "#c9a227",
  "KM3NeT/ORCA": "#6a3fb5",
  "ORCA": "#6a3fb5",
  "Super-K": "#1f9e8f",
  "JUNO": "#c4588e",
  "TAO": "#8a5a2f",
  "Combined": "#c0392b",
};
const DEFAULT_COLOR = "#7a8494";

// Resolves relative to the page's own location by default; category pages set
// PAGE_DATA_BASE (e.g. "../../") since they live two directories below the repo root.
const DATA_BASE = typeof PAGE_DATA_BASE !== "undefined" ? PAGE_DATA_BASE : "./";

// Minimal reader for experiments.toml's flat [[experiment]] array-of-tables shape — not a
// general TOML parser, just enough for `key = "value"` lines grouped under [[experiment]].
function parseExperimentsToml(text) {
  const entries = [];
  let current = null;
  for (const rawLine of text.split("\n")) {
    const line = rawLine.split("#")[0].trim();
    if (!line) continue;
    if (line === "[[experiment]]") {
      current = {};
      entries.push(current);
      continue;
    }
    const m = line.match(/^(\w+)\s*=\s*"(.*)"$/);
    if (m && current) current[m[1]] = m[2];
  }
  return entries;
}

let EXPERIMENTS_CONFIG = [];
let DATA = null;
const state = {
  px: null,
  py: "None",
  clIndex: 0,
  showAllCL: false,
  showBestfit: true,
  showNO: true,
  showIO: true,
  datasets: {}, // name -> bool
};

async function main() {
  const [resultsRes, tomlRes] = await Promise.all([
    fetch(`${DATA_BASE}data/results.json`),
    fetch(`${DATA_BASE}experiments.toml`),
  ]);
  DATA = await resultsRes.json();
  EXPERIMENTS_CONFIG = parseExperimentsToml(await tomlRes.text());

  // Category pages (PAGE_CATEGORY set before this script loads) only ever show the
  // experiments in that category, plus that category's own joint fit ("Combined
  // (reactor)", etc. — computed by compute_results.jl alongside the site-wide
  // "Combined"). The combined dashboard (no PAGE_CATEGORY) shows every individual
  // experiment plus the complete all-experiments "Combined" fit — but not the
  // per-category joint fits ("Combined (reactor)" etc.), since those each have their own
  // dedicated page now and would just be redundant here.
  if (typeof PAGE_CATEGORY !== "undefined") {
    const allowed = new Set(EXPERIMENTS_CONFIG.filter((e) => e.category === PAGE_CATEGORY).map((e) => e.name));
    allowed.add(`Combined (${PAGE_CATEGORY})`);
    DATA.experiments = DATA.experiments.filter((name) => allowed.has(name));
  } else {
    DATA.experiments = DATA.experiments.filter((name) => !/^Combined \(/.test(name));
  }

  // Any "Combined"/"Combined (<category>)" entry first, then the individual experiments
  // in whatever order they were given.
  const isCombined = (name) => name === "Combined" || name.startsWith("Combined (");
  DATA.experiments.sort((a, b) => (isCombined(a) ? -1 : isCombined(b) ? 1 : 0));

  state.px = DATA.scan_params[0];
  // Show only the combined fit by default; individual experiments are opt-in.
  const hasCombined = DATA.experiments.some(isCombined);
  for (const name of DATA.experiments) state.datasets[name] = hasCombined ? isCombined(name) : true;

  buildControls();
  render();
  loadSourceFiles();
  document.getElementById("source-note").remove();
  loadResiduals();
}

let RESIDUALS = null;

async function loadResiduals() {
  try {
    const res = await fetch(`${DATA_BASE}data/residuals.json`);
    if (!res.ok) return; // no residuals.json yet — section stays hidden
    RESIDUALS = await res.json();
    document.getElementById("residuals-section").hidden = false;
    renderResiduals();
  } catch (err) {
    console.warn("No residuals data available:", err.message);
  }
}

// Color for any experiment/dataset name, matched by prefix so "Combined (reactor)" etc.
// resolve to the same color as "Combined", and residual series like "MINOS (CC)" resolve
// to MINOS's color.
function experimentColor(label) {
  const known = Object.keys(COLORS).find((name) => label.startsWith(name));
  return known ? COLORS[known] : DEFAULT_COLOR;
}
const residualColor = experimentColor;

// Marker shape per sub-channel, so e.g. MINOS (CC) vs MINOS (NC) or DeepCore (Cascades) vs
// (Tracks) stay distinguishable even though they share one color. Falls back to a circle
// for single-channel experiments (Daya Bay, KamLAND) and anything not listed here.
const CHANNEL_SYMBOLS = {
  "CC": "circle",
  "NC": "diamond",
  "Cascades": "circle",
  "Tracks": "diamond",
  "high-purity tracks": "diamond",
  "low-purity tracks": "triangle-up",
  "showers": "circle",
};
// Plotly's triangle glyphs read visually smaller than circles/diamonds at the same nominal
// marker size, so triangle-using symbols get a size bump to look consistent with the rest.
const SYMBOL_SIZE_BOOST = { "triangle-up": 1.4, "triangle-down": 1.4, "triangle-left": 1.4, "triangle-right": 1.4 };
function residualMarkerSize(symbol, base = 7) {
  return base * (SYMBOL_SIZE_BOOST[symbol] || 1);
}

function residualSymbol(label) {
  const m = label.match(/\(([^)]+)\)\s*$/);
  if (!m) return "circle";
  return CHANNEL_SYMBOLS[m[1]] || "pentagon";
}

// Pick the residuals entry matching the currently-selected scan (same px/py/ordering
// logic as the scan plot above) AND the combined set this page is scoped to ("Combined"
// on the unrestricted dashboard, "Combined (<category>)" on a category page) — so the
// pull plot always shows residuals at THAT scan's own best-fit point, for the same
// experiments this page's scan/table are already showing. With both NO and IO checked,
// NO is shown (both can't fit on one plot at once); the note below the heading says which
// ordering is in use.
function currentResidualsSetName() {
  return typeof PAGE_CATEGORY !== "undefined" ? `Combined (${PAGE_CATEGORY})` : "Combined";
}

function currentResidualsEntry() {
  if (!RESIDUALS) return null;
  const ordering = state.showNO ? "NO" : state.showIO ? "IO" : null;
  if (!ordering) return null;
  const setName = currentResidualsSetName();

  if (isOneD()) {
    return { entry: RESIDUALS.entries[`${setName}:1d:${state.px}:${ordering}`], ordering };
  }
  const py = state.py;
  const direct = RESIDUALS.entries[`${setName}:2d:${state.px}|${py}:${ordering}`];
  const swapped = RESIDUALS.entries[`${setName}:2d:${py}|${state.px}:${ordering}`];
  return { entry: direct || swapped, ordering };
}

function renderResiduals() {
  const picked = currentResidualsEntry();
  const noteEl = document.getElementById("residuals-note");
  const plotEl = document.getElementById("residuals-plot");

  if (!picked || !picked.entry) {
    noteEl.textContent = "No precomputed residuals for this parameter selection yet.";
    Plotly.purge(plotEl);
    return;
  }

  const { entry, ordering } = picked;
  noteEl.textContent = `${RESIDUALS.note || ""} Showing residuals at the ${ordering} best-fit for the current parameter selection.`;

  const traces = [];
  const shapes = [];
  let cursor = 0; // running bin-index offset so every series gets its own x-slot

  // No client-side filtering needed: each entry's series are already scoped to exactly the
  // experiments in this page's combined set (see export_residuals.jl's per-set computation).
  for (const series of entry.series) {
    const color = residualColor(series.label);
    const symbol = residualSymbol(series.label);
    const n = series.observed.length;
    const xs = series.observed.map((_, i) => cursor + i);

    // Shaded ±1σ band (in pull units, a band is exactly [-1, 1]) across this series'
    // x-range, so each experiment/channel is visually distinguishable even though the
    // band height is the same for all of them.
    shapes.push({
      type: "rect", xref: "x", yref: "y",
      x0: cursor - 0.5, x1: cursor + n - 0.5, y0: -1, y1: 1,
      fillcolor: color, opacity: 0.12, line: { width: 0 },
    });

    const pulls = series.observed.map((obs, i) => (obs - series.predicted[i]) / series.sigma[i]);
    traces.push({
      x: xs, y: pulls, mode: "markers", name: series.label,
      marker: { color, symbol, size: residualMarkerSize(symbol) },
      hovertext: series.x.map((x, i) => {
        // A non-empty bin_desc (e.g. DeepCore's flattened (energy, cosθ) bins) is a more
        // meaningful label than a single-axis bin range; prefer it when present.
        const hasDesc = series.bin_desc && series.bin_desc[i];
        const range = hasDesc
          ? series.bin_desc[i]
          : (series.bin_lo && series.bin_hi)
            ? `${series.bin_lo[i]}–${series.bin_hi[i]} ${series.axis_label || ""}`
            : `center: ${x}`;
        return (
          `${series.label}<br>` +
          `bin ${i + 1} of ${n} (${range})<br>` +
          `observed: ${series.observed[i]}, predicted: ${series.predicted[i].toFixed(2)} ± ${series.sigma[i].toFixed(2)}<br>` +
          `pull: ${pulls[i].toFixed(2)}`
        );
      }),
      hoverinfo: "text",
    });

    cursor += n;
  }

  // Flat zero reference line (the best-fit prediction, by construction, in pull units).
  traces.push({
    x: [-0.5, cursor - 0.5], y: [0, 0], mode: "lines",
    line: { color: "#000", width: 1 }, showlegend: false, hoverinfo: "skip",
  });

  const layout = {
    margin: { l: 60, r: 20, t: 20, b: 50 },
    xaxis: {
      title: { text: "data point (grouped by experiment / channel)" },
      color: "#000", gridcolor: "#e5e7eb", zerolinecolor: "#000",
      showline: true, linecolor: "#000", linewidth: 1, mirror: true,
      ticks: "outside", tickcolor: "#000", showticklabels: false,
    },
    yaxis: {
      title: { text: "pull = (data − prediction) / σ" },
      color: "#000", gridcolor: "#e5e7eb", zerolinecolor: "#000",
      showline: true, linecolor: "#000", linewidth: 1, mirror: true,
      ticks: "outside", tickcolor: "#000",
    },
    shapes,
    paper_bgcolor: "#ffffff",
    plot_bgcolor: "#ffffff",
    font: { color: "#000", family: "Public Sans, system-ui, sans-serif", size: 13 },
    legend: { orientation: "v", bgcolor: "#ffffff", bordercolor: "#000", borderwidth: 1 },
    autosize: true,
  };

  Plotly.react("residuals-plot", traces, layout, { responsive: true, displaylogo: false });
}

async function loadSourceFiles() {
  const files = [
    { url: `${DATA_BASE}compute_results.jl`, elId: "code-compute" },
    { url: `${DATA_BASE}export_results.jl`, elId: "code-export" },
    { url: `${DATA_BASE}export_residuals.jl`, elId: "code-residuals" },
  ];
  for (const { url, elId } of files) {
    const el = document.getElementById(elId);
    try {
      const res = await fetch(url);
      el.textContent = await res.text();
      if (window.hljs) hljs.highlightElement(el);
    } catch (err) {
      el.textContent = `// failed to load ${url}: ${err.message}`;
    }
  }
  for (const btn of document.querySelectorAll(".copy")) {
    btn.addEventListener("click", () => {
      const code = document.getElementById(btn.dataset.copy).textContent;
      navigator.clipboard.writeText(code).then(() => {
        const original = btn.textContent;
        btn.textContent = "Copied!";
        setTimeout(() => (btn.textContent = original), 1500);
      });
    });
  }
}

function buildControls() {
  const paramX = document.getElementById("param-x");
  const paramY = document.getElementById("param-y");
  for (const p of DATA.scan_params) {
    paramX.appendChild(new Option(p, p));
    paramY.appendChild(new Option(p, p));
  }
  paramY.insertBefore(new Option("None", "None"), paramY.firstChild);
  paramX.value = state.px;
  paramY.value = state.py;

  paramX.addEventListener("change", () => { state.px = paramX.value; render(); });
  paramY.addEventListener("change", () => { state.py = paramY.value; render(); });

  const dsContainer = document.getElementById("dataset-checkboxes");
  for (const name of DATA.experiments) {
    const row = document.createElement("div");
    row.className = "checkbox-row";
    const id = "ds-" + name.replace(/\s+/g, "-");
    const checkedAttr = state.datasets[name] ? "checked" : "";
    row.innerHTML = `<input type="checkbox" id="${id}" ${checkedAttr}><label for="${id}">${name}</label>`;
    dsContainer.appendChild(row);
    row.querySelector("input").addEventListener("change", (e) => {
      state.datasets[name] = e.target.checked;
      render();
    });
  }

  const clSlider = document.getElementById("cl-slider");
  clSlider.max = DATA.cl_labels.length - 1;
  clSlider.addEventListener("input", () => {
    state.clIndex = +clSlider.value;
    updateCLLabel();
    render();
  });
  updateCLLabel();

  document.getElementById("cl-show-all").addEventListener("change", (e) => {
    state.showAllCL = e.target.checked;
    clSlider.disabled = state.showAllCL;
    render();
  });

  document.getElementById("show-bestfit").addEventListener("change", (e) => {
    state.showBestfit = e.target.checked;
    render();
  });
  document.getElementById("ord-no").addEventListener("change", (e) => {
    state.showNO = e.target.checked;
    render();
  });
  document.getElementById("ord-io").addEventListener("change", (e) => {
    state.showIO = e.target.checked;
    render();
  });

  document.getElementById("download-pdf").addEventListener("click", downloadPlotPDF);
  document.getElementById("download-csv").addEventListener("click", downloadCSV);
  document.getElementById("download-json").addEventListener("click", downloadJSON);
}

function updateCLLabel() {
  document.getElementById("cl-value").textContent = DATA.cl_labels[state.clIndex];
}

function isOneD() {
  return state.py === "None" || state.py === state.px;
}

function paramYLookup() {
  if (!isOneD()) return state.py;
  return DATA.scan_params.find((p) => p !== state.px);
}

function get2DGrid(results2d, a, b) {
  if (results2d[`${a}|${b}`]) {
    const r = results2d[`${a}|${b}`];
    return { x: r.x, y: r.y, z: r.dchi2 }; // z[iy][ix]
  }
  if (results2d[`${b}|${a}`]) {
    // Stored under the swapped key "b|a": r.x holds b-values, r.y holds a-values, and
    // r.dchi2[iy][ix] is the value at (b = r.x[ix], a = r.y[iy]). We want x = a-axis,
    // y = b-axis, i.e. zOut[iy'][ix'] = value at (a = r.y[ix'], b = r.x[iy']) = r.dchi2[ix'][iy']
    // — a transpose of r.dchi2.
    const r = results2d[`${b}|${a}`];
    const zOut = r.y.map((_, iy2) => r.x.map((_, ix2) => r.dchi2[ix2][iy2]));
    return { x: r.y, y: r.x, z: zOut };
  }
  return null;
}

function argmin(arr) {
  let best = 0;
  for (let i = 1; i < arr.length; i++) if (arr[i] < arr[best]) best = i;
  return best;
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function render() {
  renderPlot();
  renderSummaryTable();
  if (RESIDUALS) renderResiduals();
}

// All CL labels joined like "1σ, 90%, 2σ, 99%, 3σ" for the combined "show all" case.
function allCLLabel() {
  return DATA.cl_labels.join(", ") + " CL";
}

function renderPlot() {
  const traces = [];
  const annotations = [];
  const px = state.px;
  const oneD = isOneD();
  const py = paramYLookup();
  const clIndices1d = state.showAllCL ? DATA.cl_levels_1d.map((_, i) => i) : [state.clIndex];
  const clLevels1d = clIndices1d.map((i) => DATA.cl_levels_1d[i]);
  const clIndices2d = state.showAllCL ? DATA.cl_levels_2d.map((_, i) => i) : [state.clIndex];
  const clLevels2d = clIndices2d.map((i) => DATA.cl_levels_2d[i]);
  // Legend suffix naming which CL level(s) are plotted, e.g. "90%" or the combined
  // "1σ, 90%, 2σ, 99%, 3σ CL" when "show all" is checked.
  const clSuffix = state.showAllCL ? allCLLabel() : `${DATA.cl_labels[state.clIndex]} CL`;

  if (oneD) {
    // x-extent of the actual scan range (not an arbitrary large number) so autoscaling
    // doesn't stretch the axis out to a line that looks vertical by comparison.
    const anyEntry = DATA.experiments.map((n) => DATA.results[n].NO.results_1d[px]).find(Boolean);
    const xExtent = anyEntry ? [anyEntry.x[0], anyEntry.x[anyEntry.x.length - 1]] : [0, 1];
    clIndices1d.forEach((clIdx, i) => {
      const level = clLevels1d[i];
      traces.push({
        x: xExtent, y: [level, level], mode: "lines",
        line: { color: cssVar("--muted"), dash: "dot", width: 1 },
        hoverinfo: "skip", showlegend: false,
      });
      // With a single CL level shown, label it directly above the line. With "show all",
      // that would be five overlapping labels — state them once in the legend instead
      // (see the dedicated CL-levels legend trace below).
      if (!state.showAllCL) {
        annotations.push({
          x: xExtent[1], y: level, xref: "x", yref: "y",
          text: DATA.cl_labels[clIdx], showarrow: false,
          xanchor: "right", yanchor: "bottom", yshift: 2,
          font: { size: 11, color: "#5d6676" },
        });
      }
    });
  }

  for (const name of DATA.experiments) {
    if (!state.datasets[name]) continue;
    const color = experimentColor(name);
    for (const [ordering, dash, enabled] of [["NO", "solid", state.showNO], ["IO", "dash", state.showIO]]) {
      if (!enabled) continue;
      const expData = DATA.results[name][ordering];
      if (!expData) continue; // not every experiment has both orderings (e.g. DeepCore has no IO yet)

      if (oneD) {
        const d = expData.results_1d[px];
        if (!d) continue;
        traces.push({
          x: d.x, y: d.dchi2, mode: "lines", name: `${name} (${ordering})`,
          line: { color, dash, width: 2 },
        });
        if (state.showBestfit) {
          const i = argmin(d.dchi2);
          traces.push({
            x: [d.x[i]], y: [d.dchi2[i]], mode: "markers", showlegend: false,
            marker: { symbol: ordering === "NO" ? "star" : "star-triangle-up", size: 13, color, line: { color: "#000", width: 1 } },
            hoverinfo: "skip",
          });
        }
      } else {
        const grid = get2DGrid(expData.results_2d, px, py);
        if (!grid) continue;
        // Plotly's contour trace only takes a single (start, end, size) step, so draw
        // one contour trace per requested CL level to get crisp lines at exactly those levels.
        for (const level of clLevels2d) {
          traces.push({
            x: grid.x, y: grid.y, z: grid.z, type: "contour",
            contours: { coloring: "none", showlabels: false, start: level, end: level, size: 1 },
            line: { color, dash, width: 2 },
            showscale: false,
            name: `${name} (${ordering})`,
            showlegend: level === clLevels2d[0],
            hoverinfo: "skip",
          });
        }
        if (state.showBestfit) {
          const flat = grid.z.flat();
          const minVal = Math.min(...flat);
          let iy0 = 0, ix0 = 0;
          outer:
          for (let iy = 0; iy < grid.z.length; iy++) {
            for (let ix = 0; ix < grid.z[iy].length; ix++) {
              if (grid.z[iy][ix] === minVal) { iy0 = iy; ix0 = ix; break outer; }
            }
          }
          traces.push({
            x: [grid.x[ix0]], y: [grid.y[iy0]], mode: "markers", showlegend: false,
            marker: { symbol: ordering === "NO" ? "star" : "star-triangle-up", size: 13, color, line: { color: "#000", width: 1 } },
            hoverinfo: "skip",
          });
        }
      }
    }
  }

  // One combined legend entry naming the CL level(s) in play, listed last (after every
  // dataset) rather than repeated per dataset or per line.
  if (oneD) {
    if (state.showAllCL) {
      traces.push({
        x: [null], y: [null], mode: "lines",
        line: { color: cssVar("--muted"), dash: "dot", width: 1 },
        name: allCLLabel(), showlegend: true, hoverinfo: "skip",
      });
    }
  } else {
    traces.push({
      x: [null], y: [null], mode: "lines",
      line: { color: "#000", width: 2 },
      name: clSuffix, showlegend: true, hoverinfo: "skip",
    });
  }

  // Publication-style canvas: always white/black regardless of page theme, boxed axes
  // with visible ticks, so the plot can be lifted straight into a thesis/paper.
  const axisStyle = {
    color: "#000", gridcolor: "#e5e7eb", zerolinecolor: "#000",
    showline: true, linecolor: "#000", linewidth: 1, mirror: true,
    ticks: "outside", tickcolor: "#000",
  };
  const layout = {
    margin: { l: 70, r: 20, t: 20, b: 55 },
    xaxis: { ...axisStyle, title: { text: px } },
    yaxis: { ...axisStyle, title: { text: oneD ? "Δχ²" : py } },
    paper_bgcolor: "#ffffff",
    plot_bgcolor: "#ffffff",
    font: { color: "#000", family: "Public Sans, system-ui, sans-serif", size: 13 },
    legend: { orientation: "v", bgcolor: "#ffffff", bordercolor: "#000", borderwidth: 1 },
    annotations,
    autosize: true,
  };
  if (oneD) {
    // auto-range y to data, but never below 0
    layout.yaxis.rangemode = "tozero";
  }

  Plotly.react("plot", traces, layout, { responsive: true, displaylogo: false });
}

function cl_interval(xs, dchi2, level) {
  let lo = null, hi = null;
  for (let i = 0; i < xs.length; i++) {
    if (dchi2[i] <= level) {
      if (lo === null) lo = xs[i];
      hi = xs[i];
    }
  }
  return [lo, hi];
}

function fmt(x) {
  if (x === null || x === undefined || Number.isNaN(x)) return "—";
  return Number(x).toPrecision(4).replace(/\.?0+$/, (m) => (m.includes(".") ? "" : m));
}
function fmtRange(lo, hi) {
  if (lo === null) return "—";
  return `[${fmt(lo)}, ${fmt(hi)}]`;
}

function paramsToShow() {
  return isOneD() ? [state.px] : [state.px, state.py];
}

function renderSummaryTable() {
  const params = paramsToShow();
  const table = document.getElementById("summary-table");
  const thead = table.querySelector("thead");
  const tbody = table.querySelector("tbody");

  thead.innerHTML = `<tr><th>Parameter</th><th>Experiment</th><th>Ordering</th><th>Best fit</th>${DATA.cl_labels.map((l) => `<th>${l}</th>`).join("")}</tr>`;

  const rows = [];
  for (const key of params) {
    for (const name of [...DATA.experiments].sort()) {
      for (const ordering of ["NO", "IO"]) {
        const expData = DATA.results[name][ordering];
        if (!expData) continue; // not every experiment has both orderings
        const d = expData.results_1d[key];
        if (!d) continue;
        const i = argmin(d.dchi2);
        const bestfit = d.x[i];
        const ranges = DATA.cl_levels_1d.map((lvl) => cl_interval(d.x, d.dchi2, lvl));
        rows.push({ key, name, ordering, bestfit, ranges });
      }
    }
  }

  tbody.innerHTML = rows.map((r) => `
    <tr>
      <td>${r.key}</td><td>${r.name}</td><td>${r.ordering}</td><td>${fmt(r.bestfit)}</td>
      ${r.ranges.map(([lo, hi]) => `<td>${fmtRange(lo, hi)}</td>`).join("")}
    </tr>
  `).join("");
}

async function downloadPlotPDF() {
  const plotEl = document.getElementById("plot");
  const { width, height } = plotEl.getBoundingClientRect();
  // High-res raster (3x) of the always-white publication-style canvas, embedded as a
  // single full-bleed image on a PDF page sized to match the plot's aspect ratio.
  const dataUrl = await Plotly.toImage(plotEl, { format: "png", width: Math.round(width), height: Math.round(height), scale: 3 });
  const { jsPDF } = window.jspdf;
  const orientation = width >= height ? "landscape" : "portrait";
  const pdf = new jsPDF({ orientation, unit: "pt", format: [width, height] });
  pdf.addImage(dataUrl, "PNG", 0, 0, width, height);
  pdf.save("newtrinos_plot.pdf");
}

// Prepend a UTF-8 BOM for text downloads so Excel (and other apps that don't assume
// UTF-8) render the unicode parameter names (θ₁₂, σ, Δm², …) correctly instead of as
// mojibake like "Î¸â‚â‚‚".
const UTF8_BOM = "﻿";

function downloadBlob(content, filename, mime, { bom = false } = {}) {
  const blob = new Blob([bom ? UTF8_BOM + content : content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function downloadCSV() {
  const params = paramsToShow();
  const header = ["parameter", "experiment", "ordering", "bestfit", ...DATA.cl_labels.map((l) => `CL_${l}_lo`), ...DATA.cl_labels.map((l) => `CL_${l}_hi`)];
  const lines = [header.join(",")];
  for (const key of params) {
    for (const name of DATA.experiments) {
      for (const ordering of ["NO", "IO"]) {
        const expData = DATA.results[name][ordering];
        if (!expData) continue; // not every experiment has both orderings
        const d = expData.results_1d[key];
        if (!d) continue;
        const i = argmin(d.dchi2);
        const ranges = DATA.cl_levels_1d.map((lvl) => cl_interval(d.x, d.dchi2, lvl));
        const los = ranges.map((r) => r[0] ?? "");
        const his = ranges.map((r) => r[1] ?? "");
        lines.push([key, name, ordering, d.x[i], ...los, ...his].join(","));
      }
    }
  }
  downloadBlob(lines.join("\n"), `newtrinos_summary_${params.join("_")}.csv`, "text/csv;charset=utf-8", { bom: true });
}

function downloadJSON() {
  const params = paramsToShow();
  const out = {};
  for (const name of DATA.experiments) {
    out[name] = {};
    for (const ordering of ["NO", "IO"]) {
      const expData = DATA.results[name][ordering];
      if (!expData) continue; // not every experiment has both orderings
      out[name][ordering] = {
        results_1d: Object.fromEntries(params.map((p) => [p, expData.results_1d[p]]).filter(([, v]) => v)),
      };
    }
  }
  downloadBlob(JSON.stringify(out, null, 2), `newtrinos_scan_${params.join("_")}.json`, "application/json");
}

main().catch((err) => {
  document.getElementById("source-note").textContent = "Failed to load results.json: " + err.message;
  console.error(err);
});

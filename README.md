# newtrinos-interactive_results
Interactive Visualisation of Newtrinos.jl Global Fit Results.

## What the page shows

### Scan plot

The main plot shows Δχ² for one oscillation parameter (1D) or a contour over a pair of
parameters (2D) — pick the parameter(s) from the **Axes** dropdowns. From there:

- **Confidence level** — a slider over the standard 1σ/90%/2σ/99%/3σ levels, drawn as a
  horizontal reference line (1D) or contour (2D) at the selected level; "Show all confidence
  levels" draws every level at once instead. "Show best-fit ★" toggles the marker at each
  curve's own minimum.
- **Datasets** — toggle which experiments are overlaid (only "Combined" is shown by default;
  the individual experiments are opt-in).
- **Mass ordering** — toggle Normal (NO, solid lines) and Inverted (IO, dashed lines)
  independently; both can be shown at once for comparison.
- **Export** — download the current plot as a PDF, the summary table below as a CSV, or the
  underlying scan data for the selected parameter(s) as JSON.

### Summary table

Below the plot, a table lists the best-fit value and every confidence interval (1σ through
3σ) for whichever parameter(s) are currently selected, broken out by experiment and mass
ordering — so the numbers behind the plot are always readable directly, not just inferred
from the curve.

### Residual ("pull") plot

Further down, a second plot shows pulls — (observed − predicted) / σ — for every data bin
across all experiments, at the best-fit point of whichever scan is currently selected above
(not a separate, fixed global fit: switching the Axes dropdowns changes which best-fit the
pulls are evaluated at). Each experiment gets its own color and a shaded ±1σ reference band;
experiments with more than one channel (e.g. MINOS's CC/NC, IceCube DeepCore's
Cascades/Tracks) share that color but use a different marker shape per channel so they stay
distinguishable. Hovering over a point shows which bin it is (its energy/angle range or,
for DeepCore's flattened 2D binning, the specific energy/cosθ bin) along with the observed,
predicted, and pull values.

### Used Code for result production

At the bottom of the page one can look into the source code, how the results were produced 
with Newtrinos.jl. This makes it very easy to reconstruct the shown results. 

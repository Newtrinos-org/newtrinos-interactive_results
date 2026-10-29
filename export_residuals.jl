#=
export_residuals.jl

Reads every "Combined"/"Combined (<category>)" experiment set's scan results
from results.jld2 (see compute_results.jl; written next to this script) and,
for every already-scanned parameter (1D) and parameter pair (2D) x ordering,
extracts that scan's own best-fit point (Newtrinos.bestfit — the argmin Δχ²
point already sitting inside each NewtrinosResult) and evaluates every
experiment IN THAT SET's forward_model there to get per-bin (observed,
predicted mean, predicted sigma) data. The dashboard picks whichever entry
matches the currently selected scan (and category, if any) and plots pulls:
(observed - predicted) / sigma, at THAT scan's own best fit — not a separate,
unconditional global best-fit.

This calls Newtrinos.bestfit on results that came from Newtrinos.scan, so the
"best fit" nuisance values are just whatever scan(...) fixed them to (nominal)
— only the scanned oscillation parameter(s) move. Once compute_results.jl
switches to Newtrinos.profile (same NewtrinosResult shape, so no code here
needs to change), the nuisances in these best-fits become real optimized
values instead of nominal placeholders.

Which experiments exist and which combined sets to compute residuals for both
come from experiments.toml — add an experiment there, not here (see
compute_results.jl's own header for the same point).

    NEWTRINOS_JL_PATH=/path/to/Newtrinos.jl julia export_residuals.jl

Writes data/residuals.json next to this script. Needs results.jld2 already
computed (compute_results.jl) and NEWTRINOS_JL_PATH pointed at a local clone
of Newtrinos.jl, to get live experiment objects with .forward_model/.assets
(results.jld2 only stores the scan grids/bestfit numbers, not those objects).
=#

haskey(ENV, "NEWTRINOS_JL_PATH") || error("Set the NEWTRINOS_JL_PATH environment variable to a local Newtrinos.jl checkout")

using Pkg
Pkg.activate(ENV["NEWTRINOS_JL_PATH"])

using Newtrinos
using OrderedCollections
using Statistics
using JLD2
using TOML

# Hand-rolled JSON writer (same approach as newtrinos-verifications/site/build.jl) so this
# script needs no extra dependency beyond what's already in Newtrinos.jl's own project —
# stacking in a separate project for JSON3 previously triggered a slow, fragile
# precompile cascade (and one failure) across the two environments' package versions.
tojson(x::AbstractDict) = "{" * join(["$(tojson(string(k))):$(tojson(v))" for (k, v) in x], ",") * "}"
tojson(x::AbstractVector) = "[" * join(tojson.(x), ",") * "]"
tojson(x::AbstractString) = "\"" * replace(x, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n") * "\""
tojson(x::Bool) = string(x)
tojson(x::Number) = string(x)
tojson(::Nothing) = "null"

round4(x) = round(x; sigdigits = 6)

experiments_config = TOML.parsefile(joinpath(@__DIR__, "experiments.toml"))["experiment"]
categories = unique(entry["category"] for entry in experiments_config)

osc_NO = Newtrinos.osc.OscillationConfig(
    flavour     = Newtrinos.osc.ThreeFlavour(ordering = :NO),
    propagation = Newtrinos.osc.Basic(),
    states      = Newtrinos.osc.All(),
    interaction = Newtrinos.osc.SI(),
)
osc_model_NO = Newtrinos.osc.configure(osc_NO)
physics_NO = (;
    osc = osc_model_NO,
    atm_flux = Newtrinos.atm_flux.configure(),
    earth_layers = Newtrinos.earth_layers.configure(),
    xsec = Newtrinos.xsec.configure(),
)

osc_IO = Newtrinos.osc.OscillationConfig(
    flavour     = Newtrinos.osc.ThreeFlavour(ordering = :IO),
    propagation = Newtrinos.osc.Basic(),
    states      = Newtrinos.osc.All(),
    interaction = Newtrinos.osc.SI(),
)
osc_model_IO = Newtrinos.osc.configure(osc_IO)
physics_IO = (;
    osc = osc_model_IO,
    atm_flux = Newtrinos.atm_flux.configure(),
    earth_layers = Newtrinos.earth_layers.configure(),
    xsec = Newtrinos.xsec.configure(),
)

# One "series" is a set of bins that share a single x-axis (e.g. one MINOS channel,
# or Daya Bay's single energy axis). An experiment can contribute more than one series.
struct Series
    label::String          # shown in the legend, e.g. "MINOS (CC)"
    axis_label::String     # physical quantity + unit, e.g. "Reconstructed energy (GeV)"
    x::Vector{Float64}     # bin centers (or a plain running index for multi-dimensional bins)
    bin_lo::Vector{Float64}
    bin_hi::Vector{Float64}
    observed::Vector{Float64}
    predicted::Vector{Float64}
    sigma::Vector{Float64}
    bin_desc::Vector{String}  # optional extra per-bin label (e.g. a 2D bin's own axes); "" if unused
end

Series(label, axis_label, x, bin_lo, bin_hi, observed, predicted, sigma) =
    Series(label, axis_label, x, bin_lo, bin_hi, observed, predicted, sigma, fill("", length(x)))

# Flattens a 2D (or more) per-channel array into one Series with a running-index x-axis and
# a decoded bin_desc per point — the pattern first used for DeepCore's (energy, coszen)
# bins, reused here for ORCA's per-channel (energy, coszen) arrays.
function flattened_series(label, axis_label, observed_2d, predicted_2d, sigma_2d, edges_a, edges_b, desc_fn)
    n_a, n_b = size(observed_2d)
    x = Float64[]; bin_lo = Float64[]; bin_hi = Float64[]
    observed = Float64[]; predicted = Float64[]; sigma = Float64[]; bin_desc = String[]
    idx = 0.0
    for ia in 1:n_a, ib in 1:n_b
        idx += 1
        push!(x, idx); push!(bin_lo, idx - 0.5); push!(bin_hi, idx + 0.5)
        push!(observed, observed_2d[ia, ib])
        push!(predicted, predicted_2d[ia, ib])
        push!(sigma, sigma_2d[ia, ib])
        push!(bin_desc, desc_fn(ia, ib, edges_a, edges_b))
    end
    Series(label, axis_label, x, bin_lo, bin_hi, observed, predicted, sigma, bin_desc)
end

function dayabay_series(exp, bf)
    bin_edges = exp.assets.energy_bins
    x = exp.assets.energy
    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))
    [Series("Daya Bay", "Prompt energy (MeV)", x, bin_edges[1:end-1], bin_edges[2:end],
            exp.assets.observed, m, sqrt.(v))]
end

function minos_series(exp, bf)
    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))
    series = Series[]
    for (ch, label) in [(:CC, "MINOS (CC)"), (:NC, "MINOS (NC)")]
        bin_edges = exp.assets.ch_data["FD" * String(ch)].bin_edges
        x = 0.5 .* (bin_edges[1:end-1] .+ bin_edges[2:end])
        push!(series, Series(label, "Reconstructed energy (GeV)", x, bin_edges[1:end-1], bin_edges[2:end],
                              exp.assets.observed[ch], m[ch], sqrt.(v[ch])))
    end
    series
end

function kamland_series(exp, bf)
    bin_edges = exp.assets.Ep_bins
    x = exp.assets.Ep
    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))
    [Series("KamLAND", "Prompt energy (MeV)", x, bin_edges[1:end-1], bin_edges[2:end],
            exp.assets.observed, m, sqrt.(v))]
end

# DeepCore's bins are 3D (reco energy x cos(zenith) x PID). There's no single meaningful
# numeric x-axis for that, so each PID category becomes its own series with a plain running
# index for x, and a bin_desc string per point decoding which (energy, coszen) bin it is —
# the dashboard shows that decoded label on hover instead of a bare bin number.
function deepcore_series(exp, bf)
    binning = exp.assets.binning
    e_edges = binning.reco_energy_bin_edges
    cz_edges = binning.reco_coszen_bin_edges

    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))

    series = Series[]
    for (pid, label) in [(1, "DeepCore (Cascades)"), (2, "DeepCore (Tracks)")]
        desc(ie, icz, ee, cze) = "E ∈ [$(ee[ie]), $(ee[ie+1])) GeV, cosθ ∈ [$(cze[icz]), $(cze[icz+1]))"
        push!(series, flattened_series(label, "flattened (energy, cosθ) bin",
            exp.assets.observed[:, :, pid], m[:, :, pid], sqrt.(v[:, :, pid]), e_edges, cz_edges, desc))
    end
    series
end

# ORCA's bins are 2D (reco energy x reco coszen) per channel, 3 channels (hpt/lpt/showers —
# high-/low-purity tracks and showers). Each channel's energy-axis row count differs slightly
# (hpt/lpt drop the last energy bin, showers keeps all — see orca.jl's own `cut`), so edges
# are sliced to match each channel's own observed/predicted array shape rather than assumed.
function orca_series(exp, bf)
    binning = exp.assets.binning
    e_edges_full = binning.e_reco_edges
    cz_edges = binning.cz_reco_edges[1:11]

    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))

    series = Series[]
    for (ch, label) in [(:hpt, "ORCA (high-purity tracks)"), (:lpt, "ORCA (low-purity tracks)"), (:showers, "ORCA (showers)")]
        obs = exp.assets.observed[ch]
        n_e = size(obs, 1)
        e_edges = e_edges_full[1:n_e+1]
        desc(ie, icz, ee, cze) = "E ∈ [$(round4(ee[ie])), $(round4(ee[ie+1]))) GeV, cosθ ∈ [$(round4(cze[icz])), $(round4(cze[icz+1])))"
        push!(series, flattened_series(label, "flattened (energy, cosθ) bin",
            obs, m[ch], sqrt.(v[ch]), e_edges, cz_edges, desc))
    end
    series
end

# Super-K has a single flat vector over all analysis bins (no fixed 2D array — different
# samples have different bin counts/types), with per-bin metadata in assets.bininfo rather
# than a bin-edges array. bin_desc decodes each bin's sample name plus whichever of the
# momentum or coszen range is meaningful for that row (samples are either energy-binned or
# coszen-binned, never both — CosZMin/Max are only meaningful when not the sentinel -1).
function superk_series(exp, bf)
    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))
    bininfo = exp.assets.bininfo
    n = length(exp.assets.observed)

    x = collect(1.0:n)
    bin_desc = map(1:n) do i
        row = bininfo[i, :]
        range_str = row.CosZMin == -1 ?
            "p ∈ [$(round4(row.logPMin)), $(round4(row.logPMax))) log-momentum" :
            "cosθ ∈ [$(round4(row.CosZMin)), $(round4(row.CosZMax)))"
        "$(row.Sample), $range_str"
    end

    [Series("Super-K", "flattened analysis bin", x, x .- 0.5, x .+ 0.5,
            exp.assets.observed, m, sqrt.(v), bin_desc)]
end

# JUNO/TAO are simulation-only experiments — Newtrinos.jl's modules for them carry no
# observed data at all (no assets.observed field; their own `plot` functions take an
# explicit `data_to_plot` argument instead). The only "observed" value available is
# Newtrinos.generate_asimov_data, which is just forward_model's own mean, rounded — so a
# pull computed this way is exactly zero everywhere by construction, not a real data check.
# Shown anyway (labeled clearly) for a uniform per-experiment residuals view across the site.
function simulation_only_series(exp, bf, label, axis_label)
    observed = Newtrinos.generate_asimov_data(exp, bf)
    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))
    edges = exp.assets.E_bins_visible
    step_ = edges isa AbstractRange ? step(edges) : (edges[2] - edges[1])
    [Series(label, axis_label, collect(edges), collect(edges) .- step_ / 2, collect(edges) .+ step_ / 2,
            observed, m, sqrt.(v))]
end
juno_series(exp, bf) = simulation_only_series(exp, bf, "JUNO (Asimov — simulation only, no real data)", "Visible energy (MeV)")
tao_series(exp, bf) = simulation_only_series(exp, bf, "TAO (Asimov — simulation only, no real data)", "Visible energy (MeV)")

# Maps each experiments.toml `module` name to its series function, so all_series_at can stay
# generic over whatever experiments a given combined set actually includes.
const SERIES_FNS = Dict(
    "dayabay"  => dayabay_series,
    "minos"    => minos_series,
    "kamland"  => kamland_series,
    "deepcore" => deepcore_series,
    "orca"     => orca_series,
    "super_k"  => superk_series,
    "juno"     => juno_series,
    "tao"      => tao_series,
)

function all_series_at(experiments, bf)
    s = Series[]
    for mod_name in keys(experiments)
        append!(s, SERIES_FNS[string(mod_name)](experiments[mod_name], bf))
    end
    s
end

series_to_json(s::Series) = OrderedDict(
    "label" => s.label,
    "axis_label" => s.axis_label,
    "x" => round4.(s.x),
    "bin_lo" => round4.(s.bin_lo),
    "bin_hi" => round4.(s.bin_hi),
    "observed" => round4.(s.observed),
    "predicted" => round4.(s.predicted),
    "sigma" => round4.(s.sigma),
    "bin_desc" => s.bin_desc,
)

# --- Load every Combined/Combined (<category>) set's already-computed scan results ---
loaded = JLD2.load(joinpath(@__DIR__, "results.jld2"))
params_results = loaded["params_results"]
scan_params = loaded["scan_params"]  # Vector{String}

combined_set_names = ["Combined"; ["Combined ($c)" for c in categories]]

# For a given combined-set name, the subset of experiments.toml entries it includes.
function entries_for_set(set_name)
    if set_name == "Combined"
        experiments_config
    else
        category = match(r"^Combined \((.+)\)$", set_name)[1]
        filter(e -> e["category"] == category, experiments_config)
    end
end

function configure_experiments(entries, physics)
    NamedTuple(Symbol(e["module"]) => getfield(Newtrinos, Symbol(e["module"])).configure(physics) for e in entries)
end

entries = OrderedDict{String, Any}()  # key: "<set>:1d:<param>:<ordering>" or "<set>:2d:<a>|<b>:<ordering>"

for set_name in combined_set_names
    set_entries = entries_for_set(set_name)
    experiments_by_ordering = Dict(
        "NO" => configure_experiments(set_entries, physics_NO),
        "IO" => configure_experiments(set_entries, physics_IO),
    )

    for ordering in ("NO", "IO")
        experiments = experiments_by_ordering[ordering]
        combined = params_results[set_name][ordering]

        for key in scan_params
            result = combined.results_1d[key]
            bf = Newtrinos.bestfit(result)
            t0 = time()
            series = all_series_at(experiments, bf)
            println("[$set_name] 1D bestfit $(key) ($(ordering)): forward_model eval took $(round(time() - t0, digits=2)) s")
            entries["$(set_name):1d:$(key):$(ordering)"] = OrderedDict(
                "bestfit" => OrderedDict(string(k) => v for (k, v) in pairs(bf)),
                "series" => series_to_json.(series),
            )
        end

        for (a, b) in keys(combined.results_2d)
            result = combined.results_2d[(a, b)]
            bf = Newtrinos.bestfit(result)
            t0 = time()
            series = all_series_at(experiments, bf)
            println("[$set_name] 2D bestfit $(a),$(b) ($(ordering)): forward_model eval took $(round(time() - t0, digits=2)) s")
            entries["$(set_name):2d:$(a)|$(b):$(ordering)"] = OrderedDict(
                "bestfit" => OrderedDict(string(k) => v for (k, v) in pairs(bf)),
                "series" => series_to_json.(series),
            )
        end
    end
end

data = OrderedDict{String, Any}(
    "note" => "Best-fit predictions at each scan's OWN best-fit point (argmin Δχ² along that specific parameter/pair), not a single global best-fit. Currently sourced from Newtrinos.scan results, so nuisance parameters are at their nominal (fixed) values — only the scanned oscillation parameter(s) actually move with the selection. Switching compute_results.jl's combined sets from Newtrinos.scan to Newtrinos.profile (no other code change needed) will make nuisances real optimized values too.",
    "entries" => entries,
)

out_dir = joinpath(@__DIR__, "data")
mkpath(out_dir)
out_path = joinpath(out_dir, "residuals.json")
open(out_path, "w") do io
    write(io, tojson(data))
end
println("Wrote $(out_path) ($(round(filesize(out_path) / 1024, digits=1)) KiB)")

#=
export_residuals.jl

Reads the Combined experiment set's scan results from results.jld2 (see
compute_results.jl; written next to this script) and, for every
already-scanned parameter (1D) and parameter pair (2D) x ordering, extracts
that scan's own best-fit point (Newtrinos.bestfit — the argmin Δχ² point
already sitting inside each NewtrinosResult) and evaluates every experiment's
forward_model there to get per-bin (observed, predicted mean, predicted
sigma) data. The dashboard picks whichever entry matches the currently
selected scan and plots pulls: (observed - predicted) / sigma, at THAT scan's
own best fit — not a separate, unconditional global best-fit.

This calls Newtrinos.bestfit on results that came from Newtrinos.scan, so the
"best fit" nuisance values are just whatever scan(...) fixed them to (nominal)
— only the scanned oscillation parameter(s) move. Once compute_results.jl
switches the Combined set from Newtrinos.scan to Newtrinos.profile (same
NewtrinosResult shape, so no code here needs to change), the nuisances in
these best-fits become real optimized values instead of nominal placeholders.

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
    n_e, n_cz = length(e_edges) - 1, length(cz_edges) - 1

    m = mean(exp.forward_model(bf))
    v = var(exp.forward_model(bf))

    series = Series[]
    for (pid, label) in [(1, "DeepCore (Cascades)"), (2, "DeepCore (Tracks)")]
        x = Float64[]
        bin_lo = Float64[]
        bin_hi = Float64[]
        observed = Float64[]
        predicted = Float64[]
        sigma = Float64[]
        bin_desc = String[]
        idx = 0.0
        for ie in 1:n_e, icz in 1:n_cz
            idx += 1
            push!(x, idx)
            push!(bin_lo, idx - 0.5)
            push!(bin_hi, idx + 0.5)
            push!(observed, exp.assets.observed[ie, icz, pid])
            push!(predicted, m[ie, icz, pid])
            push!(sigma, sqrt(v[ie, icz, pid]))
            push!(bin_desc, "E ∈ [$(e_edges[ie]), $(e_edges[ie+1])) GeV, cosθ ∈ [$(cz_edges[icz]), $(cz_edges[icz+1]))")
        end
        push!(series, Series(label, "flattened (energy, cosθ) bin", x, bin_lo, bin_hi, observed, predicted, sigma, bin_desc))
    end
    series
end

function all_series_at(experiments, bf)
    s = Series[]
    append!(s, dayabay_series(experiments.dayabay, bf))
    append!(s, minos_series(experiments.minos, bf))
    append!(s, kamland_series(experiments.kamland, bf))
    append!(s, deepcore_series(experiments.deepcore, bf))
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

# --- Load the Combined set's already-computed scan results (no new fit here) ---
loaded = JLD2.load(joinpath(@__DIR__, "results.jld2"))
params_results = loaded["params_results"]
scan_params = loaded["scan_params"]  # Vector{String}

experiments_by_ordering = Dict(
    "NO" => (dayabay = Newtrinos.dayabay.configure(physics_NO), minos = Newtrinos.minos.configure(physics_NO),
             kamland = Newtrinos.kamland.configure(physics_NO), deepcore = Newtrinos.deepcore.configure(physics_NO)),
    "IO" => (dayabay = Newtrinos.dayabay.configure(physics_IO), minos = Newtrinos.minos.configure(physics_IO),
             kamland = Newtrinos.kamland.configure(physics_IO), deepcore = Newtrinos.deepcore.configure(physics_IO)),
)

entries = OrderedDict{String, Any}()  # key: "1d:<param>:<ordering>" or "2d:<a>|<b>:<ordering>"

for ordering in ("NO", "IO")
    experiments = experiments_by_ordering[ordering]
    combined = params_results["Combined"][ordering]

    for key in scan_params
        result = combined.results_1d[key]
        bf = Newtrinos.bestfit(result)
        t0 = time()
        series = all_series_at(experiments, bf)
        println("1D bestfit $(key) ($(ordering)): forward_model eval took $(round(time() - t0, digits=2)) s")
        entries["1d:$(key):$(ordering)"] = OrderedDict(
            "bestfit" => OrderedDict(string(k) => v for (k, v) in pairs(bf)),
            "series" => series_to_json.(series),
        )
    end

    for (a, b) in keys(combined.results_2d)
        result = combined.results_2d[(a, b)]
        bf = Newtrinos.bestfit(result)
        t0 = time()
        series = all_series_at(experiments, bf)
        println("2D bestfit $(a),$(b) ($(ordering)): forward_model eval took $(round(time() - t0, digits=2)) s")
        entries["2d:$(a)|$(b):$(ordering)"] = OrderedDict(
            "bestfit" => OrderedDict(string(k) => v for (k, v) in pairs(bf)),
            "series" => series_to_json.(series),
        )
    end
end

data = OrderedDict{String, Any}(
    "note" => "Best-fit predictions at each scan's OWN best-fit point (argmin Δχ² along that specific parameter/pair), not a single global best-fit. Currently sourced from Newtrinos.scan results, so nuisance parameters are at their nominal (fixed) values — only the scanned oscillation parameter(s) actually move with the selection. Switching compute_results.jl's Combined set from Newtrinos.scan to Newtrinos.profile (no other code change needed) will make nuisances real optimized values too.",
    "entries" => entries,
)

out_dir = joinpath(@__DIR__, "data")
mkpath(out_dir)
out_path = joinpath(out_dir, "residuals.json")
open(out_path, "w") do io
    write(io, tojson(data))
end
println("Wrote $(out_path) ($(round(filesize(out_path) / 1024, digits=1)) KiB)")

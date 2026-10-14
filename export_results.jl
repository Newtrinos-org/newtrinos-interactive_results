#=
export_results.jl

Converts `results.jld2` (see compute_results.jl; written next to this script)
into a single compact JSON file that the static Plotly.js dashboard
(index.html/app.js) can load with a plain `fetch`. No Newtrinos.jl, Bonito or
WGLMakie dependency here — only JLD2 + JSON3, so this can run in a minimal CI
environment later.

    julia --project=. export_results.jl

Writes data/results.json next to this script.
=#

using JLD2, JSON3, OrderedCollections

loaded = JLD2.load(joinpath(@__DIR__, "results.jld2"))
params_results = loaded["params_results"]
scan_params    = loaded["scan_params"]
cl_labels      = loaded["cl_labels"]
cl_levels_1d   = loaded["cl_levels_1d"]
cl_levels_2d   = loaded["cl_levels_2d"]

experiments = collect(keys(params_results))

round4(x) = round(x; sigdigits = 6)

# results_1d[param] -> {x: [...], dchi2: [...]}
function export_1d(results_1d, scan_params)
    out = OrderedDict{String, Any}()
    for key in scan_params
        r = results_1d[key]
        x = r.axes[1]
        lp = r.values.log_posterior
        dchi2 = -2 .* (lp .- maximum(lp))
        out[key] = (x = round4.(x), dchi2 = round4.(dchi2))
    end
    return out
end

# results_2d[(a,b)] -> {x: [...], y: [...], dchi2: [[...]...]} stored under key "a|b"
function export_2d(results_2d)
    out = OrderedDict{String, Any}()
    for ((a, b), r) in results_2d
        xs, ys = r.axes[1], r.axes[2]
        lp = r.values.log_posterior
        dchi2 = -2 .* (lp .- maximum(lp))
        # store row-major (y outer, x inner) so JS can index dchi2[iy][ix] directly
        grid = [round4.(dchi2[:, iy]) for iy in eachindex(ys)]
        out["$a|$b"] = (x = round4.(xs), y = round4.(ys), dchi2 = grid)
    end
    return out
end

data = OrderedDict{String, Any}(
    "scan_params"  => scan_params,
    "cl_labels"    => cl_labels,
    "cl_levels_1d" => cl_levels_1d,
    "cl_levels_2d" => cl_levels_2d,
    "experiments"  => experiments,
    "results"      => OrderedDict(
        # Not every experiment set has both orderings — e.g. standalone "IceCube Deepcore"
        # currently has no IO entry (see compute_results.jl's DEEPCORE_SUPPORTS_IO) — so only
        # emit the orderings that were actually computed for this set.
        exp_name => OrderedDict(
            ordering => OrderedDict(
                "results_1d" => export_1d(params_results[exp_name][ordering].results_1d, scan_params),
                "results_2d" => export_2d(params_results[exp_name][ordering].results_2d),
            )
            for ordering in ("NO", "IO") if haskey(params_results[exp_name], ordering)
        )
        for exp_name in experiments
    ),
)

out_dir = joinpath(@__DIR__, "data")
mkpath(out_dir)
out_path = joinpath(out_dir, "results.json")
open(out_path, "w") do io
    JSON3.write(io, data)
end

println("Wrote $(out_path) ($(round(filesize(out_path) / 1024^2, digits=2)) MiB)")

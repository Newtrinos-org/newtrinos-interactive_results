#=
compute_results.jl

Configures physics, runs the Newtrinos.jl likelihood scans for every
experiment/mass-ordering combination, and saves the results to
`results.jld2` next to this script. Run with:

    NEWTRINOS_JL_PATH=/path/to/Newtrinos.jl julia compute_results.jl

NEWTRINOS_JL_PATH must point at a local clone/checkout of Newtrinos.jl (its
Project.toml is activated to run the scans) — no path is assumed, since this
repo doesn't contain or vendor Newtrinos.jl itself.

The set of experiments to scan comes from experiments.toml, not from this
file — to add a Newtrinos.jl experiment module to the site, add an entry
there (name/module/category), nothing here needs editing.

export_results.jl and export_residuals.jl load results.jld2 and only need
plain data (Dict/NamedTuple/Vector) — they don't depend on Newtrinos.jl's own
internal types, only on calling Newtrinos.bestfit/forward_model with it.
=#

haskey(ENV, "NEWTRINOS_JL_PATH") || error("Set the NEWTRINOS_JL_PATH environment variable to a local Newtrinos.jl checkout")

using Pkg
Pkg.activate(ENV["NEWTRINOS_JL_PATH"])

using Newtrinos
using OrderedCollections
using JLD2
using TOML

# Single source of truth for which experiments this site uses — see experiments.toml's own
# header comment. Each entry becomes one experiment_defs entry and one field of "Combined".
experiments_config = TOML.parsefile(joinpath(@__DIR__, "experiments.toml"))["experiment"]

#configure physics
#default settings

#Normal Ordering
osc_NO = Newtrinos.osc.OscillationConfig(
    flavour= Newtrinos.osc.ThreeFlavour(ordering=:NO),
    propagation = Newtrinos.osc.Basic(),
    states      = Newtrinos.osc.All(),
    interaction = Newtrinos.osc.SI(),
)
osc_model_NO = Newtrinos.osc.configure(osc_NO)
physics_NO =(;osc=osc_model_NO,
            atm_flux = Newtrinos.atm_flux.configure(),
            earth_layers = Newtrinos.earth_layers.configure(),
            xsec = Newtrinos.xsec.configure(),
)

#inverted ordering
osc_IO = Newtrinos.osc.OscillationConfig(
    flavour= Newtrinos.osc.ThreeFlavour(ordering=:IO),
    propagation = Newtrinos.osc.Basic(),
    states      = Newtrinos.osc.All(),
    interaction = Newtrinos.osc.SI(),
)
osc_model_IO = Newtrinos.osc.configure(osc_IO)
physics_IO =(;osc=osc_model_IO,
            atm_flux = Newtrinos.atm_flux.configure(),
            earth_layers = Newtrinos.earth_layers.configure(),
            xsec = Newtrinos.xsec.configure(),
)

#mapping of experiments to their Newtrinos experiment module calls, generated from
#experiments.toml — add a new experiment there, not here.

experiment_defs = Dict(
    entry["name"] => phys -> getfield(Newtrinos, Symbol(entry["module"])).configure(phys)
    for entry in experiments_config
)

# Also define combined experiment sets
experiment_sets = Dict{String, Any}()
for (name, func) in experiment_defs
    experiment_sets[name] = phys -> NamedTuple{(Symbol(lowercase(replace(name, " " => ""))),)}((func(phys),))
end

# Add the combined fit definition: every configured experiment, keyed by its module name.
experiment_sets["Combined"] = phys -> NamedTuple(
    Symbol(entry["module"]) => getfield(Newtrinos, Symbol(entry["module"])).configure(phys)
    for entry in experiments_config
)

# Also add one combined fit per category (every experiment in that category, jointly) — e.g.
# "Combined (reactor)" joins Daya Bay+KamLAND+JUNO+TAO. Category pages show this alongside
# their individual-experiment scans, same pattern as the site-wide "Combined" above.
for category in unique(entry["category"] for entry in experiments_config)
    cat_entries = filter(entry -> entry["category"] == category, experiments_config)
    experiment_sets["Combined ($category)"] = phys -> NamedTuple(
        Symbol(entry["module"]) => getfield(Newtrinos, Symbol(entry["module"])).configure(phys)
        for entry in cat_entries
    )
end

#Confidence-level definitions shared by the 1D scan and 2D contour plots
#(standard χ² quantiles: 1 dof for the 1D Δχ² curves, 2 dof for the pairwise contours)
cl_labels    = ["1σ", "90%", "2σ", "99%", "3σ"]
cl_levels_1d = [1.00, 2.71, 4.00, 6.63,  9.00]   # 1 dof
cl_levels_2d = [2.30, 4.61, 6.18, 9.21, 11.83]   # 2 dof

#Helper Function to run 1D + 2D likelihood scans for a given ordering
function run_experiment_scans(exp_config_fn, physics_obj, scan_symbols, scan_pairs; grid_points=31, grid_points_2d=21)
    exp = exp_config_fn(physics_obj)
    params = Newtrinos.get_params(exp)
    priors = Newtrinos.get_priors(exp)
    likelihood = Newtrinos.generate_likelihood(exp)

    results_1d = Dict{String, Any}()
    for sym in scan_symbols
        # Store using String keys to match the Dropdown options (e.g., "θ₁₂")
        results_1d[string(sym)] = Newtrinos.scan(likelihood, priors, OrderedDict(sym => grid_points), params)
    end

    results_2d = Dict{Tuple{String,String}, Any}()
    for (a, b) in scan_pairs
        results_2d[(string(a), string(b))] = Newtrinos.scan(likelihood, priors, OrderedDict(a => grid_points_2d, b => grid_points_2d), params)
    end

    return (; results_1d, results_2d)
end

#generate all result dictionaries
scan_params = [:θ₁₂, :θ₁₃, :θ₂₃, :Δm²₂₁, :Δm²₃₁, :δCP]
scan_pairs  = [(scan_params[i], scan_params[j]) for i in 1:length(scan_params) for j in i+1:length(scan_params)]

params_results = Dict{String, Dict{String, Any}}()

for (exp_name, config_fn) in experiment_sets
    params_results[exp_name] = Dict(
        "NO" => run_experiment_scans(config_fn, physics_NO, scan_params, scan_pairs),
        "IO" => run_experiment_scans(config_fn, physics_IO, scan_params, scan_pairs)
    )
end

# Save everything the display notebook needs. Symbols are saved as strings so
# the display side has no need to know about Newtrinos.jl's parameter symbols.
output_path = joinpath(@__DIR__, "results.jld2")
JLD2.jldsave(
    output_path;
    params_results,
    scan_params = string.(scan_params),
    cl_labels, cl_levels_1d, cl_levels_2d,
)

println("Saved scan results to $(output_path) ($(round(filesize(output_path) / 1024^2, digits=2)) MiB)")

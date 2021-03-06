module TwoAgents

using CompEcon
using JLD
using NLsolve

include("../ModelAbstraction.jl")
using .ModelAbstraction

immutable SolutionForState
    c1::Float64
    c2::Float64
    J::Float64
    result::NLsolve.SolverResults{Float64}
end

immutable BCFL21
    agent1::EpsteinZinAgent
    agent2::EpsteinZinAgent
    production1::CESProducer
    production2::CESProducer
    ac1::AdjCost
    ac2::AdjCost
    exog::ConstantVolatility{2}
    gp::Matrix{Float64}
    ss::DefaultStateSpace{3,1,Float64,4}
end

function BCFL21(;ρ1::Real=-1.0 , α1::Real=-9.0, β1::Real=0.999,
                 ρ2::Real=-1.0 , α2::Real=-9.0, β2::Real=0.999,
                 η1::Real=1.0/3, ν1::Real=.1, η2::Real=1.0/3, ν2::Real=.1,
                 γ::Real=.9, δ::Real=0.025, σ1::Real=0.001, σ2::Real=0.001,
                 nϵ1::Int=2, nϵ2::Int=2,
                 nk1::Int=10, nk2::Int=10, nU::Int=8, nξ::Int=5)

    # Agents
    agent1 = EpsteinZinAgent(ρ1, α1, β1)
    agent2 = EpsteinZinAgent(ρ2, α2, β2)

    # Producers
    production1 = CESProducer(η1, ν1)
    production2 = CESProducer(η2, ν2)

    # AdjustmentCosts
    ac1 = AdjCost(δ, .75)
    ac2 = AdjCost(δ, .75)

    # exog
    exog = ConstantVolatility(γ, σ1, σ2, nϵ1, nϵ2)

    # state space
    kmin, kmax = 10., 35.
    ξmin, ξmax = .97, 1.03
    Umin = .1
    Umax = produce(production1, kmax, 1.) + produce(production2, kmax, ξmax)
    basis = Basis(SplineParams(collect(linspace(kmin, kmax, nk1)), 0, 2),
                  SplineParams(collect(linspace(kmin, kmax, nk2)), 0, 2),
                  SplineParams(collect(linspace(Umin , Umax, nU)), 0, 2),
                  LinParams(collect(linspace(ξmin, ξmax, nξ)), 0))

    grid, (_k1grid, _k2grid, _Ugrid, _ξgrid) = nodes(basis)

    lξp = (2γ-1)*log(grid[:, 4]) .+ (σ2*exog.ϵ[:, 2]' - σ1*exog.ϵ[:, 1]')
    lξp = clamp(lξp, log(_ξgrid[1]), log(_ξgrid[end]))'
    lgp = (γ-1)*log(grid[:, 4]) .+ σ1*exog.ϵ[:, 1]'

    _en = tuple(map(EndogenousState, (_k1grid, _k2grid, _Ugrid),
                                     (basis[1], basis[2], basis[2]))...)
    _ex = (ExogenousState(_ξgrid, exp(lξp), basis[4]),)

    ss = DefaultStateSpace(_en, _ex, grid, grid', basis)

    # package it up!
    return BCFL21(agent1, agent2, production1, production2, ac1, ac2, exog,
                  exp(lgp)', ss)
end

_unpack_params(m::BCFL21) = vcat(_unpack(m.agent1)..., _unpack(m.agent2)...,
                             _unpack(m.ac1)..., _unpack(m.ac2)...)

function compute_residuals!(bcfl::BCFL21, state::Vector{Float64}, J::Float64,
                            dJU::Float64, dJk1::Float64, dJk2::Float64,
                            coefs::Vector{Float64},
                            gp::Vector{Float64}, ξp::Vector{Float64},
                            guess::Vector, resid::Vector)

    # Unpack parameters.
    ρ1, α1, β1, ρ2, α2, β2, δ1, η1, δ2, η2 = _unpack_params(bcfl)
    Π = bcfl.exog.Π

    # extract guess and state
    I1, I2 = guess[1:2]
    Up = guess[3:end]
    k1, k2, U, ξ = state

    # Force the constraints I want!!! RAWRRRRRR
    if any(Up .< 0)
        # @show Up statep
        resid[:] = 1e6
        return NaN, NaN, NaN
    end
    if -I1 > k1
        resid[:] = 1e6
        return NaN, NaN, NaN
    end
    if -I2 > k2
        resid[:] = 1e6
        return NaN, NaN, NaN
    end

    # Derivative of Adjustment costs
    # NOTE: I am assuming that Γ_i(k_i, I_i) = (1 - δ_i) k_i + I_i
    dΓ1_dI1 = 1.0  # - _dIac(bcfl.ac1, k1, I1)
    dΓ2_dI2 = 1.0  # - _dIac(bcfl.ac2, k2, I2)
    dΓ1_dk1 = (1 - δ1)  # - _dkac(bcfl.ac1, k1, I1)
    dΓ2_dk2 = (1 - δ2)  # - _dkac(bcfl.ac1, k1, I1)

    # MPK for agent 1. Note we set the `z` arg to one b/c we scaled by z1
    df1dk1 = f_k(bcfl.production1, k1, 1.0)
    df2dk2 = f_k(bcfl.production2, k2, ξ)

    # Get tomorrow's state
    k1p = ((1 - δ1)*k1 + I1) ./ gp  # - _ac(bcfl.ac1, k1, I1)) ./ gp
    k2p = ((1 - δ2)*k2 + I2) ./ gp  # - _ac(bcfl.ac2, k2, I2)) ./ gp
    statep = [k1p k2p Up ξp]

    # Evaluate value function and its partials at next period's state. This is
    # done at the same time so we only have to compute 7 basis matrices instead
    # of the full 16 we will be using.
    out = funeval(coefs, bcfl.ss.basis, statep,
                  [0 0 0 0; 1 0 0 0; 0 1 0 0; 0 0 1 0])
    # out will be (4×1×length(gp))
    Jp    = out[:, 1, 1]
    dJpk1 = out[:, 1, 2]
    dJpk2 = out[:, 1, 3]
    dJpU  = out[:, 1, 4]

    # Evaluate all expectations
    if any(Jp .< 0)
        @show Jp statep
    end

    μ1 = dot(Π, (gp .* Jp).^(α1))^(1.0/α1)
    μ2 = dot(Π, (gp .* Up).^(α2))^(1.0/α2)
    EV11 = dot(Π, (gp .* Jp).^(α1 - 1.) .* dJpk1)
    EV12 = dot(Π, (gp .* Jp).^(α1 - 1.) .* dJpk2)

    # TODO: Remove all shows once we are more convinced it is working
    # get consumption
    c1_num   = dJk1 - β1 * J^(1-ρ1) * μ1^(ρ1-α1) * dΓ1_dk1 * EV11
    c1_num = c1_num > 0 ? c1_num : abs(c1_num)
    c1_denom = J.^(1-ρ1) * (1-β1) * df1dk1
    c1       = (c1_num/c1_denom)^(1/(ρ1-1))

    c2_num   = dJk2 - β1 * J^(1-ρ1) * μ1^(ρ1-α1) * dΓ2_dk2 * EV12
    c2_num = c2_num > 0 ? c2_num : abs(c2_num)
    c2_denom = -dJU * U.^(1-ρ1) * (1-β2) * df2dk2
    c2       = (c2_num/c2_denom)^(1/(ρ2-1))

    # c2 = ((-dJU * U^(1-ρ2) * (1-β2)) / (J^(1-ρ1) * (1-β1) * c1^(ρ1-1)))^(1/(ρ2-1))

    # I residual
    lhsI1 = EV11 .* dΓ1_dI1
    rhsI1 = EV12 .* dΓ2_dI2
    resid[1] = lhsI1 - rhsI1

    # use c1, c2, I1 in budget constraint to get residual for I2
    rhsI2 = c1 + c2 + I1 + I2
    lhsI2 = produce(bcfl.production1, k1, 1.) + produce(bcfl.production2, k2, ξ)
    resid[2] = rhsI2 - lhsI2

    # U residual
    nUp = length(Up)
    for i=1:nUp
        lhs = -dJU * U.^(1-ρ2) * β2 * μ2.^(ρ2-α2) .* gp[i]^α2 .* Up[i].^(α2-1)
        # TODO: check rhs to make sure that we have negative signs in the right
        #       place.
        rhs = J^(1-ρ1) * β1 * μ1.^(ρ1-α1) * gp[i]^α1 * Jp[i]^(α1-1) * (-dJpU[i])
        resid[i+2] = lhs - rhs
    end

    J = utility(bcfl.agent1, c1, μ1)

    # we are safe to return whatever we want because NLsolve just cares that
    # we update resid in place and completely ignores the return value of this
    # function
    return c1, c2, J
end

function initial_coefs(bcfl::BCFL21, bs::BasisStructure)
    #=
    Here we just manufacturing an initial guess that should be in the ballpark of
    the actual domain and has partial derivatives with the right sign. Specifically,
    we are imposing that:

    - `dJ/dU < 0`
    - `dJ/dk1 > 0`
    - `dJ/dk2 > 0`

    everywhere
    =#

    k1 = bcfl.ss.grid[:, 1]
    k2 = bcfl.ss.grid[:, 2]
    U = bcfl.ss.grid[:, 3]
    ξ = bcfl.ss.grid[:, 4]

    y = produce(bcfl.production1, k1, 1.) + produce(bcfl.production2, k2, ξ)

    # Agent 1's value starts at 1/2 of agent 2's in the "opposite" state (hence the reverse)
    # then gets 1/2 of production added to it.
    J = (reverse(U) + y) / 2.0
    coefs = CompEcon.get_coefs(bcfl.ss.basis, bs, J)

    return coefs
end

function create_jld_output_file()
    out_dir = joinpath(dirname(@__FILE__), "output")
    !isdir(out_dir) && mkdir(out_dir)

    matches = filter(x->x != nothing,
                     map(x->match(r"(\d+$)", split(x, ".")[1]),
                     filter(x->endswith(x, ".jld"),
                     readdir(out_dir))))
    if isempty(matches)
        num = 1
    else
        num = maximum(Int[parse(Int, m[1]) for m in matches]) + 1
    end

    fn = joinpath(out_dir, "results$(num).jld")
    jldopen(fn, "w") do f
        nothing
    end
    return fn
end

function brutal_solution(bcfl::BCFL21; tol=1e-4, maxiter=500)

    # Unpack parameters.
    dist, iter = 10., 0
    ρ1, α1, β1, ρ2, α2, β2, δ1, η1, δ2, η2 = _unpack_params(bcfl)

    # BasisStructure for interpolation
    bs = BasisStructure(bcfl.ss.basis, Direct(), bcfl.ss.grid,
                        [0 0 0 0; 1 0 0 0; 0 1 0 0; 0 0 1 0])

    coefs = initial_coefs(bcfl, bs)
    Nϵ = size(bcfl.gp, 1)

    # extract grids to ease notation
    k1_grid = bcfl.ss.grid[:, 1]
    k2_grid = bcfl.ss.grid[:, 2]
    U_grid = bcfl.ss.grid[:, 3]
    ξ_grid = bcfl.ss.grid[:, 4]

    i1 = (δ1-1).*k1_grid .+ (k1_grid .+ k2_grid)./(ξ_grid + 1)
    i2 = (k1_grid.*ξ_grid + k2_grid.*(δ2*ξ_grid + δ2 - 1.)) ./ (ξ_grid + 1)
    prev_soln(i::Int) = [i1[i]; i2[i]; fill(U_grid[i], Nϵ)]

    result_fn = create_jld_output_file()

    local all_sfs  # declare out local so we can return it outside while
    while dist > tol && iter < maxiter
        # Increment counter
        iter += 1

        stuff = funeval(coefs, bs, [0 0 0 0; 1 0 0 0; 0 1 0 0; 0 0 1 0])
        J_all    = stuff[:, 1, 1]
        dJk1_all = stuff[:, 1, 2]
        dJk2_all = stuff[:, 1, 3]
        dJU_all  = stuff[:, 1, 4]

        # function to solve state i
        function ssi(i)
            # prep function for nlsolve
            guess = prev_soln(i)
            resid = similar(guess)
            state = bcfl.ss.grid_transpose[:, i]
            J = J_all[i]
            dJk1 = dJk1_all[i]
            dJk2 = dJk2_all[i]
            dJU = dJU_all[i]
            gp = bcfl.gp[:, i]
            ξp = bcfl.ss.exog[1].gridp[:, i]


            # TODO: performance will probably be significantly better if we can outsourse
            #       most of the guts of compute_residuals! elsewhere. Othwerwise we
            #       will be recompiling all the guts for every i on every iteration :yuck:
            function f!(x, fvec)
                 compute_residuals!(bcfl, state, J, dJU, dJk1, dJk2, coefs, gp,
                                    ξp, x, fvec)
            end

            # lb = [-state[1], -state[2], 0., 0., 0., 0.]
            # ub = [Inf, Inf, Inf, Inf, Inf, Inf]
            soln = nlsolve(f!, guess, factor=.025)

            if maxabs(soln.initial_x - guess) > 1e-12
                println("Sebastian changed our guess on state $i")
            end

            # now call the function one more time to get c1, c2, J. Use
            # the already allocated guess vector as the resid buffer that will
            # be changed but ignored by us
            out = SolutionForState(f!(soln.zero, guess)..., soln)

            if soln.f_converged
                print("  $i converged.")
            else
                println("\n$i failed. residual norm: $(soln.residual_norm)")
            end
            return out
        end

        # if iter == 1
        #     all_sfs = jldopen(result_fn, "r+") do f
        #         read(f, "all_sfs_1")
        #     end
        # else

            all_sfs = pmap(ssi, 1:size(bcfl.ss.grid, 1))
            jldopen(result_fn, "r+") do f
                write(f, "all_sfs_$iter", all_sfs)
            end
        # end

        prev_soln(i::Int) = all_sfs[i].result.zero

        new_J = Float64[s.J for s in all_sfs]
        dist = maxabs(J_all - new_J)

        println("Hallelujah! Finished iteration $iter. dist: $dist")

        # Update coefficients
        coefs = CompEcon.get_coefs(bcfl.ss.basis, bs, new_J)
    end

    all_sfs
end

end  # module

# include("common.jl")
# addprocs(3)
# @everywhere include("common.jl")
# bcfl = TwoAgents.BCFL21();
# out = TwoAgents.brutal_solution(bcfl; maxiter=2)

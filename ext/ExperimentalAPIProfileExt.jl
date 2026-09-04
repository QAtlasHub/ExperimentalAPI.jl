# Where `record`'s inclusive/exclusive time comes from.
#
# Sampling, because the alternative is wrapping the call, and the one statement `@experimental`
# puts in a body may not do that — the measurement that settled it is in `test/spec/README.md`.
# `Profile` is Julia's own sampler and a stdlib, but `ExperimentalAPI` is loaded at run time by
# every marked package, so it stays out of the load path until somebody asks for timing.

module ExperimentalAPIProfileExt

using ExperimentalAPI:
    ExperimentalAPI, Attribution, TimingBackend, isexperimental, mark, marked_modules
using Profile: Profile

struct ProfileTiming <: TimingBackend end

# The sampler's default is one sample per millisecond, which is nothing at all for the runs worth
# recording — a marked kernel called ten thousand times can finish inside two of them. Finer while
# a recording is open, and put back afterwards: it is global state somebody else may be using.
const _DELAY = 1e-4
const _SAVED = Ref{Any}(nothing)

function ExperimentalAPI.start_timing!(::ProfileTiming; clear::Bool=true)
    try
        if clear
            _SAVED[] = Profile.init()
            n, _ = _SAVED[]
            Profile.init(; n, delay=_DELAY)
            Profile.clear()
        else
            # The caller is already using the buffer. `Profile.init` reallocates it, so setting
            # the delay here would throw their samples away — which is the one thing
            # `with_profile = true` exists to prevent. Their sampling rate stands.
            _SAVED[] = nothing
        end
        Profile.start_timer()
        return true
    catch
        return false
    end
end

function ExperimentalAPI.stop_timing!(::ProfileTiming)
    try
        Profile.stop_timer()
    catch
    end
    return nothing
end

# The saved settings are restored HERE and not in `stop_timing!`, because `Profile.init`
# reallocates the buffer: restoring the delay before reading the samples throws the run's own
# measurement away, and the symptom is a fraction of exactly zero rather than an error.
function ExperimentalAPI.attribute_timing(::ProfileTiming)
    out = try
        _fractions(Profile.fetch(; include_meta=false))
    catch
        nothing
    end
    try
        s = _SAVED[]
        s === nothing || Profile.init(; n=s[1], delay=s[2])
    catch
    end
    return out
end

function ExperimentalAPI.attribute(::ProfileTiming, data)
    d = _stacks(data)
    total = length(d)
    out = Attribution[]
    total == 0 && return out
    counts = Dict{Tuple{Module,Symbol},Vector{Int}}()
    reasons = Dict{Tuple{Module,Symbol},String}()
    idx = _mark_index()
    for stack in d
        _tally!(counts, reasons, stack, idx)
    end
    for (k, v) in counts
        push!(out, Attribution(k[1], k[2], reasons[k], v[1], v[1] / total, v[2] / total))
    end
    return sort!(out; by=a -> (-a.inclusive, string(a.mod), string(a.name)))
end

function _fractions(data)
    stacks = _stacks(data)
    total = length(stacks)
    out = Dict{Tuple{Module,Symbol},Tuple{Float64,Float64}}()
    total == 0 && return out
    counts = Dict{Tuple{Module,Symbol},Vector{Int}}()
    reasons = Dict{Tuple{Module,Symbol},String}()
    idx = _mark_index()
    for stack in stacks
        _tally!(counts, reasons, stack, idx)
    end
    for (k, v) in counts
        out[k] = (v[1] / total, v[2] / total)
    end
    return out
end

# One sample's frames, innermost first, with C frames dropped. `Profile`'s buffer separates
# samples with a zero and stores each one leaf first.
function _stacks(data)
    lidict = Profile.getdict(data)
    out = Vector{Vector{Any}}()
    current = Any[]
    for ip in data
        if ip == 0
            isempty(current) || push!(out, current)
            current = Any[]
            continue
        end
        frames = get(lidict, ip, nothing)
        frames === nothing && continue
        for fr in frames
            fr.from_c && continue
            push!(current, fr)
        end
    end
    isempty(current) || push!(out, current)
    return out
end

# `counts[key] = [inclusive, exclusive]`. A definition is counted inclusively once per sample it
# appears in, however many frames deep, and exclusively only when it is the innermost Julia frame.
function _tally!(counts, reasons, stack, idx)
    seen = Set{Tuple{Module,Symbol}}()
    for (i, fr) in enumerate(stack)
        mk = _mark_of(fr, idx)
        mk === nothing && continue
        k = (mk.mod, mk.name)
        v = get!(counts, k, [0, 0])
        reasons[k] = mk.reason
        if !(k in seen)
            push!(seen, k)
            v[1] += 1
        end
        i == 1 && (v[2] += 1)
    end
    return nothing
end

# A marked definition small enough to be worth marking is small enough to be inlined, and an
# inlined frame carries no `MethodInstance` at all — so the `linfo` route, which is the exact one,
# answers `nothing` for exactly the frames that matter most. The index is the fallback: every
# mark that resolves to a method, keyed by the file and function name a frame does carry.
function _mark_of(fr, idx)
    li = fr.linfo
    li isa Core.CodeInstance && (li = li.def)
    if li isa Core.MethodInstance && li.def isa Method
        mk = mark(li.def)
        mk === nothing || return mk
    end
    return get(idx, (fr.file, fr.func), nothing)
end

function _mark_index()
    idx = Dict{Tuple{Symbol,Symbol},Any}()
    for mod in marked_modules()
        for mk in ExperimentalAPI.experimental(mod)
            mk.sig === nothing && continue
            m = try
                which(mk.sig)
            catch
                nothing
            end
            m === nothing && continue
            idx[(m.file, m.name)] = mk
        end
    end
    return idx
end

function __init__()
    ExperimentalAPI._TIMING[] = ProfileTiming()
    return nothing
end

end # module

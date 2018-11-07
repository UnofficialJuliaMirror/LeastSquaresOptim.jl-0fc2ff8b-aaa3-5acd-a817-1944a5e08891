## LSMR works on any matrix with the following methods:
## eltype, size, mul!
## LSMR works on any vector with the following methods:
## eltype, length, rmul!, norm

#############################################################################
## 
## Define preconditioned matrix
##
#############################################################################

struct PreconditionedMatrix{TA, Tp, Tx}
    A::TA
    preconditioner::Tp
    tmp::Tx
    tmp2::Tx
end
eltype(A::PreconditionedMatrix) = eltype(A.A)
size(A::PreconditionedMatrix, i::Integer) = size(A.A, i)

Base.adjoint(M::PreconditionedMatrix) = Adjoint(M)

function mul!(b, pm::PreconditionedMatrix{TA, Tp, Tx}, a, α::Number, β::Number) where {TA, Tp, Tx}
    ldiv!(a, pm.preconditioner, pm.tmp)
    mul!(b, pm.A, pm.tmp, α, β)
    return b
end

function mul!(b, Cpm::Adjoint{Ta, PreconditionedMatrix{TA, Tp, Tx}}, a, α::Number, β::Number) where {Ta, TA, Tp, Tx}
    pm = adjoint(Cpm)
    T = eltype(b)
    β = convert(T, β)
    mul!(pm.tmp, pm.A',  a, one(T), zero(T))
    ldiv!(pm.tmp, pm.preconditioner, pm.tmp2)
    if β != one(T)
        if β == zero(T)
            fill!(b, β)
        else
            rmul!(b, β)
        end
    end
    axpy!(α, pm.tmp2, b)
    return b
end


#############################################################################
## 
## Define dampened matrix
##
#############################################################################


struct DampenedVector{Ty, Tx}
    y::Ty # dimension of f(x)
    x::Tx # dimension of x
end
eltype(a::DampenedVector) =  promote_type(eltype(a.y), eltype(a.x))
length(a::DampenedVector) = length(a.y) + length(a.x)
function rmul!(a::DampenedVector, α::Number)
    rmul!(a.y, α)
    rmul!(a.x, α)
    return a
end
norm(a::DampenedVector) = sqrt(norm(a.y)^2 + norm(a.x)^2)

struct DampenedMatrix{TA, Tx}
    A::TA
    diagonal::Tx 
end
eltype(A::DampenedMatrix) = promote_type(eltype(A.A), eltype(A.diagonal))
function size(A::DampenedMatrix, dim::Integer)
    m, n = size(A.A)
    l = length(A.diagonal)
    dim == 1 ? (m + l) : 
    dim == 2 ? n : 1
end
Base.adjoint(M::DampenedMatrix) = Adjoint(M)

function mul!(b::DampenedVector, mw::DampenedMatrix, a, α::Number, β::Number)
    if β != 1
        rmul!(b, β)
    end
    mul!(b.y, mw.A, a, α, 1.0)
    map!((z, x, y)-> z + α * x * y, b.x, b.x, a, mw.diagonal)
    return b
end
function mul!(b, Cmw::Adjoint{Ta, DampenedMatrix{TA, Tx}}, a::DampenedVector, α::Number, β::Number) where {Ta, TA, Tx}
    mw = adjoint(Cmw)
    T = eltype(b)
    β = convert(T, β)
    if β != one(T)
        if β == zero(T)
            fill!(b, β)
        else
            rmul!(b, β)
        end
    end
    mul!(b, mw.A', a.y, α, one(T))
    map!((z, x, y)-> z + α * x * y, b, b, a.x, mw.diagonal)
    return b
end

#############################################################################
## 
## Define inverse preconditioner
##
##############################################################################

struct InverseDiagonal{Tx}
    _::Tx
end
function ldiv!(x, ID::InverseDiagonal, y)
    map!(*, y, x, ID._)
end

#############################################################################
## 
## solve J'J \ J'y
##
## we use LSMR on Ax = y
## with A = J / sqrt(diag(J'J)) (diagonal preconditioner)
##
## LSMR works on any matrix with the following methods:
## eltype, size, mul!
##
##############################################################################
function getpreconditioner(nls::LeastSquaresProblem, optimizer::Dogleg{LSMR{Nothing, Nothing}})
    preconditioner! = function(x, J, out)
        colsumabs2!(out._, J)
        Tout = eltype(out._)
        map!(x -> x > zero(Tout) ? 1 / sqrt(x) : zero(Tout), out._, out._)
        return out
    end
    preconditioner = InverseDiagonal(_zeros(nls.x))
    return preconditioner!, preconditioner
end
function getpreconditioner(nls::LeastSquaresProblem, optimizer::Dogleg{LSMR{T1, T2}}) where {T1, T2}
    return optimizer.solver.preconditioner!, optimizer.solver.preconditioner
end

struct LSMRAllocatedSolver{Tx0, Tx1, Tx2, Tx22, Tx3, Tx4, Tx5, Ty} <: AbstractAllocatedSolver
    preconditioner!::Tx0
    preconditioner::Tx1
    tmp::Tx2
    tmp2::Tx22
    v::Tx3
    h::Tx4
    hbar::Tx5
    u::Ty
end


function AbstractAllocatedSolver(nls::LeastSquaresProblem, optimizer::Dogleg{LSMR{T1, T2}}) where {T1, T2}
    preconditioner!, preconditioner = getpreconditioner(nls, optimizer)
    LSMRAllocatedSolver(preconditioner!, preconditioner, _zeros(nls.x), _zeros(nls.x), 
        _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), _zeros(nls.y))
end

function ldiv!(x, J, y, A::LSMRAllocatedSolver)
    preconditioner!, preconditioner, tmp, tmp2, v, h, hbar, u = A.preconditioner!, A.preconditioner, A.tmp, A.tmp2, A.v, A.h, A.hbar, A.u

    # prepare x
    fill!(x, 0)

    # prepare b
    copyto!(u, y)

    # prepare A
    fill!(tmp, 0)
    preconditioner!(x, J, preconditioner)
    A = PreconditionedMatrix(J, preconditioner, tmp, tmp2)

    # solve
    x, ch = lsmr!(x, A, u, v, h, hbar)
    ldiv!(x, preconditioner, tmp)
    copyto!(x, tmp)
    return x, ch.mvps
end

##############################################################################
## 
## solve (J'J + diagm(damp)) \ J'y (used in LevenbergMarquardt)
## No need to solve exactly :
## "An Inexact Levenberg-Marquardt Method for Large Sparse Nonlinear Least Squares"
## Weight Holt (1985)
##
## We use LSMR on A x = b with
## A = |J          |  + diagonal preconditioner
##     |diag(damp) |
## b = vcat(y, zeros(damp))
##

##
##############################################################################
function getpreconditioner(nls::LeastSquaresProblem, optimizer::LevenbergMarquardt{LSMR{Nothing, Nothing}})
    preconditioner! = function(x, J, damp, out)
        colsumabs2!(out._, J)
        Tout = eltype(out._)
        axpy!(one(Tout), damp, out._)
        map!(x -> x > zero(Tout) ? 1 / sqrt(x) : zero(Tout), out._, out._)
        return out
    end
    preconditioner = InverseDiagonal(_zeros(nls.x))
    return preconditioner!, preconditioner
end

function getpreconditioner(nls::LeastSquaresProblem, optimizer::LevenbergMarquardt{LSMR{T1, T2}}) where {T1, T2}
    return optimizer.solver.preconditioner!, optimizer.solver.preconditioner
end


struct LSMRDampenedAllocatedSolver{Tx0, Tx1, Tx2, Tx22, Tx3, Tx4, Tx5, Tx6, Ty} <: AbstractAllocatedSolver
    preconditioner!::Tx0
    preconditioner::Tx1
    tmp::Tx2
    tmp2::Tx22
    v::Tx3
    h::Tx4
    hbar::Tx5
    zerosvector::Tx6
    u::Ty
end

function AbstractAllocatedSolver(nls::LeastSquaresProblem,  optimizer::LevenbergMarquardt{LSMR{T1, T2}}) where {T1, T2}
    preconditioner!, preconditioner = getpreconditioner(nls, optimizer)
    LSMRDampenedAllocatedSolver(preconditioner!, preconditioner, _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), _zeros(nls.x), _zeros(nls.x),  _zeros(nls.x), _zeros(nls.y))
end

function ldiv!(x, J, y, damp, A::LSMRDampenedAllocatedSolver)
    preconditioner!, preconditioner, tmp, tmp2, v, h, hbar, zerosvector, u = 
            A.preconditioner!, A.preconditioner, A.tmp, A.tmp2, A.v, A.h, A.hbar, A.zerosvector, A.u
    # prepare x
    fill!(x, 0)

    # prepare b
    copyto!(u, y)
    fill!(zerosvector, 0)
    b = DampenedVector(u, zerosvector)

    # prepare A
    fill!(tmp, 0)
    preconditioner!(x, J, damp, preconditioner)
    map!(sqrt, damp, damp)
    A = PreconditionedMatrix(DampenedMatrix(J, damp), preconditioner, tmp, tmp2)
    # solve
    x, ch = lsmr!(x, A, b, v, h, hbar, btol = 0.5)
    ldiv!(x, preconditioner, tmp)
    copyto!(x, tmp)
    return x, ch.mvps
end
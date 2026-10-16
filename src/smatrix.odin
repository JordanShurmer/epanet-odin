package epanet

import "base:intrinsics"

// smatrix.odin — the sparse symmetric linear solver (EPANET's smatrix.c).
//
// The matrix is kept the way George & Liu's "Computer Solution of Large
// Sparse Positive Definite Systems" (1981) keeps it, and the way EPANET does:
// the diagonal in one array, the strictly-lower-triangular nonzeros in
// another, column by column, with three index arrays saying where each
// nonzero is. Everything is 1-based — slot 0 of every array is unused —
// because 0 doubles as the "none" sentinel in the link chains, and because
// EPANET's arrays arrive that way and a rewrite that matches it bit for bit
// is a rewrite that can be checked.

// Smatrix is the coefficient matrix A of a system A·x = f, n rows.
//
//   aii[j]       diagonal, j = 1..n          (becomes the diagonal of L)
//   aij[k]       off-diagonal, k = 1..ncoeffs (becomes L below the diagonal)
//   xlnz[j]      first slot of column j in nzsub and lnz; xlnz[n+1] ends it
//   nzsub[s]     row index of the s-th stored nonzero
//   lnz[s]       where that nonzero lives in aij
//   f[j]         right-hand side on the way in, solution on the way out
//   temp, link, first    scratch, n+1 long, zeroed by linsolve
Smatrix :: struct {
	aii, aij, f, temp:             []f64,
	xlnz, nzsub, lnz, link, first: []i32,
}

// linsolve factorizes A = L·Lᵀ in place (Cholesky) and solves for x,
// leaving it in f. Returns 0, or the column whose pivot was not positive:
// the matrix is not positive definite, which in a water network means a
// control valve that cannot hold its setting.
//
// The column-by-column scheme: link[k] chains the columns whose next
// unused entry falls in row j, first[k] says which entry that is, and
// temp accumulates column j's modifications before they are applied.
linsolve :: proc "contextless" (m: ^Smatrix, n: int) -> int {
	aii, aij, b, temp := m.aii, m.aij, m.f, m.temp
	xlnz, nzsub, lnz, link, first := m.xlnz, m.nzsub, m.lnz, m.link, m.first

	for i in 0 ..= n {
		temp[i] = 0
		link[i] = 0
		first[i] = 0
	}

	// Numeric factorization: compute column L(*,j) for j = 1..n.
	for j in 1 ..= n {
		diagj := 0.0
		k := int(link[j])
		for k != 0 {
			// Outer-product modification of L(*,j) by L(*,k),
			// starting at entry first[k] of column k.
			newk := int(link[k])
			kfirst := int(first[k])
			ljk := aij[lnz[kfirst]]
			diagj += ljk * ljk
			istrt := kfirst + 1
			istop := int(xlnz[k + 1]) - 1
			if istop >= istrt {
				// Chain column k on to the row of its next entry.
				first[k] = i32(istrt)
				isub := int(nzsub[istrt])
				link[k] = link[isub]
				link[isub] = i32(k)
				for i in istrt ..= istop {
					isub = int(nzsub[i])
					temp[isub] += aij[lnz[i]] * ljk
				}
			}
			k = newk
		}

		// Apply what temp accumulated to column j.
		diagj = aii[j] - diagj
		if diagj <= 0 {
			return j
		}
		diagj = intrinsics.sqrt(diagj)
		aii[j] = diagj
		istrt := int(xlnz[j])
		istop := int(xlnz[j + 1]) - 1
		if istop >= istrt {
			first[j] = i32(istrt)
			isub := int(nzsub[istrt])
			link[j] = link[isub]
			link[isub] = i32(j)
			for i in istrt ..= istop {
				isub = int(nzsub[i])
				bj := (aij[lnz[i]] - temp[isub]) / diagj
				aij[lnz[i]] = bj
				temp[isub] = 0
			}
		}
	}

	// Forward substitution: L·y = b.
	for j in 1 ..= n {
		bj := b[j] / aii[j]
		b[j] = bj
		for i in int(xlnz[j]) ..< int(xlnz[j + 1]) {
			b[nzsub[i]] -= aij[lnz[i]] * bj
		}
	}

	// Backward substitution: Lᵀ·x = y.
	for j := n; j >= 1; j -= 1 {
		bj := b[j]
		for i in int(xlnz[j]) ..< int(xlnz[j + 1]) {
			bj -= aij[lnz[i]] * b[nzsub[i]]
		}
		b[j] = bj / aii[j]
	}
	return 0
}

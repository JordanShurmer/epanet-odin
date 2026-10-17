package epanet

// export.odin — the C face of the package. Each proc here is one EPANET
// symbol, with EPANET's own argument shapes, that the bridge
// (../bridge/bridge.c) hands straight through. Nothing else in the package
// knows about C.

import "base:runtime"
import "core:c"
import "core:c/libc"

@(export, link_name = "odin_linsolve")
odin_linsolve :: proc "c" (
	n, ncoeffs: c.int,
	aii, aij, f, temp: [^]f64,
	xlnz, nzsub, lnz, link, first: [^]c.int,
) -> c.int {
	m := Smatrix {
		aii   = aii[:n + 1],
		aij   = aij[:ncoeffs + 1],
		f     = f[:n + 1],
		temp  = temp[:n + 1],
		xlnz  = xlnz[:n + 2],
		nzsub = nzsub[:ncoeffs + 2],
		lnz   = lnz[:ncoeffs + 2],
		link  = link[:n + 1],
		first = first[:n + 1],
	}
	return c.int(linsolve(&m, int(n)))
}

// odin_createsparse builds the matrix structure for a network given as
// link end-node pairs. order, row and ndx are the caller's (nnodes+1,
// nnodes+1, nlinks+1); xlnz, nzsub and lnz come back calloc'd, so C frees
// them with free().
@(export, link_name = "odin_createsparse")
odin_createsparse :: proc "c" (
	nnodes, njuncs, nlinks: c.int,
	n1, n2: [^]c.int,
	order, row, ndx: [^]c.int,
	ncoeffs: ^c.int,
	xlnz, nzsub, lnz: ^[^]c.int,
) {
	context = runtime.default_context()
	g := Graph {
		nnodes = int(nnodes),
		njuncs = int(njuncs),
		nlinks = int(nlinks),
		n1     = n1[:nlinks + 1],
		n2     = n2[:nlinks + 1],
	}
	sp := create_sparse(g)
	defer {
		delete(sp.order)
		delete(sp.row)
		delete(sp.ndx)
		delete(sp.xlnz)
		delete(sp.nzsub)
		delete(sp.lnz)
	}
	copy(order[:nnodes + 1], sp.order)
	copy(row[:nnodes + 1], sp.row)
	copy(ndx[:nlinks + 1], sp.ndx)
	ncoeffs^ = c.int(sp.ncoeffs)
	xlnz^ = c_ints(sp.xlnz)
	nzsub^ = c_ints(sp.nzsub)
	lnz^ = c_ints(sp.lnz)
}

// c_ints copies a slice into a calloc'd array for C to own.
c_ints :: proc(s: []i32) -> [^]c.int {
	p := ([^]c.int)(libc.calloc(len(s), size_of(c.int)))
	copy(p[:len(s)], s)
	return p
}

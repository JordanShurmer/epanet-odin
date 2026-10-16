package epanet

// export.odin — the C face of the package. Each proc here is one EPANET
// symbol, with EPANET's own argument shapes, that the bridge
// (../bridge/bridge.c) hands straight through. Nothing else in the package
// knows about C.

import "core:c"

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

package epanet

// sparse.odin — the symbolic side of the solver (EPANET's createsparse):
// decide once, from the network's shape alone, where the nonzeros of the
// Cholesky factor will be, so that linsolve can run over flat arrays.
//
//   1. adjacency lists per node, parallel links folded into one slot
//   2. a minimum-degree ordering of the junctions (genmmd)
//   3. fill-in: the extra nonzeros elimination creates, added as links
//   4. the column structure (xlnz, nzsub, lnz), rows sorted

// Graph is a network's links as node pairs. Nodes are 1..nnodes with the
// junctions first (1..njuncs; tanks and reservoirs after, and those are
// not rows of the matrix). Links are 1..nlinks.
Graph :: struct {
	nnodes, njuncs, nlinks: int,
	n1, n2:                 []i32,
}

// Sparse is what the solver needs to know about the matrix's shape.
//
//   order[i]   the node in row i;  row[node] the row of a node  (nnodes+1)
//   ndx[k]     link k's slot in aij; a parallel link shares its twin's (nlinks+1)
//   ncoeffs    off-diagonal slots: the links plus the fill-ins
//   xlnz, nzsub, lnz   column structure, as Smatrix documents
Sparse :: struct {
	order, row, ndx:  []i32,
	ncoeffs:          int,
	xlnz, nzsub, lnz: []i32,
}

// Adj is a node's adjacency as a linked list kept in arrays: head[node]
// is its first entry, entries chain through next, 0 ends a chain. New
// entries go in front, as EPANET's do, so the fill-in is visited in the
// same order and the slots come out numbered the same.
Adj :: struct {
	head:             []i32,
	node, link, next: [dynamic]i32,
}

adj_push :: proc(a: ^Adj, at: int, node, link: i32) {
	append(&a.node, node)
	append(&a.link, link)
	append(&a.next, a.head[at])
	a.head[at] = i32(len(a.node) - 1)
}

// create_sparse builds Sparse for g. The scratch it needs is freed; the
// arrays in the result are the caller's (allocator).
create_sparse :: proc(g: Graph, allocator := context.allocator) -> (sp: Sparse) {
	context.allocator = allocator
	sp.order = make([]i32, g.nnodes + 1)
	sp.row = make([]i32, g.nnodes + 1)
	sp.ndx = make([]i32, g.nlinks + 1)

	a := Adj {
		head = make([]i32, g.nnodes + 1, context.temp_allocator),
		node = make([dynamic]i32, 1, 2 * g.nlinks + 1, context.temp_allocator),
		link = make([dynamic]i32, 1, 2 * g.nlinks + 1, context.temp_allocator),
		next = make([dynamic]i32, 1, 2 * g.nlinks + 1, context.temp_allocator),
	}
	defer free_all(context.temp_allocator)

	local_adjlists(g, &a, sp.ndx)
	reorder_nodes(g, &a, sp.order, sp.row)
	sp.ncoeffs = fill_in(g, &a, sp.order)
	store_sparse(g, &a, &sp)
	sort_sparse(g.njuncs, &sp)
	return sp
}

// local_adjlists lists each node's links, skipping a link that parallels
// an earlier one (same two ends): it maps to its twin's slot in ndx and
// adds no entry, so the matrix has one coefficient for the pair.
local_adjlists :: proc(g: Graph, a: ^Adj, ndx: []i32) {
	for k in 1 ..= g.nlinks {
		i, j := g.n1[k], g.n2[k]
		twin := i32(0)
		for e := a.head[i]; e != 0; e = a.next[e] {
			if a.node[e] == j {
				twin = a.link[e]
				break
			}
		}
		if twin != 0 {
			ndx[k] = twin
			continue
		}
		ndx[k] = i32(k)
		adj_push(a, int(i), j, i32(k))
		adj_push(a, int(j), i, i32(k))
	}
}

// reorder_nodes numbers the junctions by minimum degree; tanks keep their
// own index, since they are not rows of the matrix.
reorder_nodes :: proc(g: Graph, a: ^Adj, order, row: []i32) {
	for k in 1 ..= g.nnodes {
		row[k] = i32(k)
		order[k] = i32(k)
	}
	n := g.njuncs
	xadj := make([]i32, n + 2, context.temp_allocator)
	adjncy := make([]i32, 2 * g.nlinks + 1, context.temp_allocator)
	scratch := make([]i32, 4 * (n + 1), context.temp_allocator)
	dhead := scratch[0:n + 1]
	qsize := scratch[n + 1:2 * (n + 1)]
	llist := scratch[2 * (n + 1):3 * (n + 1)]
	marker := scratch[3 * (n + 1):4 * (n + 1)]

	// The junction subgraph as CSR, in list order.
	xadj[1] = 1
	m := 1
	for k in 1 ..= n {
		for e := a.head[k]; e != 0; e = a.next[e] {
			knode := a.node[e]
			if knode > 0 && int(knode) <= n {
				adjncy[m] = knode
				m += 1
			}
		}
		xadj[k + 1] = i32(m)
	}
	genmmd(n, xadj, adjncy, row, order, -1, dhead, qsize, llist, marker)
}

// fill_in adds, as new links numbered past nlinks, the coefficients that
// eliminating the junctions in order will create: when row k goes, every
// pair of its still-active neighbours that is not yet linked becomes one.
// Returns the total coefficient count.
//
// Whether inode and jnode are linked is read off a marker array:
// inode's neighbours are stamped once, and a new link stamps as it is
// made, instead of scanning inode's list for every jnode (EPANET's way,
// which was half the cost of opening a large network).
fill_in :: proc(g: Graph, a: ^Adj, order: []i32) -> int {
	degree := make([]i32, g.nnodes + 1, context.temp_allocator)
	for k in 1 ..= g.njuncs {
		for e := a.head[k]; e != 0; e = a.next[e] {
			if a.node[e] > 0 do degree[k] += 1
		}
	}
	mark := make([]i32, g.nnodes + 1, context.temp_allocator) // mark[j] == stamp: j is inode's neighbour
	stamp: i32
	ncoeffs := g.nlinks
	for k in 1 ..= g.njuncs {
		knode := order[k]
		for e := a.head[knode]; e != 0; e = a.next[e] {
			inode := a.node[e]
			if inode <= 0 || degree[inode] <= 0 do continue
			degree[inode] -= 1
			stamp += 1
			for n := a.head[inode]; n != 0; n = a.next[n] do mark[a.node[n]] = stamp
			// Link inode to every active neighbour listed after it.
			for f := a.next[e]; f != 0; f = a.next[f] {
				jnode := a.node[f]
				if jnode <= 0 || degree[jnode] <= 0 do continue
				if mark[jnode] == stamp do continue
				mark[jnode] = stamp
				ncoeffs += 1
				adj_push(a, int(inode), jnode, i32(ncoeffs))
				adj_push(a, int(jnode), inode, i32(ncoeffs))
				degree[inode] += 1
				degree[jnode] += 1
			}
		}
		degree[knode] = 0
	}
	return ncoeffs
}

// store_sparse writes the column structure: for column i (row i's node),
// every neighbour in a later row is a nonzero below the diagonal.
store_sparse :: proc(g: Graph, a: ^Adj, sp: ^Sparse) {
	n := g.njuncs
	sp.xlnz = make([]i32, n + 2)
	sp.nzsub = make([]i32, sp.ncoeffs + 2)
	sp.lnz = make([]i32, sp.ncoeffs + 2)
	k := 0
	sp.xlnz[1] = 1
	for i in 1 ..= n {
		m := 0
		for e := a.head[sp.order[i]]; e != 0; e = a.next[e] {
			if a.node[e] == 0 do continue
			j := int(sp.row[a.node[e]])
			if j > i && j <= n {
				m += 1
				k += 1
				sp.nzsub[k] = i32(j)
				sp.lnz[k] = a.link[e]
			}
		}
		sp.xlnz[i + 1] = sp.xlnz[i] + i32(m)
	}
}

// sort_sparse puts each column's row indexes in ascending order, which
// linsolve's column chaining needs: transposing twice sorts.
sort_sparse :: proc(n: int, sp: ^Sparse) {
	xlnzt := make([]i32, n + 2, context.temp_allocator)
	nzsubt := make([]i32, sp.ncoeffs + 2, context.temp_allocator)
	lnzt := make([]i32, sp.ncoeffs + 2, context.temp_allocator)
	nzt := make([]i32, n + 2, context.temp_allocator)

	for i in 1 ..= n {
		for k in sp.xlnz[i] ..< sp.xlnz[i + 1] do nzt[sp.nzsub[k]] += 1
	}
	xlnzt[1] = 1
	for i in 1 ..= n do xlnzt[i + 1] = xlnzt[i] + nzt[i]

	transpose(n, sp.xlnz, sp.nzsub, sp.lnz, xlnzt, nzsubt, lnzt, nzt)
	transpose(n, xlnzt, nzsubt, lnzt, sp.xlnz, sp.nzsub, sp.lnz, nzt)
}

transpose :: proc "contextless" (n: int, il, jl, xl, ilt, jlt, xlt, nzt: []i32) {
	for i in 1 ..= n do nzt[i] = 0
	for i in 1 ..= n {
		for k in il[i] ..< il[i + 1] {
			j := jl[k]
			kk := ilt[j] + nzt[j]
			jlt[kk] = i32(i)
			xlt[kk] = xl[k]
			nzt[j] += 1
		}
	}
}

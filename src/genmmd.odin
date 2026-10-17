package epanet

// genmmd.odin — Liu's multiple minimum external degree ordering
// (EPANET's genmmd.c, an f2c translation of SPARSPAK's GENMMD).
//
// Given a graph as 1-based CSR (xadj, adjncy), find a permutation of its
// nodes that keeps the Cholesky factor sparse. The quotient-graph trick:
// an eliminated node becomes an "element" stored in place in adjncy, and
// a negative entry -e in a node's list means "continue in element e's
// list". adjncy is destroyed.
//
// The structure is the Fortran's, loop for loop, so that the ordering —
// and so every rounding in the factorization — is the one EPANET gets.
// A `chain:` loop is the Fortran's "goto L400 with a new LINK".

// genmmd fills perm (the ordering: perm[i] = the node in row i) and invp
// (its inverse) and returns nofsub, an upper bound on the subscripts the
// factor needs. delta < 0 means single elimination; dhead, qsize, llist
// and marker are scratch, neqns+1 long.
genmmd :: proc "contextless" (
	neqns: int,
	xadj, adjncy, invp, perm: []i32,
	delta: int,
	dhead, qsize, llist, marker: []i32,
) -> (nofsub: int) {
	MAXINT :: max(i32)
	if neqns <= 0 do return 0

	// dforw and dbakw are the Fortran's names for invp and perm while
	// they hold the degree lists.
	dforw, dbakw := invp, perm
	mmdint(neqns, xadj, dhead, dforw, dbakw, qsize, llist, marker)

	num := 1 // ordered nodes + 1

	// Isolated nodes go first.
	nextmd := dhead[1]
	for nextmd > 0 {
		mdnode := nextmd
		nextmd = invp[mdnode]
		marker[mdnode] = MAXINT
		invp[mdnode] = i32(-num)
		num += 1
	}

	tag := i32(1)
	mdeg := 2
	done := num > neqns
	if !done do dhead[1] = 0
	for !done {
		// The node of minimum degree.
		for dhead[mdeg] <= 0 do mdeg += 1
		mdlmt := mdeg + delta // degrees up to here eliminate in one pass
		ehead := i32(0)       // list of the elements formed in this pass

		pass: for {
			mdnode := dhead[mdeg]
			if mdnode <= 0 {
				mdeg += 1
				if mdeg > mdlmt do break pass
				continue pass
			}
			// Take mdnode off the degree structure.
			nextmd = invp[mdnode]
			dhead[mdeg] = nextmd
			if nextmd > 0 do perm[nextmd] = i32(-mdeg)
			invp[mdnode] = i32(-num)
			nofsub += mdeg + int(qsize[mdnode]) - 2
			if num + int(qsize[mdnode]) > neqns {
				done = true
				break pass
			}
			// Eliminate it; reset the tags when they would overflow.
			tag += 1
			if tag >= MAXINT {
				tag = 1
				for i in 1 ..= neqns do if marker[i] < MAXINT do marker[i] = 0
			}
			mmdelm(int(mdnode), xadj, adjncy, dhead, dforw, dbakw, qsize, llist, marker, tag)
			num += int(qsize[mdnode])
			llist[mdnode] = ehead
			ehead = mdnode
			if delta < 0 do break pass
		}
		if done do break
		if num > neqns do break
		mmdupd(ehead, neqns, xadj, adjncy, delta, &mdeg, dhead, dforw, dbakw, qsize, llist, marker, &tag)
	}
	mmdnum(neqns, perm, invp, qsize)
	return nofsub
}

// mmdint builds the degree doubly-linked lists: dhead[d] heads the list
// of nodes with degree d, dforw/dbakw chain it, and a node's dbakw holds
// -d when it is first in its list.
mmdint :: proc "contextless" (neqns: int, xadj, dhead, dforw, dbakw, qsize, llist, marker: []i32) {
	for node in 1 ..= neqns {
		dhead[node] = 0
		qsize[node] = 1
		marker[node] = 0
		llist[node] = 0
	}
	for node in 1 ..= neqns {
		ndeg := int(xadj[node + 1] - xadj[node] + 1)
		fnode := dhead[ndeg]
		dforw[node] = fnode
		dhead[ndeg] = i32(node)
		if fnode > 0 do dbakw[fnode] = i32(node)
		dbakw[node] = i32(-ndeg)
	}
}

// mmdelm eliminates mdnode: gathers its reachable set into its own list
// (borrowing storage from the elements it absorbs), then for every node
// reached, drops it from the degree lists, purges its dead neighbours and
// either merges it into mdnode (no live neighbours left) or flags it for a
// degree update.
mmdelm :: proc "contextless" (
	mdnode: int,
	xadj, adjncy, dhead, dforw, dbakw, qsize, llist, marker: []i32,
	tag: i32,
) {
	MAXINT :: max(i32)
	marker[mdnode] = tag
	istrt := int(xadj[mdnode])
	istop := int(xadj[mdnode + 1]) - 1

	// elmnt heads the list of eliminated neighbours; rloc is where the
	// next reachable node goes.
	elmnt := i32(0)
	rloc := istrt
	rlmt := istop
	for i in istrt ..= istop {
		nabor := adjncy[i]
		if nabor == 0 do break
		if marker[nabor] >= tag do continue
		marker[nabor] = tag
		if dforw[nabor] < 0 {
			llist[nabor] = elmnt
			elmnt = nabor
		} else {
			adjncy[rloc] = nabor
			rloc += 1
		}
	}

	// Merge in the nodes reachable through those elements.
	for elmnt > 0 {
		adjncy[rlmt] = -elmnt
		link := int(elmnt)
		chain: for {
			jstrt := int(xadj[link])
			jstop := int(xadj[link + 1]) - 1
			for j in jstrt ..= jstop {
				node := adjncy[j]
				if node < 0 {
					link = int(-node)
					continue chain
				}
				if node == 0 do break chain
				if marker[node] >= tag || dforw[node] < 0 do continue
				marker[node] = tag
				// Use an absorbed element's storage when mdnode's is full.
				for rloc >= rlmt {
					store := int(-adjncy[rlmt])
					rloc = int(xadj[store])
					rlmt = int(xadj[store + 1]) - 1
				}
				adjncy[rloc] = node
				rloc += 1
			}
			break chain
		}
		elmnt = llist[elmnt]
	}
	if rloc <= rlmt do adjncy[rloc] = 0

	// For each node in the reachable set…
	link := mdnode
	reach: for {
		istrt = int(xadj[link])
		istop = int(xadj[link + 1]) - 1
		for i in istrt ..= istop {
			rnode := adjncy[i]
			if rnode < 0 {
				link = int(-rnode)
				continue reach
			}
			if rnode == 0 do break reach

			// …take it out of the degree structure…
			pvnode := dbakw[rnode]
			if !(pvnode == 0 || pvnode == -MAXINT) {
				nxnode := dforw[rnode]
				if nxnode > 0 do dbakw[nxnode] = pvnode
				if pvnode > 0 do dforw[pvnode] = nxnode
				if pvnode < 0 do dhead[-pvnode] = nxnode
			}

			// …purge its inactive quotient neighbours…
			jstrt := int(xadj[rnode])
			jstop := int(xadj[rnode + 1]) - 1
			xqnbr := jstrt
			for j in jstrt ..= jstop {
				nabor := adjncy[j]
				if nabor == 0 do break
				if marker[nabor] >= tag do continue
				adjncy[xqnbr] = nabor
				xqnbr += 1
			}

			// …and merge it with mdnode, or flag it for a degree update.
			nqnbrs := xqnbr - jstrt
			if nqnbrs <= 0 {
				qsize[mdnode] += qsize[rnode]
				qsize[rnode] = 0
				marker[rnode] = MAXINT
				dforw[rnode] = i32(-mdnode)
				dbakw[rnode] = -MAXINT
			} else {
				dforw[rnode] = i32(nqnbrs + 1)
				dbakw[rnode] = 0
				adjncy[xqnbr] = i32(mdnode)
				xqnbr += 1
				if xqnbr <= jstop do adjncy[xqnbr] = 0
			}
		}
		break reach
	}
}

// mmdupd recomputes the external degree of every node touched by the
// elements formed in the last pass (the ehead list), treating a node with
// exactly two element neighbours (the q2 list) by the cheaper route and
// merging indistinguishable nodes into supernodes as it goes.
mmdupd :: proc "contextless" (
	ehead: i32,
	neqns: int,
	xadj, adjncy: []i32,
	delta: int,
	mdeg: ^int,
	dhead, dforw, dbakw, qsize, llist, marker: []i32,
	tag: ^i32,
) {
	MAXINT :: max(i32)
	mdeg0 := mdeg^ + delta
	elmnt := ehead
	for elmnt > 0 {
		mtag := tag^ + i32(mdeg0)
		if mtag >= MAXINT {
			tag^ = 1
			for i in 1 ..= neqns do if marker[i] < MAXINT do marker[i] = 0
			mtag = tag^ + i32(mdeg0)
		}

		// Split the element's nodes into those with two neighbours (q2)
		// and the rest (qx); deg0 is the element's size.
		q2head, qxhead := i32(0), i32(0)
		deg0 := i32(0)
		link := int(elmnt)
		chain: for {
			istrt := int(xadj[link])
			istop := int(xadj[link + 1]) - 1
			for i in istrt ..= istop {
				enode := adjncy[i]
				if enode < 0 {
					link = int(-enode)
					continue chain
				}
				if enode == 0 do break chain
				if qsize[enode] == 0 do continue
				deg0 += qsize[enode]
				marker[enode] = mtag
				if dbakw[enode] != 0 do continue
				if dforw[enode] == 2 {
					llist[enode] = q2head
					q2head = enode
				} else {
					llist[enode] = qxhead
					qxhead = enode
				}
			}
			break chain
		}

		// The q2 list: the other element neighbour gives the degree.
		for enode := q2head; enode > 0; enode = llist[enode] {
			if dbakw[enode] != 0 do continue
			tag^ += 1
			deg := deg0
			istrt := int(xadj[enode])
			nabor := adjncy[istrt]
			if nabor == elmnt do nabor = adjncy[istrt + 1]
			if dforw[nabor] >= 0 {
				deg += qsize[nabor]
			} else {
				link = int(nabor)
				other: for {
					istrt = int(xadj[link])
					istop := int(xadj[link + 1]) - 1
					for i in istrt ..= istop {
						node := adjncy[i]
						if node == enode do continue
						if node < 0 {
							link = int(-node)
							continue other
						}
						if node == 0 do break other
						if qsize[node] == 0 do continue
						if marker[node] < tag^ {
							marker[node] = tag^
							deg += qsize[node]
							continue
						}
						if dbakw[node] != 0 do continue
						if dforw[node] == 2 {
							// Indistinguishable from enode: one supernode.
							qsize[enode] += qsize[node]
							qsize[node] = 0
							marker[node] = MAXINT
							dforw[node] = -enode
							dbakw[node] = -MAXINT
						} else if dbakw[node] == 0 {
							// Outmatched by enode.
							dbakw[node] = -MAXINT
						}
					}
					break other
				}
			}
			mmd_setdeg(enode, deg, mdeg, dhead, dforw, dbakw, qsize)
		}

		// The qx list: count every unmarked neighbour, through elements.
		for enode := qxhead; enode > 0; enode = llist[enode] {
			if dbakw[enode] != 0 do continue
			tag^ += 1
			deg := deg0
			istrt := int(xadj[enode])
			istop := int(xadj[enode + 1]) - 1
			for i in istrt ..= istop {
				nabor := adjncy[i]
				if nabor == 0 do break
				if marker[nabor] >= tag^ do continue
				marker[nabor] = tag^
				if dforw[nabor] >= 0 {
					deg += qsize[nabor]
					continue
				}
				link = int(nabor)
				elem: for {
					jstrt := int(xadj[link])
					jstop := int(xadj[link + 1]) - 1
					for j in jstrt ..= jstop {
						node := adjncy[j]
						if node < 0 {
							link = int(-node)
							continue elem
						}
						if node == 0 do break elem
						if marker[node] >= tag^ do continue
						marker[node] = tag^
						deg += qsize[node]
					}
					break elem
				}
			}
			mmd_setdeg(enode, deg, mdeg, dhead, dforw, dbakw, qsize)
		}

		tag^ = mtag
		elmnt = llist[elmnt]
	}
}

// mmd_setdeg files enode under its new external degree and lowers the
// running minimum if it beat it.
mmd_setdeg :: proc "contextless" (enode: i32, deg0: i32, mdeg: ^int, dhead, dforw, dbakw, qsize: []i32) {
	deg := deg0 - qsize[enode] + 1
	fnode := dhead[deg]
	dforw[enode] = fnode
	dbakw[enode] = -deg
	if fnode > 0 do dbakw[fnode] = enode
	dhead[deg] = enode
	if int(deg) < mdeg^ do mdeg^ = int(deg)
}

// mmdnum turns the elimination record into perm and invp: a merged node
// is numbered right after the root of the supernode it was merged into.
mmdnum :: proc "contextless" (neqns: int, perm, invp, qsize: []i32) {
	for node in 1 ..= neqns {
		perm[node] = qsize[node] <= 0 ? invp[node] : -invp[node]
	}
	for node in 1 ..= neqns {
		if perm[node] > 0 do continue
		// Walk the merge tree to a node that was not merged: the root.
		father := i32(node)
		for perm[father] <= 0 do father = -perm[father]
		root := father
		num := perm[root] + 1
		invp[node] = -num
		perm[root] = num
		// Shorten the tree for the next walk.
		father = i32(node)
		for {
			nextf := -perm[father]
			if nextf <= 0 do break
			perm[father] = -root
			father = nextf
		}
	}
	for node in 1 ..= neqns {
		num := -invp[node]
		invp[node] = num
		perm[num] = i32(node)
	}
}

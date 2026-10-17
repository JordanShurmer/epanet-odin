package epanet

// errors.odin — EPANET's error messages by code (errors.dat).

error_message :: proc "contextless" (code: int) -> string {
	switch code {
	case 0:
		return "ok"
	case 101:
		return "insufficient memory available"
	case 102:
		return "no network data available"
	case 103:
		return "hydraulic solver not opened"
	case 104:
		return "no hydraulics for water quality analysis"
	case 105:
		return "water quality solver not opened"
	case 106:
		return "no results saved to report on"
	case 107:
		return "hydraulics supplied from external file"
	case 108:
		return "cannot use external file while hydraulics solver is active"
	case 110:
		return "cannot solve network hydraulic equations"
	case 120:
		return "cannot solve water quality transport equations"
	case 200:
		return "one or more errors in input file"
	case 201:
		return "syntax error"
	case 299:
		return "invalid section keyword"
	case 202:
		return "illegal numeric value"
	case 203:
		return "undefined node"
	case 204:
		return "undefined link"
	case 205:
		return "undefined time pattern"
	case 206:
		return "undefined curve"
	case 207:
		return "attempt to control CV/GPV link"
	case 208:
		return "illegal PDA pressure limits"
	case 209:
		return "illegal node property value"
	case 211:
		return "illegal link property value"
	case 212:
		return "undefined trace node"
	case 213:
		return "invalid option value"
	case 214:
		return "too many characters in input line"
	case 215:
		return "duplicate ID label"
	case 216:
		return "reference to undefined pump"
	case 217:
		return "invalid pump energy data"
	case 219:
		return "illegal valve connection to tank node"
	case 220:
		return "illegal valve connection to another valve"
	case 221:
		return "mis-placed rule clause in rule-based control"
	case 222:
		return "same start and end nodes for link"
	case 223:
		return "not enough nodes in network"
	case 224:
		return "no tanks or reservoirs in network"
	case 225:
		return "invalid lower/upper levels for tank"
	case 226:
		return "no head curve or power rating for pump"
	case 227:
		return "invalid head curve for pump"
	case 230:
		return "nonincreasing x-values for curve"
	case 231:
		return "no data provided for curve"
	case 232:
		return "no data provided for pattern"
	case 233:
		return "network has unconnected nodes"
	case 234:
		return "network has an unconnected node with ID: "
	case 240:
		return "nonexistent source"
	case 241:
		return "nonexistent control"
	case 250:
		return "invalid format"
	case 251:
		return "invalid parameter code"
	case 252:
		return "invalid ID name"
	case 253:
		return "nonexistent demand category"
	case 254:
		return "node with no coordinates"
	case 255:
		return "invalid link vertex"
	case 257:
		return "nonexistent rule"
	case 258:
		return "nonexistent rule clause"
	case 259:
		return "attempt to delete a node that still has links connected to it"
	case 260:
		return "attempt to delete node assigned as a Trace Node"
	case 261:
		return "attempt to delete a node or link contained in a control"
	case 262:
		return "attempt to modify network structure while solver is active"
	case 263:
		return "node is not a tank"
	case 264:
		return "link is not a valve"
	case 301:
		return "identical file names"
	case 302:
		return "cannot open input file"
	case 303:
		return "cannot open report file"
	case 304:
		return "cannot open binary output file"
	case 305:
		return "cannot open hydraulics file"
	case 306:
		return "hydraulics file does not match network data"
	case 307:
		return "cannot read hydraulics file"
	case 308:
		return "cannot save results to file"
	case 309:
		return "cannot save results to report file"
	}
	return ""
}

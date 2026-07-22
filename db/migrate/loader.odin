package migrate

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

@(private) UP_SUFFIX :: ".up.sql"
@(private) DOWN_SUFFIX :: ".down.sql"
@(private) NO_TX_DIRECTIVE :: "uruquim:no_transaction"

// load reads and validates every migration in dir. It parses ids and names,
// orders by id, rejects duplicate ids and bad filenames, attaches down files,
// detects the no_transaction directive and computes each SHA-256 checksum. It
// touches no database. Returned strings are allocated in `allocator`.
load :: proc(dir: string, allocator := context.allocator, loc := #caller_location) -> ([]Migration, Error) {
	handle, oerr := os.open(dir)
	if oerr != nil {
		return nil, mig_err(.Load_Failed, 0, "cannot open migrations directory", loc)
	}
	defer os.close(handle)
	infos, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil {
		return nil, mig_err(.Load_Failed, 0, "cannot read migrations directory", loc)
	}

	// Index down files by their shared base so up files can attach them.
	downs := make(map[string]string, context.temp_allocator)
	for info in infos {
		if !strings.has_suffix(info.name, DOWN_SUFFIX) {
			continue
		}
		base := info.name[:len(info.name) - len(DOWN_SUFFIX)]
		data, derr := os.read_entire_file(info.fullpath, context.temp_allocator)
		if derr != nil {
			return nil, mig_err(.Load_Failed, 0, "cannot read a down migration", loc)
		}
		downs[base] = string(data)
	}

	out: [dynamic]Migration
	out.allocator = context.temp_allocator
	for info in infos {
		if !strings.has_suffix(info.name, UP_SUFFIX) {
			continue
		}
		base := info.name[:len(info.name) - len(UP_SUFFIX)]
		id, name, ok := parse_base(base)
		if !ok {
			return nil, mig_err(.Bad_Filename, 0, "bad migration filename", loc)
		}
		data, uerr := os.read_entire_file(info.fullpath, context.temp_allocator)
		if uerr != nil {
			return nil, mig_err(.Load_Failed, id, "cannot read an up migration", loc)
		}
		up_sql := string(data)
		digest := hash.hash_string(.SHA256, up_sql, context.temp_allocator)
		sum := hex.encode(digest, context.temp_allocator)

		// Reference temp-backed strings for now; only the validated result is
		// cloned into the caller's allocator, so error paths leak nothing.
		m := Migration {
			id             = id,
			name           = name,
			up_sql         = up_sql,
			checksum       = string(sum),
			no_transaction = has_no_tx_directive(up_sql),
		}
		if d, has := downs[base]; has {
			m.down_sql = d
		}
		append(&out, m)
	}

	slice.sort_by(out[:], proc(a, b: Migration) -> bool {
		return a.id < b.id
	})
	for i in 1 ..< len(out) {
		if out[i].id == out[i - 1].id {
			return nil, mig_err(.Duplicate_Id, out[i].id, "two migrations share an id", loc)
		}
	}

	result := make([]Migration, len(out), allocator)
	for m, i in out {
		result[i] = Migration {
			id             = m.id,
			name           = strings.clone(m.name, allocator),
			up_sql         = strings.clone(m.up_sql, allocator),
			checksum       = strings.clone(m.checksum, allocator),
			no_transaction = m.no_transaction,
		}
		if m.down_sql != "" {
			result[i].down_sql = strings.clone(m.down_sql, allocator)
		}
	}
	return result, Error{}
}

// parse_base splits "<id>_<name>" into a positive integer id and a name.
@(private)
parse_base :: proc(base: string) -> (id: i64, name: string, ok: bool) {
	sep := strings.index_byte(base, '_')
	if sep <= 0 || sep == len(base) - 1 {
		return 0, "", false
	}
	prefix := base[:sep]
	value, pok := strconv.parse_int(prefix, 10)
	if !pok || value <= 0 {
		return 0, "", false
	}
	return i64(value), base[sep + 1:], true
}

@(private)
has_no_tx_directive :: proc(sql: string) -> bool {
	line := sql
	if nl := strings.index_byte(sql, '\n'); nl >= 0 {
		line = sql[:nl]
	}
	return strings.contains(line, NO_TX_DIRECTIVE)
}

@(private)
mig_err :: proc(kind: Error_Kind, id: i64, detail: string, loc: runtime.Source_Code_Location) -> Error {
	return Error{kind = kind, id = id, detail = detail, loc = loc}
}

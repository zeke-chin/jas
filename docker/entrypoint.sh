#!/bin/sh
set -eu

fail() {
    echo "JAS startup: $*" >&2
    exit 1
}

validate_key() {
    [ "${#1}" -eq 64 ] || fail "The key must be exactly 64 hexadecimal characters."
    case "$1" in
        *[!0-9a-fA-F]*) fail "The key must contain only hexadecimal characters." ;;
    esac
}

jas_config=${JAS_CONFIG:-/etc/jas/jas.toml}
if [ ! -r "$jas_config" ] || [ ! -f "$jas_config" ]; then
    fail "JAS_CONFIG must point to a readable TOML file."
fi

# Normally /data is the ./data bind mount. Config::load() rebases /data/...
# storage paths when this variable is set, so a custom layout does not need
# a second jas.toml.
jas_data_dir=${JAS_DATA_DIR:-/data}
if [ ! -d "$jas_data_dir" ] || [ ! -w "$jas_data_dir" ] || [ ! -x "$jas_data_dir" ]; then
    fail "The data directory must be writable by UID/GID 10001:10001; check ./data permissions."
fi
export JAS_DATA_DIR="$jas_data_dir"

umask 077
jas_key_file="$jas_data_dir/.jas-secret-key"
if [ -L "$jas_key_file" ] || { [ -e "$jas_key_file" ] && [ ! -f "$jas_key_file" ]; }; then
    fail "The key path must be a regular file, not a symlink or directory."
fi

# Optional explicit input supports importing an old deployment's key. Compose
# does not declare this variable; normal deployments only use the key file.
jas_import_key=${JAS_SECRET_KEY:-}
if [ -n "$jas_import_key" ]; then
    validate_key "$jas_import_key"
    jas_import_key=$(printf '%s' "$jas_import_key" | tr 'A-F' 'a-f')
fi

if [ ! -f "$jas_key_file" ]; then
    if [ -n "$jas_import_key" ]; then
        jas_new_key=$jas_import_key
    else
        # Never silently replace the key for an existing SQLite database,
        # including interrupted/partially restored databases with WAL files.
        for jas_db_file in "$jas_data_dir/jas.db" "$jas_data_dir/jas.db-wal" "$jas_data_dir/jas.db-shm"; do
            if [ -e "$jas_db_file" ] || [ -L "$jas_db_file" ]; then
                fail "Database exists but .jas-secret-key is missing. Restore/import the ORIGINAL key; refusing to generate a new one."
            fi
        done
        jas_new_key=$(openssl rand -hex 32)
        validate_key "$jas_new_key"
    fi

    # Publish a completely written key atomically. ln never overwrites another
    # startup's key; if another process wins, read its completed file below.
    jas_key_tmp=$(mktemp "$jas_data_dir/.jas-secret-key.tmp.XXXXXX")
    trap 'rm -f -- "$jas_key_tmp"' 0
    trap 'exit 1' 1 2 15
    printf '%s\n' "$jas_new_key" > "$jas_key_tmp"
    chmod 600 "$jas_key_tmp"
    if ln "$jas_key_tmp" "$jas_key_file" 2>/dev/null; then
        echo "JAS startup: saved the encryption key in the data directory (value not logged)." >&2
    elif [ ! -f "$jas_key_file" ] || [ -L "$jas_key_file" ]; then
        fail "Could not create the key file without overwriting existing data."
    fi
    rm -f -- "$jas_key_tmp"
    trap - 0 1 2 15
fi

jas_secret_key=$(cat "$jas_key_file")
validate_key "$jas_secret_key"
jas_secret_key=$(printf '%s' "$jas_secret_key" | tr 'A-F' 'a-f')
if [ -n "$jas_import_key" ] && [ "$jas_import_key" != "$jas_secret_key" ]; then
    fail "JAS_SECRET_KEY conflicts with the saved key. Refusing to replace it."
fi
chmod 600 "$jas_key_file"

# Keep the Rust app unchanged: pass its key internally, not in Compose or logs.
export JAS_SECRET_KEY="$jas_secret_key"
exec "$@"

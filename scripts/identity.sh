#!/bin/sh
# Prints the SHA-1 of the single usable "Unazc Dev" signing identity, or fails with the reason.
# Self-signed, so it is CSSMERR_TP_NOT_TRUSTED (fine for local signing) and absent from -v output.
NAME="Unazc Dev"
LINES=$(security find-identity -p codesigning | grep "\"$NAME\"")
[ -n "$LINES" ] || { echo "no identity '$NAME' (run scripts/make-cert.sh)" >&2; exit 1; }
# The same identity can appear in several numbered sections; count distinct hashes.
HASHES=$(echo "$LINES" | awk '{print $2}' | sort -u)
[ "$(echo "$HASHES" | wc -l | tr -d ' ')" = 1 ] || { echo "multiple '$NAME' identities; delete extras in Keychain Access:" >&2; echo "$LINES" >&2; exit 2; }
if echo "$LINES" | grep -qE "EXPIRED|REVOKED"; then echo "identity unusable: $LINES" >&2; exit 2; fi
echo "$HASHES"

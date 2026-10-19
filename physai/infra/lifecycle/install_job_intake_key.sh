#!/bin/bash
# Install the job-intake submit Lambda's SSH public key for `ubuntu`.
# Runs on the LOGIN node only.
#
# The key pair is created by PhysaiJobIntakeStack, which deploys after this
# cluster, so it is looked up at boot rather than baked in. HyperPod re-runs
# lifecycle scripts on every node replacement, which is what keeps the key
# installed. Reads the key pair's name, its stack and the VPC CIDR from
# physai-config.json, which carries them only while job intake is enabled;
# without them, any key this script installed is removed.
#
# Trust: only the key pair whose id the job-intake stack publishes as its
# `SshKeyPairId` output is installed. A key pair recreated by hand under the
# same name gets a new id, so it is refused, and changing the output means
# updating the stack. The installed line is restricted to connections from the
# VPC, with every forwarding and pty option disabled. The file is written as
# `ubuntu`, so root never follows a link planted in that user's home.
#
# Never fails the lifecycle: a login node without the key only breaks job
# intake, and a failed lifecycle fails the node.
set -euo pipefail
trap 'echo "WARNING: \"$BASH_COMMAND\" failed; job intake cannot reach this node" >&2; exit 0' ERR
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_node_type login

CONFIG_JSON="$(dirname "$0")/physai-config.json"
LOGIN_USER="ubuntu"

if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "No physai-config.json found at $CONFIG_JSON, skipping"
    exit 0
fi

KEY_NAME=$(jq -r '.job_intake_key_name // empty' "$CONFIG_JSON")
STACK_NAME=$(jq -r '.job_intake_stack_name // empty' "$CONFIG_JSON")
SOURCE_CIDR=$(jq -r '.vpc_cidr // empty' "$CONFIG_JSON")

if [[ -n "$SOURCE_CIDR" && ! "$SOURCE_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    echo "WARNING: vpc_cidr '$SOURCE_CIDR' is not an IPv4 CIDR, skipping" >&2
    exit 0
fi

HOME_DIR=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    echo "WARNING: no home directory for $LOGIN_USER, skipping" >&2
    exit 0
fi
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
# Identifies the lines this script owns, so they can be replaced or removed
# without touching any other key. Matched by prefix, so a key installed under
# an earlier cluster name is still found.
MARKER="job-intake:"

# Prints the key line to install, prints nothing if the key pair is gone or
# fails verification, and returns 1 if the answer is unknown.
verified_key_line() {
    local token region stack key_pair_id described key_name key_type material
    token=$(curl -sfX PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
    region=$(curl -sfH "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/placement/region) || return 1

    if ! stack=$(aws cloudformation describe-stacks --region "$region" \
        --stack-name "$STACK_NAME" --output json 2>&1); then
        # Not found: the stack is gone. Access denied: the grant that comes
        # with the stack is gone. Either way nothing should be installed.
        if [[ "$stack" == *"does not exist"* || "$stack" == *AccessDenied* ]]; then
            echo "$STACK_NAME is not deployed" >&2
            return 0
        fi
        echo "WARNING: could not read $STACK_NAME: $stack" >&2
        return 1
    fi
    key_pair_id=$(jq -r '.Stacks[0].Outputs // [] | map(select(.OutputKey == "SshKeyPairId")) | .[0].OutputValue // empty' <<<"$stack")
    if [[ ! "$key_pair_id" =~ ^key-[0-9a-f]{8,17}$ ]]; then
        # A stack mid-update can lack the output; nothing new is trusted.
        echo "WARNING: $STACK_NAME has no usable SshKeyPairId output ('$key_pair_id')" >&2
        return 1
    fi

    if ! described=$(aws ec2 describe-key-pairs --region "$region" \
        --key-pair-ids "$key_pair_id" --include-public-key --output json 2>&1); then
        if [[ "$described" == *InvalidKeyPair.NotFound* || "$described" == *UnauthorizedOperation* ]]; then
            echo "key pair $key_pair_id is not deployed" >&2
            return 0
        fi
        echo "WARNING: could not look up $key_pair_id: $described" >&2
        return 1
    fi

    key_name=$(jq -r '.KeyPairs[0].KeyName // empty' <<<"$described")
    key_type=$(jq -r '.KeyPairs[0].KeyType // empty' <<<"$described")
    material=$(jq -r '.KeyPairs[0].PublicKey // empty' <<<"$described")

    if [[ "$key_name" != "$KEY_NAME" ]]; then
        echo "WARNING: $key_pair_id is named '$key_name', not $KEY_NAME, refusing it" >&2
        return 0
    fi
    if [[ "$key_type" != "ed25519" ]]; then
        echo "WARNING: $KEY_NAME is type '$key_type', not ed25519, refusing it" >&2
        return 0
    fi
    # Only the type and key fields are kept, so nothing from the API can add
    # an authorized_keys option or a second line.
    if [[ ! "$material" =~ ^(ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=*)(\ [^[:cntrl:]]*)?$ ]]; then
        echo "WARNING: $KEY_NAME has an unrecognised public key, refusing it" >&2
        return 0
    fi
    printf 'restrict,from="%s" %s %s%s\n' "$SOURCE_CIDR" "${BASH_REMATCH[1]}" "$MARKER" "$KEY_NAME"
}

if [[ -z "$KEY_NAME" || -z "$STACK_NAME" || -z "$SOURCE_CIDR" ]]; then
    echo "Job intake is not enabled on this cluster"
    key_line=""
elif ! key_line=$(verified_key_line); then
    echo "Leaving $AUTH_KEYS unchanged"
    exit 0
fi

runuser -u "$LOGIN_USER" -- install -d -m 700 "$SSH_DIR"

current=""
if [[ -f "$AUTH_KEYS" ]]; then
    current=$(runuser -u "$LOGIN_USER" -- cat "$AUTH_KEYS")
fi
kept=$(grep -vF -- " $MARKER" <<<"$current" || true)
desired=$(printf '%s\n%s\n' "$kept" "$key_line" | sed '/^$/d')

if [[ "$desired" == "$current" ]]; then
    echo "$AUTH_KEYS already up to date"
    exit 0
fi

# Written beside the target and renamed over it, so sshd never reads a
# half-written file.
# shellcheck disable=SC2016
printf '%s\n' "$desired" | runuser -u "$LOGIN_USER" -- bash -c '
    tmp=$(mktemp "$1/.authorized_keys.XXXXXX") || exit 1
    if cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$2"; then exit 0; fi
    rm -f "$tmp"
    exit 1' _ "$SSH_DIR" "$AUTH_KEYS"

if [[ -n "$key_line" ]]; then
    echo "Installed job-intake key $KEY_NAME for $LOGIN_USER, restricted to $SOURCE_CIDR"
else
    echo "Removed the job-intake key for $LOGIN_USER"
fi

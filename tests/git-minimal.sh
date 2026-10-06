#!/usr/bin/env bash
# Run directly with bash; no sandbox privileges required.
set -eu
preset=$(realpath -- "$(dirname -- "$0")/../presets.d/git-minimal.sh")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

yell() { printf '%s\n' "$*" >&2; }
die() { yell "$*"; exit 1; }
source "$preset"
git init -q "$tmp/source"
git -C "$tmp/source" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm initial
git init -q "$tmp/super"
git -C "$tmp/super" -c protocol.file.allow=always submodule add -q "$tmp/source" 'sub module'
sub="$tmp/super/sub module"
metadata=$(git -C "$sub" rev-parse --path-format=absolute --git-dir)
mkdir "$tmp/nonrepo" "$tmp/fake" "$tmp/symlink" "$sub/nested"
PROJECT_DIR="$tmp/nonrepo"
RO_BINDS=(); RW_BINDS=(); EXTRA_BWRAP_OPTS=(); SANDBOX_RUN_FINALIZERS=()
configure_git-minimal || true
[[ ${SANDBOX_RUN_FINALIZERS[0]} == _git_minimal_add_bind_gitdirs ]]

# Read-only metadata is reapplied after writable ancestor mounts.
RO_BINDS=("$sub" "$sub" "$tmp/missing" "$sub/nested")
RW_BINDS=("$tmp/super/.git")
_git_minimal_add_bind_gitdirs
[[ ${#RO_BINDS[@]} == 5 && ${RO_BINDS[4]} == "$metadata" ]]
[[ ${#RW_BINDS[@]} == 1 ]]
[[ ${EXTRA_BWRAP_OPTS[*]} == "--ro-bind-try $metadata $metadata" ]]
if command -v bwrap >/dev/null && bwrap --ro-bind / / --unshare-user -- true 2>/dev/null; then
    bwrap --ro-bind / / --unshare-user \
        --bind "$tmp/super/.git" "$tmp/super/.git" \
        "${EXTRA_BWRAP_OPTS[@]}" --dev /dev -- bash -c '
            set -eu
            GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain >/dev/null
            if touch "$2/bind-test" 2>/dev/null; then
                echo "read-only metadata unexpectedly writable" >&2
                exit 1
            fi
        ' bash "$sub" "$metadata"
else
    printf 'SKIP: bubblewrap mount enforcement (unavailable)\n'
fi

# Same worktree requested both ways: writable metadata wins, once.
RO_BINDS=("$sub"); RW_BINDS=("$sub" "$sub"); EXTRA_BWRAP_OPTS=()
_git_minimal_add_bind_gitdirs
[[ ${#RO_BINDS[@]} == 2 && ${RO_BINDS[1]} == "$metadata" ]]
[[ ${#RW_BINDS[@]} == 3 && ${RW_BINDS[2]} == "$metadata" ]]
[[ ${#EXTRA_BWRAP_OPTS[@]} == 0 ]]
if command -v bwrap >/dev/null && bwrap --ro-bind / / --unshare-user -- true 2>/dev/null; then
    bwrap --ro-bind / / --unshare-user \
        --ro-bind "$metadata" "$metadata" --bind "$metadata" "$metadata" \
        -- touch "$metadata/bind-test"
    rm "$metadata/bind-test"
fi

# Explicit writable metadata (including aliases) also wins.
ln -s "$metadata" "$tmp/metadata-alias"
RO_BINDS=("$sub"); RW_BINDS=("$tmp/metadata-alias"); EXTRA_BWRAP_OPTS=()
_git_minimal_add_bind_gitdirs
[[ ${#EXTRA_BWRAP_OPTS[@]} == 0 ]]

# Keep security restrictions in both modes.
printf 'gitdir: %s\n' "$tmp/source/.git" > "$tmp/fake/.git"
ln -s "$sub/.git" "$tmp/symlink/.git"
for mode in ro rw; do
    RO_BINDS=(); RW_BINDS=(); EXTRA_BWRAP_OPTS=()
    if [[ "$mode" == ro ]]; then
        RO_BINDS=("$tmp/fake" "$tmp/symlink" "$sub/nested")
    else
        RW_BINDS=("$tmp/fake" "$tmp/symlink" "$sub/nested")
    fi
    _git_minimal_add_bind_gitdirs
    [[ $((${#RO_BINDS[@]} + ${#RW_BINDS[@]})) == 3 ]]
    [[ ${#EXTRA_BWRAP_OPTS[@]} == 0 ]]
done
printf 'PASS: git-minimal bind access, precedence, deduplication and validation\n'

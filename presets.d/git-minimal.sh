# Provide some minimal context for git to allow for proper
# commit metadata if no complete gitconfig is made available.

# Map a file (~/.gitconfig-sandbox-run by default) r/o if it exists
# to allow for specific gitconfig files for the sandbox.
if [ -z "${SANDBOX_RUN_GIT_CONFIG_PATH:-}" ]; then
    SANDBOX_RUN_GIT_CONFIG_PATH="$HOME/.gitconfig-sandbox-run"
fi

# Ignore repository-location overrides while inspecting the project.
# In particular, do not let an inherited GIT_DIR turn into an automatic bind.
_git_minimal_git() {
    env \
        -u GIT_DIR \
        -u GIT_WORK_TREE \
        -u GIT_COMMON_DIR \
        -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY \
        -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_CEILING_DIRECTORIES \
        -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
        GIT_CONFIG_COUNT=0 \
        git "$@"
}

_git_minimal_add_external_submodule_gitdir() {
    local project_real="$1"
    local git_dir=""
    local git_dir_real=""
    local git_common_dir=""
    local git_common_dir_real=""
    local superproject_root=""
    local superproject_real=""
    local superproject_git_dir=""
    local superproject_git_dir_real=""
    local submodule_path=""
    local index_entry=""

    git_dir=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --git-dir 2>/dev/null
    ) || return
    git_dir_real=$(realpath -e -- "$git_dir" 2>/dev/null) || {
        yell "git-minimal preset: cannot resolve gitdir: $git_dir"
        return
    }

    # A normal repository's gitdir is already covered by the project bind.
    case "$git_dir_real" in
        "$project_real"|"$project_real"/*)
            return
            ;;
    esac

    # Only regular .git files at the project root may request an external bind.
    # This excludes symlink tricks and deliberately ignores nested worktrees.
    if [[ ! -f "$project_real/.git" || -L "$project_real/.git" ]]; then
        yell "git-minimal preset: refusing external gitdir without a regular project-root .git file: $git_dir"
        return
    fi

    # Git performs its submodule relationship check here.
    # A .git file that merely points at an unrelated repository yields no
    # superproject, and one pointing at another submodule reports another
    # worktree before this function is reached by configure_git-minimal.
    superproject_root=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --show-superproject-working-tree 2>/dev/null
    ) || return
    if [[ -z "$superproject_root" ]]; then
        yell "git-minimal preset: refusing external gitdir without a recognized superproject: $git_dir"
        return
    fi
    superproject_real=$(realpath -e -- "$superproject_root" 2>/dev/null) || {
        yell "git-minimal preset: cannot resolve superproject: $superproject_root"
        return
    }

    # The project must be a strict descendant of the reported superproject.
    case "$project_real" in
        "$superproject_real"/*) ;;
        *)
            yell "git-minimal preset: project is outside its reported superproject: $superproject_root"
            return
            ;;
    esac

    superproject_git_dir=$(
        _git_minimal_git -C "$superproject_real" rev-parse \
            --path-format=absolute --git-dir 2>/dev/null
    ) || return
    superproject_git_dir_real=$(realpath -e -- "$superproject_git_dir" 2>/dev/null) || {
        yell "git-minimal preset: cannot resolve superproject gitdir: $superproject_git_dir"
        return
    }

    # Resolve before comparing so '..' and symlinks cannot escape modules/.
    case "$git_dir_real" in
        "$superproject_git_dir_real"/modules/*) ;;
        *)
            yell "git-minimal preset: refusing gitdir outside the superproject's modules directory: $git_dir"
            return
            ;;
    esac

    # A separate common dir would require another external bind whose safe
    # scope is unclear, so support only the normal absorbed-submodule layout.
    git_common_dir=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --git-common-dir 2>/dev/null
    ) || return
    git_common_dir_real=$(realpath -e -- "$git_common_dir" 2>/dev/null) || return
    if [[ "$git_common_dir_real" != "$git_dir_real" ]]; then
        yell "git-minimal preset: refusing submodule with a separate common gitdir: $git_common_dir"
        return
    fi

    # Explicitly verify the relationship Git reported against the
    # superproject index. Mode 160000 denotes a submodule gitlink.
    submodule_path=$(realpath --relative-to="$superproject_real" -- "$project_real") || return
    index_entry=$(
        _git_minimal_git --literal-pathspecs -C "$superproject_real" \
            ls-files --error-unmatch --stage -- "$submodule_path" 2>/dev/null
    ) || {
        yell "git-minimal preset: project is absent from the superproject index: $submodule_path"
        return
    }
    if [[ "$index_entry" == *$'\n'* || "${index_entry%% *}" != "160000" ]]; then
        yell "git-minimal preset: project is not a submodule gitlink: $submodule_path"
        return
    fi

    # Match the write access an in-tree .git directory normally receives.
    RW_BINDS+=("$git_dir")
}

configure_git-minimal() {
    command -v git >/dev/null 2>&1 || \
        die "git-minimal preset requires git, but git was not found in PATH"

    local project_real=""
    local worktree_root=""
    project_real=$(realpath -e -- "$PROJECT_DIR" 2>/dev/null) || return
    worktree_root=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --show-toplevel 2>/dev/null
    ) || return
    worktree_root=$(realpath -e -- "$worktree_root" 2>/dev/null) || return

    # Sandboxing a repository subdirectory intentionally does not expose the
    # repository root or its metadata.
    [[ "$project_real" == "$worktree_root" ]] || return

    _git_minimal_add_external_submodule_gitdir "$project_real"

    local git_author_name=""
    local git_author_email=""
    git_author_name=$(_git_minimal_git -C "$project_real" config --get user.name 2>/dev/null || true)
    git_author_email=$(_git_minimal_git -C "$project_real" config --get user.email 2>/dev/null || true)

    if [[ -z "$git_author_name" || -z "$git_author_email" ]]; then
        yell "git-minimal preset: missing user.name/user.email in repo config"
        return
    fi

    ENV_PRESET_OPTS+=(
        --setenv GIT_AUTHOR_NAME "$git_author_name"
        --setenv GIT_AUTHOR_EMAIL "$git_author_email"
        --setenv GIT_COMMITTER_NAME "$git_author_name"
        --setenv GIT_COMMITTER_EMAIL "$git_author_email"
    )

    if [ -r "$SANDBOX_RUN_GIT_CONFIG_PATH" ]; then
        ENV_PRESET_OPTS+=(
            --setenv GIT_CONFIG_GLOBAL "$SANDBOX_RUN_GIT_CONFIG_PATH"
        )
        RO_BINDS+=("$SANDBOX_RUN_GIT_CONFIG_PATH")
    else
        yell "SANDBOX_RUN_GIT_CONFIG_PATH set but the file is not readable: \"${SANDBOX_RUN_GIT_CONFIG_PATH}\""
    fi
}

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

_git_minimal_add_gitdir_bind() {
    local gitdir="$1"
    local bind_mode="$2"
    local -n gitdir_binds="${bind_mode^^}_BINDS"
    local existing=""

    for existing in "${gitdir_binds[@]}"; do
        [[ "$existing" == "$gitdir" ]] && return
    done
    gitdir_binds+=("$gitdir")
}

_git_minimal_add_external_gitdir() {
    local project_real="$1"
    local bind_mode="${2:-rw}"
    local git_dir=""
    local git_dir_real=""
    local git_common_dir=""
    local git_common_dir_real=""
    local worktree_id=""
    local commondir_ref=""
    local commondir_real=""
    local gitfile_backlink=""
    local gitfile_backlink_real=""
    local project_gitfile_real=""
    local worktree_entry=""
    local listed_worktree=""
    local listed_worktree_real=""
    local registered_worktree=0
    local superproject_root=""
    local superproject_real=""
    local superproject_git_dir=""
    local superproject_git_dir_real=""
    local submodule_path=""
    local index_entry=""

    git_dir=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --git-dir 2>/dev/null
    ) || return 0
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
    # This excludes symlink tricks and deliberately ignores nested repositories.
    if [[ ! -f "$project_real/.git" || -L "$project_real/.git" ]]; then
        yell "git-minimal preset: refusing external gitdir without a regular project-root .git file: $git_dir"
        return
    fi

    git_common_dir=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --git-common-dir 2>/dev/null
    ) || return 0
    git_common_dir_real=$(realpath -e -- "$git_common_dir" 2>/dev/null) || {
        yell "git-minimal preset: cannot resolve common gitdir: $git_common_dir"
        return
    }

    if [[ "$git_common_dir_real" != "$git_dir_real" ]]; then
        # Linked worktrees keep per-worktree metadata in a direct child of the
        # common gitdir's worktrees/ directory.
        case "$git_dir_real" in
            "$git_common_dir_real"/worktrees/*)
                worktree_id=${git_dir_real#"$git_common_dir_real"/worktrees/}
                ;;
            *)
                yell "git-minimal preset: refusing linked worktree gitdir outside the common gitdir: $git_dir"
                return
                ;;
        esac
        if [[ -z "$worktree_id" || "$worktree_id" == */* ]]; then
            yell "git-minimal preset: refusing non-direct worktree gitdir: $git_dir"
            return
        fi

        # Verify the per-worktree commondir link independently of rev-parse.
        if [[ ! -f "$git_dir_real/commondir" || -L "$git_dir_real/commondir" ]]; then
            yell "git-minimal preset: linked worktree has no regular commondir file: $git_dir"
            return
        fi
        IFS= read -r commondir_ref < "$git_dir_real/commondir" || return 0
        commondir_ref=${commondir_ref%$'\r'}
        if [[ "$commondir_ref" != /* ]]; then
            commondir_ref="$git_dir_real/$commondir_ref"
        fi
        commondir_real=$(realpath -e -- "$commondir_ref" 2>/dev/null) || return 0
        if [[ "$commondir_real" != "$git_common_dir_real" ]]; then
            yell "git-minimal preset: linked worktree commondir does not match git: $commondir_ref"
            return
        fi

        # The administrative gitdir must point back to this worktree's .git
        # file, preventing a project from borrowing another worktree's gitdir.
        if [[ ! -f "$git_dir_real/gitdir" || -L "$git_dir_real/gitdir" ]]; then
            yell "git-minimal preset: linked worktree has no regular gitdir backlink: $git_dir"
            return
        fi
        IFS= read -r gitfile_backlink < "$git_dir_real/gitdir" || return 0
        gitfile_backlink=${gitfile_backlink%$'\r'}
        if [[ "$gitfile_backlink" != /* ]]; then
            gitfile_backlink="$git_dir_real/$gitfile_backlink"
        fi
        gitfile_backlink_real=$(realpath -e -- "$gitfile_backlink" 2>/dev/null) || return 0
        project_gitfile_real=$(realpath -e -- "$project_real/.git" 2>/dev/null) || return 0
        if [[ "$gitfile_backlink_real" != "$project_gitfile_real" ]]; then
            yell "git-minimal preset: linked worktree gitdir points at another worktree: $gitfile_backlink"
            return
        fi

        # Confirm that the common repository still registers this worktree.
        while IFS= read -r -d '' worktree_entry; do
            case "$worktree_entry" in
                "worktree "*)
                    listed_worktree=${worktree_entry#worktree }
                    listed_worktree_real=$(realpath -e -- "$listed_worktree" 2>/dev/null) || continue
                    if [[ "$listed_worktree_real" == "$project_real" ]]; then
                        registered_worktree=1
                    fi
                    ;;
            esac
        done < <(
            _git_minimal_git -C "$project_real" \
                worktree list --porcelain -z 2>/dev/null
        )
        if (( ! registered_worktree )); then
            yell "git-minimal preset: linked worktree is not registered in the common repository: $project_real"
            return
        fi

        # Linked worktrees require the complete common gitdir for shared
        # objects, refs, configuration, and worktree administration.
        _git_minimal_add_gitdir_bind "$git_common_dir_real" "$bind_mode"
        return
    fi

    # With no separate common dir, recognize only an absorbed submodule.
    # Arbitrary gitfiles such as --separate-git-dir layouts remain unsupported.
    superproject_root=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --show-superproject-working-tree 2>/dev/null
    ) || return 0
    if [[ -z "$superproject_root" ]]; then
        yell "git-minimal preset: refusing external gitdir that is neither a linked worktree nor a recognized submodule: $git_dir"
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
    ) || return 0
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

    # Explicitly verify the relationship Git reported against the
    # superproject index. Mode 160000 denotes a submodule gitlink.
    submodule_path=$(realpath --relative-to="$superproject_real" -- "$project_real") || return 0
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

    # Match the worktree bind's access without exposing other metadata.
    _git_minimal_add_gitdir_bind "$git_dir_real" "$bind_mode"
}

# Run after environment binds and all presets have been collected. Inspect only
# each bind's root, not nested repositories or metadata added during this pass.
_git_minimal_add_bind_gitdirs() {
    local bind=""
    local bind_real=""
    local worktree_root=""
    local mode=""
    local existing=""
    local existing_real=""
    local writable=0
    local ro_count=${#RO_BINDS[@]}
    local -a ro_binds=("${RO_BINDS[@]}")
    local -a rw_binds=("${RW_BINDS[@]}")
    local -a binds=()

    for mode in ro rw; do
        if [[ "$mode" == ro ]]; then
            binds=("${ro_binds[@]}")
        else
            binds=("${rw_binds[@]}")
        fi
        for bind in "${binds[@]}"; do
            [[ -d "$bind" ]] || continue
            bind_real=$(realpath -e -- "$bind" 2>/dev/null) || continue
            [[ -f "$bind_real/.git" && ! -L "$bind_real/.git" ]] || continue
            worktree_root=$(
                _git_minimal_git -C "$bind_real" rev-parse \
                    --path-format=absolute --show-toplevel 2>/dev/null
            ) || continue
            worktree_root=$(realpath -e -- "$worktree_root" 2>/dev/null) || continue
            [[ "$bind_real" == "$worktree_root" ]] || continue
            _git_minimal_add_external_gitdir "$bind_real" "$mode"
        done
    done

    # RO_BINDS are mounted before RW_BINDS. Reapply discovered read-only
    # metadata last so a writable ancestor cannot accidentally make it writable.
    # An explicit writable mount of that same gitdir takes precedence.
    for bind in "${RO_BINDS[@]:ro_count}"; do
        writable=0
        for existing in "${RW_BINDS[@]}"; do
            existing_real=$(realpath -e -- "$existing" 2>/dev/null) || continue
            if [[ "$existing_real" == "$bind" ]]; then
                writable=1
                break
            fi
        done
        if (( ! writable )); then
            EXTRA_BWRAP_OPTS+=(--ro-bind-try "$bind" "$bind")
        fi
    done
}

configure_git-minimal() {
    command -v git >/dev/null 2>&1 || \
        die "git-minimal preset requires git, but git was not found in PATH"

    # Register before project inspection: extra binds may be submodules or
    # linked worktrees even when CWD is not a repository root or lacks author
    # configuration.
    SANDBOX_RUN_FINALIZERS+=(_git_minimal_add_bind_gitdirs)

    local project_real=""
    local worktree_root=""
    project_real=$(realpath -e -- "$PROJECT_DIR" 2>/dev/null) || return 0
    worktree_root=$(
        _git_minimal_git -C "$project_real" rev-parse \
            --path-format=absolute --show-toplevel 2>/dev/null
    ) || return 0
    worktree_root=$(realpath -e -- "$worktree_root" 2>/dev/null) || return 0

    # Sandboxing a repository subdirectory intentionally does not expose the
    # repository root or its metadata.
    [[ "$project_real" == "$worktree_root" ]] || return 0

    _git_minimal_add_external_gitdir "$project_real"

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

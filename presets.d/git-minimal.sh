# Provide some minimal context for git to allow for proper
# commit metadata if no complete gitconfig is made available.
configure_git-minimal() {
    command -v git >/dev/null 2>&1 || return
    if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    local git_author_name=""
    local git_author_email=""
    git_author_name=$(git -C "$PROJECT_DIR" config --get user.name 2>/dev/null || true)
    git_author_email=$(git -C "$PROJECT_DIR" config --get user.email 2>/dev/null || true)

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
}

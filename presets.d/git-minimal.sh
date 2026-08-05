# Provide some minimal context for git to allow for proper
# commit metadata if no complete gitconfig is made available.

# Map a file (~/.gitconfig-sandbox-run by default) r/o if it exists
# to allow for specific gitconfig files for the sandbox.
if [ -z "${SANDBOX_RUN_GIT_CONFIG_PATH:-}" ]; then
    SANDBOX_RUN_GIT_CONFIG_PATH="$HOME/.gitconfig-sandbox-run"
fi

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

    if [ -r "$SANDBOX_RUN_GIT_CONFIG_PATH" ]; then
        ENV_PRESET_OPTS+=(
            --setenv GIT_CONFIG_GLOBAL "$SANDBOX_RUN_GIT_CONFIG_PATH"
        )
        RO_BINDS+=("$SANDBOX_RUN_GIT_CONFIG_PATH")
    else
        yell "SANDBOX_RUN_GIT_CONFIG_PATH set but the file is not readable: \"${SANDBOX_RUN_GIT_CONFIG_PATH}\""
    fi
}

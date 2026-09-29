# shellcheck shell=bash
# Claude Code user configuration (spec §6.4, §6.10, §6.11). Needs
# lib/common.sh, lib/tools.sh, load_config and resolve_paths.

CLAUDE_AGENT_DIR="$DEVENV_ROOT/agents/claude"
STATUSLINE_SHA256=dc324500a5e54bc7905816cd92039c6519e4bcd3303d40a023e0686cde7e27c4

# jq program: deep-merge $overlay into the input. Objects merge recursively,
# arrays gain the overlay's elements they do not already contain, and scalars
# take the overlay's value. Before merging, hook entries that run one of
# devenv's own ~/.claude/hooks/devenv-* scripts are dropped, so a changed
# overlay hook replaces the old one instead of piling up next to it.
# shellcheck disable=SC2016
CLAUDE_MERGE_JQ='
def merge($a; $b):
  if ($a | type) == "object" and ($b | type) == "object" then
    reduce ($b | keys_unsorted[]) as $k ($a; .[$k] = merge($a[$k]; $b[$k]))
  elif ($a | type) == "array" and ($b | type) == "array" then
    $a + [$b[] | . as $x | select(any($a[]; . == $x) | not)]
  else $b end;
def is_devenv_hook: any(.hooks[]?; (.command // "") | tostring | contains("/.claude/hooks/devenv-"));
(if (.hooks | type) == "object" then
   .hooks |= with_entries(.value |= (if type == "array" then map(select(is_devenv_hook | not)) else . end))
 else . end)
| merge(.; $overlay)
| reduce ($models | split(" ")[] | select(length > 0)) as $m (.; .modelSettings[$m].effortLevel = $effort)
'

# Write ~/.config/devenv/paths.env: the few values the status line wrapper and
# the memory hook need without loading the whole of devenv.
write_paths_env() {
  mkdir -p "$DEVENV_CFG"
  {
    echo "# Written by devenv; do not edit."
    printf 'DEVENV_DIR=%q\n' "$DEVENV_ROOT"
    printf 'DEVENV_STATE_DIR=%q\n' "$DEVENV_STATE_DIR"
    printf 'FM_HOME=%q\n' "$FM_HOME"
    printf 'DEVENV_STATUSLINE_WARNINGS=%q\n' "$DEVENV_STATUSLINE_WARNINGS"
  } | write_if_changed "$DEVENV_CFG/paths.env" 0644 >/dev/null
}

# The line that imports sbx's generated runtime guidance, which sbx writes to
# the parent folder of the workspace. Empty when there is no such file.
sbx_guidance_import() {
  local f
  [ -n "${WORKSPACE_DIR:-}" ] || return 0
  f="$(dirname "$WORKSPACE_DIR")/CLAUDE.md"
  [ -f "$f" ] && printf '@%s' "$f"
  return 0
}

render_claude_md() {
  local import
  import=$(sbx_guidance_import)
  awk -v imp="$import" -v login="$BOT_LOGIN" -v email="$BOT_EMAIL" '
    $0 == "@@SBX_GUIDANCE_IMPORT@@" { if (imp != "") print imp; next }
    { gsub(/@@BOT_LOGIN@@/, login); gsub(/@@BOT_EMAIL@@/, email); print }
  ' "$CLAUDE_AGENT_DIR/CLAUDE.md"
}

# Install the status line scripts and devenv's hook script.
install_claude_files() {
  local src=$CLAUDE_AGENT_DIR/statusline-command.sh dst=$HOME/.claude/statusline-command.sh
  [ "$(file_sha256 "$src")" = "$STATUSLINE_SHA256" ] \
    || die "$src does not match the preserved status line (sha256 $STATUSLINE_SHA256)"
  mkdir -p "$HOME/.claude/hooks"
  write_if_changed "$dst" 0644 < "$src" >/dev/null
  [ "$(file_sha256 "$dst")" = "$STATUSLINE_SHA256" ] || die "installed $dst does not match sha256 $STATUSLINE_SHA256"
  write_if_changed "$HOME/.claude/statusline.sh" 0755 < "$CLAUDE_AGENT_DIR/statusline.sh" >/dev/null
  write_if_changed "$HOME/.claude/hooks/devenv-memory-link.sh" 0755 < "$CLAUDE_AGENT_DIR/hooks/memory-link.sh" >/dev/null
}

# Merge settings.overlay.json and the effort default into ~/.claude/settings.json.
merge_claude_settings() {
  local f=$HOME/.claude/settings.json cur
  mkdir -p "$HOME/.claude"
  if [ -s "$f" ]; then cur=$(cat "$f"); else cur='{}'; fi
  printf '%s' "$cur" | jq -e . >/dev/null 2>&1 || die "$f is not valid JSON; fix or remove it"
  printf '%s' "$cur" \
    | jq --argjson overlay "$(cat "$CLAUDE_AGENT_DIR/settings.overlay.json")" \
         --arg models "$CLAUDE_EFFORT_MODELS" --arg effort "$CLAUDE_EFFORT_DEFAULT" \
         "$CLAUDE_MERGE_JQ" \
    | write_if_changed "$f" 0644
}

# Link devenv's skills into ~/.claude/skills, so every Claude session (the
# first mate, workers in worktrees) sees them. sbx mounts its shared skills
# store only for built-in agents, so sbxenv.yaml turns it off and devenv links
# instead. A user's own skill that is not a symlink is never replaced.
link_skills() {
  local dir=$HOME/.claude/skills s name target
  mkdir -p "$dir" 2>/dev/null || true
  if [ ! -w "$dir" ]; then
    warn "~/.claude/skills is not writable (is sbx's skills store mounted there? set sandboxOptions.skills: \"off\"); skills not linked"
    return 0
  fi
  for s in "$DEVENV_ROOT"/skills/*/; do
    [ -f "$s/SKILL.md" ] || continue
    s=${s%/}; name=${s##*/}; target="$dir/$name"
    if [ -L "$target" ]; then
      [ "$(readlink "$target")" = "$s" ] && continue
      ln -sfn "$s" "$target"
    elif [ -e "$target" ]; then
      warn "~/.claude/skills/$name exists and is not a symlink; leaving it alone"
      continue
    else
      ln -s "$s" "$target"
    fi
    ok "skill $name linked"
  done
  # Drop links to skills that were removed from the repo.
  for target in "$dir"/*; do
    [ -L "$target" ] || continue
    case "$(readlink "$target")" in
      "$DEVENV_ROOT"/skills/*) [ -e "$target" ] || rm -f "$target" ;;
    esac
  done
}

# ---------------------------------------------------------------- token mode
# With CLAUDE_AUTH=token Claude signs in with CLAUDE_CODE_OAUTH_TOKEN. But
# Claude Code starts its daemon, which hosts background sessions (the first
# mate's conversation runs in one), without that variable whenever
# ~/.claude/.credentials.json holds a claude.ai login with a refresh token.
# Those sessions then use the stored login, and a login that lacks the
# inference scope ends in "Not logged in · Please run /login". sbx's claude kit
# seeds such a login when the host holds an Anthropic subscription (OAuth)
# credential, so in token mode devenv removes it before the first mate starts.
CLAUDE_CREDENTIALS_ASIDE_SUFFIX=.devenv-stored-login

claude_credentials_file() { printf '%s/.claude/.credentials.json' "$HOME"; }

# Token mode is in force wherever devenv supplies the setup-token: always in
# sbx (host-prepare's custom secret), and in plain mode only when the variable
# is set, so a laptop's own /login is never touched.
claude_token_mode_active() {
  [ "$CLAUDE_AUTH" = token ] || return 1
  [ "$(detect_mode)" = sbx ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]
}

# true when ~/.claude/.credentials.json holds a claude.ai login with a refresh
# token, the very condition Claude's daemon tests.
claude_stored_login_present() {
  local f
  f=$(claude_credentials_file)
  [ -s "$f" ] && jq -e '(.claudeAiOauth.refreshToken // "") != ""' "$f" >/dev/null 2>&1
}

# In token mode, move a stored claude.ai login out of ~/.claude/.credentials.json
# into <file>.devenv-stored-login (same mode; put it back to undo). Other
# entries in the file, such as MCP logins, stay. A login stored by /login in
# token mode goes the same way at the next start or entry. Never fails.
claude_drop_stored_login() {
  local f aside rest
  claude_token_mode_active || return 0
  claude_stored_login_present || return 0
  f=$(claude_credentials_file)
  aside=$f$CLAUDE_CREDENTIALS_ASIDE_SUFFIX
  if ! (umask 077 && jq '{claudeAiOauth}' "$f" | write_if_changed "$aside" 0600 >/dev/null) \
     || ! rest=$(jq -c 'del(.claudeAiOauth)' "$f"); then
    warn "could not set the stored claude.ai login in $f aside; Claude's daemon will drop CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  if [ "$rest" = '{}' ]; then rm -f "$f"; else printf '%s\n' "$rest" | write_if_changed "$f" 0600 >/dev/null; fi \
    || { warn "could not remove the stored claude.ai login from $f"; return 0; }
  ok "CLAUDE_AUTH=token: moved the stored claude.ai login out of ~/.claude/.credentials.json (now ~/.claude/.credentials.json$CLAUDE_CREDENTIALS_ASIDE_SUFFIX), so Claude's daemon keeps CLAUDE_CODE_OAUTH_TOKEN"
}

# PIDs of the running Claude daemons (`claude daemon run …`, as Claude spawns
# it), one per line. /proc is read through host_path so tests can fake it.
claude_daemon_pids() {
  local d i argv=()
  for d in "$(host_path /proc)"/[0-9]*; do
    mapfile -d '' -t argv < "$d/cmdline" 2>/dev/null || continue
    [[ "${argv[0]:-} ${argv[1]:-}" == *claude* ]] || continue
    for i in "${!argv[@]}"; do
      if [ "${argv[i]}" = daemon ] && [ "${argv[i+1]:-}" = run ]; then echo "${d##*/}"; break; fi
    done
  done
}

# Problems with a running daemon that lacks CLAUDE_CODE_OAUTH_TOKEN, one per
# line. A daemon whose environment can't be read is not reported.
claude_daemon_token_problems() {
  local pid env
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    env="$(host_path /proc)/$pid/environ"
    [ -r "$env" ] || continue
    tr '\0' '\n' < "$env" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.' && continue
    echo "Claude's daemon (pid $pid) has no CLAUDE_CODE_OAUTH_TOKEN, so background sessions, including the first mate's, can't use the setup-token; once the stored login is gone, run: claude daemon stop --any (it ends the background sessions), then start Claude again"
  done < <(claude_daemon_pids)
}

# Checks used by doctor in token mode: prints one problem per line, nothing
# when all is well.
claude_token_mode_problems() {
  claude_token_mode_active || return 0
  if claude_stored_login_present; then
    echo "a stored claude.ai login is in ~/.claude/.credentials.json, so Claude's daemon drops CLAUDE_CODE_OAUTH_TOKEN and background sessions can say \"Not logged in\"; run: devenv start (it moves the login aside)"
  fi
  claude_daemon_token_problems
}

# Everything §6.4 re-applies: files, settings merge, CLAUDE.md, integrations.
# Serialized with a lock, because `devenv start` (a detached startup hook) and
# `devenv entry` may both run it at the same moment. Both run it before the
# first mate starts, so the token-mode cleanup comes first: before anything
# below runs claude.
apply_claude_config() {
  local integrations=${1:-with-integrations}
  mkdir -p "$DEVENV_CACHE"
  (
    if have flock; then flock -w 30 9 || warn "timed out waiting for $DEVENV_CACHE/claude-apply.lock"; fi
    claude_drop_stored_login
    write_paths_env
    install_claude_files
    render_claude_md | write_if_changed "$HOME/.claude/CLAUDE.md" 0644 >/dev/null
    [ "$integrations" = with-integrations ] && run_integrations
    # Merge last: the integration commands above rewrite settings.json too.
    merge_claude_settings >/dev/null
  ) 9>"$DEVENV_CACHE/claude-apply.lock"
}

link_claude_memory() {
  bash "$HOME/.claude/hooks/devenv-memory-link.sh" --all
}

# Checks used by doctor: prints one problem per line, nothing when all is well.
claude_config_problems() {
  local f=$HOME/.claude/settings.json m
  [ -f "$f" ] || { echo "~/.claude/settings.json is missing"; return 0; }
  [ "$(jq -r '.statusLine.command // empty' "$f")" = "$(jq -r '.statusLine.command' "$CLAUDE_AGENT_DIR/settings.overlay.json")" ] \
    || echo "statusLine in ~/.claude/settings.json is not devenv's wrapper"
  for m in $CLAUDE_EFFORT_MODELS; do
    [ "$(jq -r --arg m "$m" '.modelSettings[$m].effortLevel // empty' "$f")" = "$CLAUDE_EFFORT_DEFAULT" ] \
      || echo "modelSettings.$m.effortLevel is not $CLAUDE_EFFORT_DEFAULT"
  done
  jq -e '[.hooks.SessionStart[]?.hooks[]?.command // ""] | any(contains("/.claude/hooks/devenv-memory-link.sh"))' "$f" >/dev/null \
    || echo "devenv memory hook missing from ~/.claude/settings.json"
  [ -f "$HOME/.claude/statusline-command.sh" ] && [ "$(file_sha256 "$HOME/.claude/statusline-command.sh")" = "$STATUSLINE_SHA256" ] \
    || echo "~/.claude/statusline-command.sh is missing or its sha256 is not $STATUSLINE_SHA256"
  cmp -s "$HOME/.claude/statusline.sh" "$CLAUDE_AGENT_DIR/statusline.sh" || echo "~/.claude/statusline.sh differs from devenv's"
  for m in "$DEVENV_ROOT"/skills/*/; do
    [ -f "$m/SKILL.md" ] || continue
    m=${m%/}
    [ "$(readlink "$HOME/.claude/skills/${m##*/}" 2>/dev/null)" = "$m" ] \
      || echo "skill ${m##*/} is not linked into ~/.claude/skills (devenv start links it)"
  done
  return 0
}

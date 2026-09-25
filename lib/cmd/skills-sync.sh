# shellcheck shell=bash
# devenv skills-sync: put devenv/skills into sbx's shared skills store (host).
#
# `sbx skills import` copies every skill folder it finds in ~/.claude/skills.
# To import only devenv's skills, and never touch the owner's own
# ~/.claude/skills, it runs with HOME pointed at a staging folder that holds
# just devenv's skills. sbx's own config and state folders are kept by
# passing the real XDG_CONFIG_HOME/XDG_STATE_HOME. If that import fails, the
# skills are copied straight into the store folder that the sbx docs name
# (~/.local/state/sandboxes/sandboxes/agent-skills on Linux).
#
# Skills devenv synced before but that are no longer in the repo are removed
# with `sbx skills rm --force`. The list of names devenv manages is kept in
# ~/.config/devenv/skills-managed on the host.

sbx_skills_store_dir() {
  printf '%s/sandboxes/sandboxes/agent-skills' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

cmd_skills_sync() {
  local stage s name names=() managed old store method=import
  have sbx || { warn "sbx is not installed; skills not synced"; return 1; }
  stage=$(mktemp -d)
  mkdir -p "$stage/.claude/skills"
  for s in "$DEVENV_ROOT"/skills/*/; do
    [ -f "$s/SKILL.md" ] || continue
    s=${s%/}; name=${s##*/}
    cp -R "$s" "$stage/.claude/skills/$name"
    names+=("$name")
  done
  local cfg=${XDG_CONFIG_HOME:-$HOME/.config} st=${XDG_STATE_HOME:-$HOME/.local/state}
  local cache=${XDG_CACHE_HOME:-$HOME/.cache} dcfg=${DOCKER_CONFIG:-$HOME/.docker}
  if ! HOME=$stage XDG_CONFIG_HOME=$cfg XDG_STATE_HOME=$st XDG_CACHE_HOME=$cache DOCKER_CONFIG=$dcfg \
       sbx skills import --force >"$stage/import.log" 2>&1; then
    method=copy
    store=$(sbx_skills_store_dir)
    warn "sbx skills import failed ($(tail -n 1 "$stage/import.log")); copying into $store instead"
    [ -d "$store" ] || { rm -rf "$stage"; warn "sbx skills store $store does not exist"; return 1; }
    for name in "${names[@]}"; do
      rm -rf "$store/$name.devenv-new"
      cp -R "$stage/.claude/skills/$name" "$store/$name.devenv-new"
      rm -rf "${store:?}/${name:?}"
      mv "$store/$name.devenv-new" "$store/$name"
    done
  fi
  mkdir -p "$HOME/.config/devenv"
  managed="$HOME/.config/devenv/skills-managed"
  if [ -f "$managed" ]; then
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      case " ${names[*]} " in *" $old "*) continue ;; esac
      if sbx skills rm --force "$old" >/dev/null 2>&1; then log "removed skill $old (deleted from devenv)"
      elif [ "$method" = copy ] && [ -d "$(sbx_skills_store_dir)/$old" ]; then rm -rf "$(sbx_skills_store_dir)/${old:?}"; log "removed skill $old"
      else warn "could not remove skill $old from the sbx store"; fi
    done < "$managed"
  fi
  printf '%s\n' "${names[@]}" > "$managed"
  rm -rf "$stage"
  ok "skills in the sbx store ($method): ${names[*]}"
}

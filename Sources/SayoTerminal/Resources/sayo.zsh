# Sayo ZLE integration. Ctrl-X Ctrl-R rewrites the editable command buffer.
function __sayo_rewrite_widget() {
  # The app intentionally rejects blank input. Keep an empty/whitespace-only
  # command line untouched instead of invoking the bridge and showing errors.
  if [[ -z "${BUFFER//[[:space:]]/}" ]]; then
    return 0
  fi

  local -a sayo_args
  sayo_args=(rewrite --cursor "$CURSOR")

  if (( REGION_ACTIVE )); then
    local selection_start="$MARK"
    local selection_end="$CURSOR"
    if (( selection_start > selection_end )); then
      local swap="$selection_start"
      selection_start="$selection_end"
      selection_end="$swap"
    fi
    sayo_args+=(--selection-start "$selection_start" --selection-length "$((selection_end - selection_start))")
  fi

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/sayo-rewrite.XXXXXXXX")" || return 1
  if command "$SAYO_CLI" "${sayo_args[@]}" >| "$output_file" < <(printf %s "$BUFFER"); then
    local rewritten=""
    IFS= read -r -d '' rewritten < "$output_file" || true
    BUFFER="$rewritten"
    CURSOR="${#BUFFER}"
    REGION_ACTIVE=0
  else
    zle -M "Sayo could not rewrite this command; the original buffer was kept."
  fi
  command rm -f -- "$output_file"
}

zle -N sayo-rewrite __sayo_rewrite_widget
bindkey '^X^R' sayo-rewrite
# Ghostty's Kitty keyboard protocol may encode the synthetic control keys as
# CSI-u sequences. Modifier 5 is Ctrl; modifier 6 can appear while Shift state
# is being released with the global shortcut.
bindkey $'\e[120;5u\e[114;5u' sayo-rewrite
bindkey $'\e[120;6u\e[114;6u' sayo-rewrite

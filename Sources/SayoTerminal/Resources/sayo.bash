# Sayo Readline integration. Ctrl-X Ctrl-R rewrites the editable command buffer.
# Bash 3.2 can bind commands but cannot expose or replace READLINE_LINE.
if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s\n' 'Sayo Terminal Integration requires Bash 4 or newer. Use zsh or a newer Bash; your bindings were left unchanged.' >&2
  return 0
fi

# Login profiles may already source .bashrc. Install the binding once in each
# shell; do not export this flag, since child Bash processes need their own bind.
if [[ ${__SAYO_BASH_LOADED-} == 1 ]]; then
  return 0
fi

function __sayo_rewrite_widget() {
  # The app intentionally rejects blank input. Keep an empty/whitespace-only
  # command line untouched instead of invoking the bridge and showing errors.
  if [[ -z "${READLINE_LINE//[[:space:]]/}" ]]; then
    return 0
  fi

  local output_file rewritten status
  local -a sayo_args
  sayo_args=(rewrite --cursor-byte "$READLINE_POINT")
  output_file="$(mktemp "${TMPDIR:-/tmp}/sayo-rewrite.XXXXXXXX")" || return 1

  if command "$SAYO_CLI" "${sayo_args[@]}" > "$output_file" < <(printf %s "$READLINE_LINE"); then
    status=0
    rewritten=""
    IFS= read -r -d '' rewritten < "$output_file" || true
    READLINE_LINE="$rewritten"
    # Readline's rl_point is a byte offset even in a multibyte locale. Keep
    # the locale override local and apply it only after the CLI has returned.
    local LC_ALL=C
    READLINE_POINT="${#READLINE_LINE}"
  else
    status=$?
  fi
  command rm -f -- "$output_file"
  return "$status"
}

if bind -x '"\C-x\C-r":__sayo_rewrite_widget' \
    && bind -x '"\e[120;5u\e[114;5u":__sayo_rewrite_widget' \
    && bind -x '"\e[120;6u\e[114;6u":__sayo_rewrite_widget'; then
  __SAYO_BASH_LOADED=1
fi

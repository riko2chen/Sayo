# Sayo fish integration. Ctrl-X Ctrl-R rewrites the editable command buffer.
function __sayo_rewrite_widget
    # commandline appends one newline. Collect without splitting or trimming,
    # then capture everything except that one newline (including empty input).
    # https://github.com/fish-shell/fish-shell/blob/master/src/builtins/commandline.rs
    # https://fishshell.com/docs/current/cmds/string.html
    set -l printed_buffer (commandline --current-buffer | string collect --no-trim-newlines)
    set -l buffer
    string match --regex --quiet '(?s)\A(?<buffer>.*)\n\z' -- "$printed_buffer"
    or return 1
    # The app intentionally rejects blank input. Keep an empty/whitespace-only
    # command line untouched instead of invoking the bridge and showing errors.
    string match --regex --quiet '(?s)\A[[:space:]]*\z' -- "$buffer"
    and return 0
    set -l cursor (commandline --cursor)
    or return 1
    set -l temp_directory /tmp
    if set -q TMPDIR; and test -n "$TMPDIR"
        set temp_directory "$TMPDIR"
    end
    set -l output_file (command mktemp "$temp_directory/sayo-rewrite.XXXXXXXX")
    or return 1

    printf %s "$buffer" | command "$SAYO_CLI" rewrite --cursor "$cursor" > "$output_file"
    set -l rewrite_status $pipestatus[2]
    if test "$rewrite_status" -eq 0
        set -l rewritten (string collect --allow-empty --no-trim-newlines < "$output_file")
        commandline --replace -- "$rewritten"
        commandline --cursor (string length -- "$rewritten")
    end
    command rm -f -- "$output_file"
    return "$rewrite_status"
end

bind \cx\cr __sayo_rewrite_widget
bind \e\[120\;5u\e\[114\;5u __sayo_rewrite_widget
bind \e\[120\;6u\e\[114\;6u __sayo_rewrite_widget

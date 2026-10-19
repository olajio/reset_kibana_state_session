# Summarise one or more reset_kibana_state_session.sh CSV reports (merged into
# one file with a single header row) across every deployment in the run.
#
#   awk -v mode=dry-run|execute -f summarize_report.awk report.csv
#
# Columns: deployment,space_id,space_name,value_before,action,detail. Every
# field is double-quoted with embedded quotes doubled, so fields are parsed
# properly rather than split on commas (error details can contain commas).
# Portable awk only (mawk, gawk, BSD awk).

function parse_csv(line,    n, i, c, f, in_quotes, len) {
    n = 0; f = ""; in_quotes = 0; len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (in_quotes) {
            if (c == "\"") {
                if (i < len && substr(line, i + 1, 1) == "\"") { f = f "\""; i++ }
                else in_quotes = 0
            } else {
                f = f c
            }
        } else if (c == "\"") {
            in_quotes = 1
        } else if (c == ",") {
            field[++n] = f; f = ""
        } else {
            f = f c
        }
    }
    field[++n] = f
    return n
}

BEGIN {
    deployments = 0; bad_deployments = 0; problems = 0
    split("reset already-false would-reset skipped reset-unverified failed", actions, " ")
    for (a in actions) count[actions[a]] = 0
}

FNR == 1 { next }                            # header row

{
    sub(/\r$/, "")
    if ($0 == "" || parse_csv($0) != 6) next
    deployment = field[1]; space = field[2]; action = field[5]; detail = field[6]

    count[action]++
    if (!(deployment in seen)) { seen[deployment] = 1; deployments++ }
    if (action == "failed" || action == "reset-unverified") {
        if (!(deployment in bad)) { bad[deployment] = 1; bad_deployments++ }
        problem[++problems] = sprintf("  %-16s %s / %s: %s", toupper(action), deployment, space, detail)
    }
}

END {
    print "================================================================"
    print " RUN SUMMARY - state:storeInSessionStorage (" (mode == "" ? "?" : mode) ")"
    print "================================================================"
    printf "  deployments in report     : %d\n", deployments
    printf "  deployments with failures : %d\n", bad_deployments
    printf "  spaces reset to false     : %d\n", count["reset"]
    printf "  spaces already false      : %d\n", count["already-false"]
    if (mode == "dry-run")
        printf "  spaces needing reset      : %d  (dry run - nothing was changed)\n", count["would-reset"]
    printf "  spaces skipped            : %d\n", count["skipped"]
    printf "  spaces reset, unverified  : %d\n", count["reset-unverified"]
    printf "  failures                  : %d\n", count["failed"]
    if (problems > 0) {
        print ""
        print "Needs attention:"
        for (p = 1; p <= problems; p++) print problem[p]
    }
}

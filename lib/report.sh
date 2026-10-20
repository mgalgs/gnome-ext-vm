# shellcheck shell=bash
# HTML report for a matrix run.
#
# Usage: write_report <label_dir> <vm...>
# Reads LABEL, BASELINE, PROJECT_ROOT and the RESULTS, GNOME_VERSIONS,
# DURATIONS and DOMAINS associative arrays set by cmd_matrix.

html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

placeholder() {
    cat << EOF
    <div class="screenshot-box">
      <div style="padding:40px;text-align:center;color:#999;border:1px dashed #ddd;border-radius:4px;">$1</div>
      <div class="caption">$2</div>
    </div>
EOF
}

shot_box() {
    cat << EOF
    <div class="screenshot-box">
      <img src="$1" alt="$2">
      <div class="caption">$2</div>
    </div>
EOF
}

write_report() {
    local dir="$1" vm result badge base img name
    shift
    local pass=0 fail=0 skip=0
    for vm in "$@"; do
        case "${RESULTS[$vm]:-SKIP}" in
            PASS) pass=$((pass + 1)) ;;
            FAIL) fail=$((fail + 1)) ;;
            *) skip=$((skip + 1)) ;;
        esac
    done

    {
        cat << 'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>VM Test Matrix Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #333; }
  .meta { color: #666; margin-bottom: 20px; }
  .summary { display: flex; gap: 20px; margin-bottom: 30px; }
  .summary-card { padding: 15px 25px; border-radius: 8px; color: white; font-size: 1.2em; }
  .pass { background: #2ea043; }
  .fail { background: #cf222e; }
  .skip { background: #888; }
  .vm-card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .vm-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; }
  .vm-title { font-size: 1.3em; font-weight: bold; }
  .badge { padding: 4px 12px; border-radius: 12px; color: white; font-size: 0.85em; }
  .screenshots { display: flex; gap: 20px; flex-wrap: wrap; }
  .screenshot-box { flex: 1; min-width: 300px; }
  .screenshot-box img { width: 100%; border: 1px solid #ddd; border-radius: 4px; }
  .screenshot-box .caption { text-align: center; color: #666; margin-top: 5px; font-size: 0.9em; }
  .log-preview { background: #1e1e1e; color: #d4d4d4; padding: 12px; border-radius: 4px; font-family: monospace; font-size: 0.85em; max-height: 200px; overflow-y: auto; white-space: pre-wrap; margin-top: 10px; }
  .duration { color: #888; font-size: 0.9em; }
</style>
</head>
<body>
<h1>VM Test Matrix Report</h1>
<div class="meta">
EOF
        echo "  <strong>Label:</strong> $LABEL<br>"
        echo "  <strong>Git:</strong> $(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null | html_escape || echo unknown)<br>"
        echo "  <strong>Date:</strong> $(date '+%Y-%m-%d %H:%M:%S')<br>"
        [[ -n "$BASELINE" ]] && echo "  <strong>Baseline:</strong> $BASELINE<br>"
        cat << EOF
</div>

<div class="summary">
  <div class="summary-card pass">$pass PASS</div>
  <div class="summary-card fail">$fail FAIL</div>
  <div class="summary-card skip">$skip SKIP</div>
</div>
EOF

        for vm in "$@"; do
            result="${RESULTS[$vm]:-SKIP}"
            badge=skip
            [[ "$result" == PASS ]] && badge=pass
            [[ "$result" == FAIL ]] && badge=fail
            cat << EOF
<div class="vm-card">
  <div class="vm-header">
    <span class="vm-title">$vm <span style="color:#888; font-weight:normal;">(GNOME ${GNOME_VERSIONS[$vm]:-?})</span></span>
    <span>
      <span class="badge $badge">$result</span>
      <span class="duration">${DURATIONS[$vm]:-0}s</span>
    </span>
  </div>
  <div class="screenshots">
EOF
            if [[ -n "$BASELINE" ]]; then
                # A baseline from before a VM was adopted is named by its domain.
                base=""
                for name in "$vm" "${DOMAINS[$vm]:-}"; do
                    if [[ -n "$name" && -f "$dir/../$BASELINE/$name.png" ]]; then
                        base="../$BASELINE/$name.png"
                        break
                    fi
                done
                if [[ -n "$base" ]]; then
                    shot_box "$base" "Baseline ($BASELINE)"
                else
                    placeholder "No baseline screenshot" "Baseline ($BASELINE)"
                fi
            fi
            if [[ -f "$dir/$vm.png" ]]; then
                shot_box "$vm.png" "Current ($LABEL)"
            else
                placeholder "No screenshot" "Current ($LABEL)"
            fi
            for img in "$dir/${vm}_"*.png; do
                [[ -f "$img" ]] || continue
                name=$(basename "$img" .png)
                shot_box "$(basename "$img")" "${name#"${vm}_"}"
            done
            echo "  </div>"
            if [[ -f "$dir/$vm.log" ]]; then
                echo "  <div class=\"log-preview\">$(head -30 "$dir/$vm.log" | html_escape)</div>"
            fi
            echo "</div>"
        done
        printf '</body>\n</html>\n'
    } > "$dir/report.html"
    log_ok "Report saved: $dir/report.html"
}

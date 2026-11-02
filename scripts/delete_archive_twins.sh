#!/usr/bin/env bash
# Delete the 35 -archive-2026-07-17 twin repos to reclaim ~3.67 GB of LFS storage.
#
# VERIFICATION (2026-07-22, audit/twin_verify.json):
#   34/35 twins: every branch/tag ref present in the source repo.
#   prenatal-care-toolkit twin: DIVERGED (source force-pushed after twin
#     creation) — full mirror bundled to
#     ~/repos/branch-archives/prenatal-care-toolkit-archive-twin_full_2026-07-22.bundle
#   ev-battery-management-sim twin: source history was intentionally rewritten
#     2026-07-22 (Kaggle de-hosting); pre-rewrite bundle at
#     ~/repos/branch-archives/evsim-full-pre-rewrite_2026-07-22.bundle
#
# LFS: twins duplicate every LFS object (namespaces are per-repo). Deleting a
# repo is the ONLY way GitHub frees its LFS storage. Expected: 12.58 -> ~8.9 GB.
#
# Prereq (one-time): the delete_repo scope
#   gh auth refresh -h github.com -s delete_repo
#
# This script is intentionally NOT run by automation. Run it yourself:
#   scripts/delete_archive_twins.sh          # dry run (prints what it would do)
#   scripts/delete_archive_twins.sh --run    # actually delete
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/delete_archive_twins.sh [--run]
  (no flag)  dry run: print the repos that would be deleted, exit 0
  --run      delete every twin listed below via 'gh repo delete --yes'
Any other argument is treated as a dry run."

TWINS=(
  BazaarTalks-archive-2026-07-17
  Bazartalks_Py2Cplus-archive-2026-07-17
  Merlin-archive-2026-07-17
  bms-battery-management-archive-2026-07-17
  claude-lmstudio-router-archive-2026-07-17
  claude-stock-tools-archive-2026-07-17
  colab-experiments-archive-2026-07-17
  colab-market-fundamentals-archive-2026-07-17
  data_validator-archive-2026-07-17
  discom-debt-and-revenue-models-archive-2026-07-17
  europe-stock-screener-archive-2026-07-17
  ev-battery-management-sim-archive-2026-07-17
  event-driven-stock-analysis-archive-2026-07-17
  fuel-retail-outlets-archive-2026-07-17
  global-market-data-archive-2026-07-17
  global-stock-screener-archive-2026-07-17
  global-ticker-universe-archive-2026-07-17
  heart-valve-defect-detection-archive-2026-07-17
  hydrogen-electrolyser-control-archive-2026-07-17
  india-election-analysis-archive-2026-07-17
  india-forex-analysis-archive-2026-07-17
  india-trade-export-analysis-archive-2026-07-17
  interpreter_toolkit-archive-2026-07-17
  karz-archive-2026-07-17
  ltm-warehouse-tests-archive-2026-07-17
  market-data-artifacts-archive-2026-07-17
  piotroski-liquidity-research-archive-2026-07-17
  prenatal-care-toolkit-archive-2026-07-17
  saf-monitoring-system-archive-2026-07-17
  stock-portfolio-evaluator-archive-2026-07-17
  stock-screener-ddd-archive-2026-07-17
  stock-screener-platform-archive-2026-07-17
  toll-plaza-highways-archive-2026-07-17
  tools-handling_data-archive-2026-07-17
  working-files-archive-2026-07-17
)

delete_twin() {  # delete_twin <index> <total> <repo>
  echo "[$1/$2] deleting $GH_OWNER/$3"
  gh repo delete "$GH_OWNER/$3" --yes
}

main() {
  usage_if_requested "$USAGE" "$@"
  local mode="${1:-dry}" total=${#TWINS[@]} n=0 t
  for t in "${TWINS[@]}"; do
    n=$((n + 1))
    if [ "$mode" = "--run" ]; then
      delete_twin "$n" "$total" "$t"
    else
      echo "[dry] would delete $GH_OWNER/$t"
    fi
  done
  [ "$mode" = "--run" ] || echo "Dry run only. Re-run with --run to delete. Needs: gh auth refresh -h github.com -s delete_repo"
}

main "$@"

# Library chart evaluation: asa-runtime-common
#
# Trigger (documented in tests/chart-drift.sh): extract when a third chart appears
# or the same shared-template fix is applied twice.
#
# Decision (2026-09-30, architecture consolidation): DEFER.
#
# Shared primitives today (byte-identical, guarded by chart-drift.sh):
#   _workloadidentity.tpl, _labels.tpl, serviceaccount.yaml, externalsecret.yaml,
#   configmap.yaml, wif-credentials.yaml
#
# Why not now:
#   1. Only two consumers. Drift guard already fails CI on divergence.
#   2. Deploy path installs charts from a checked-out directory
#      (helm upgrade … "${CHART_DIR}"). A library chart forces either
#      `helm dependency build` on the agent or vendoring charts/*.tgz —
#      both are new operational surface for no bug class we currently have.
#   3. Identity/cloud knowledge lives in those shared files; extracting them
#      does not shrink the cloud surface, it only relocates the duplication.
#
# Gatilho concreto para reabrir:
#   - charts/asa-* grows to a third chart, OR
#   - the same fix lands in both charts twice within a quarter
#      (chart-drift.sh already says so).
#
# When extracting: bump both application charts, add Chart.yaml dependencies,
# and teach helm-deploy.yml + ci.yml to run `helm dependency build` (or ship
# the packaged .tgz alongside the templates checkout).

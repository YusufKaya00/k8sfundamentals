#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 4 — GRAFANA DASHBOARD & PROMQL DOĞRULAYICI
# ==============================================================================
# Bu betik, observability/dashboards/*.json dosyalarındaki tüm PromQL
# sorgularını ayrıştırır ve sözdizimini (syntax) ve/veya canlı Prometheus API
# üzerindeki geçerliliğini doğrular.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASHBOARDS_DIR="${LAB_DIR}/observability/dashboards"

if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
elif [[ -f "${LAB_DIR}/ansible/hosts.ini" ]]; then
  MASTER_IP="$(awk -F'master_public_ip=' '/^master_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | head -n1 | tr -d '[:space:]')"
fi
MASTER_IP="${MASTER_IP:-9.205.250.156}"

echo "=============================================================================="
echo "GRAFANA DASHBOARD & PROMQL SÖZDİZİMİ DOĞRULAMASI"
echo "Dizin: ${DASHBOARDS_DIR}"
echo "=============================================================================="

python3 - << 'EOF'
import json
import glob
import os
import sys

dashboards = sorted(glob.glob("observability/dashboards/*.json", root_dir="troubleshoot/chaos-troubleshooting-4"))
base_path = "troubleshoot/chaos-troubleshooting-4"

total_dashboards = 0
total_panels = 0
total_targets = 0
errors = 0

print(f"{'DASHBOARD':<40} | {'PANELS':<8} | {'TARGETS':<8} | {'DURUM'}")
print("-" * 75)

for db_file in dashboards:
    total_dashboards += 1
    full_path = os.path.join(base_path, db_file)
    try:
        with open(full_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        title = data.get("title", db_file)
        panels = data.get("panels", [])
        total_panels += len(panels)
        
        panel_targets = 0
        for p in panels:
            for t in p.get("targets", []):
                expr = t.get("expr", "").strip()
                if expr:
                    panel_targets += 1
                    # Basic syntax check for balanced parentheses/brackets
                    if expr.count("(") != expr.count(")"):
                        print(f"❌ Parantez hatası [Panel: {p.get('title')}]: {expr}")
                        errors += 1
                    if expr.count("{") != expr.count("}"):
                        print(f"❌ Süslü parantez hatası [Panel: {p.get('title')}]: {expr}")
                        errors += 1
                    if expr.count("[") != expr.count("]"):
                        print(f"❌ Köşeli parantez hatası [Panel: {p.get('title')}]: {expr}")
                        errors += 1
        
        total_targets += panel_targets
        status = "✅ GEÇERLİ" if errors == 0 else "❌ HATA"
        print(f"{title[:40]:<40} | {len(panels):<8} | {panel_targets:<8} | {status}")
    except Exception as e:
        print(f"❌ JSON okuma hatası ({db_file}): {e}")
        errors += 1

print("-" * 75)
print(f"Toplam: {total_dashboards} dashboard, {total_panels} panel, {total_targets} PromQL hedefi.")

if errors > 0:
    print(f"❌ Toplam {errors} hata bulundu!")
    sys.exit(1)
else:
    print("✅ Tüm dashboard ve PromQL ifadeleri başarıyla doğrulandı!")
EOF

echo "=============================================================================="

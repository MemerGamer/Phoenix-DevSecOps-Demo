package deploy

import rego.v1

# ─────────────────────────────────────────────────────────────────
# Deploy policy for the Elixir Phoenix demo app
#
# Input (from gate evaluate):
#   input.attestations[]
#     .result.check_type  – "sast" | "sca" | "config"
#     .result.passed      – bool
#     .result.findings[]
#       .severity         – "critical" | "high" | "medium" | "low"
#
# Output consumed by gate:
#   allow        – bool  (data.deploy.allow)
#   deny_reasons – set   (data.deploy.deny_reasons → GateDecision.Reasons)
#
# Rules:
#   1. All three required checks must be present in the chain.
#   2. No critical findings are allowed in any check.
#   3. SAST and SCA must pass outright (passed == true).
#   4. Config scan may have low/medium findings but must have
#      no critical or high findings.
# ─────────────────────────────────────────────────────────────────

required_checks := {"sast", "sca", "config"}

# Collect the check types present in the attestation chain
present_checks := {a.result.check_type | a := input.attestations[_]}

# Allow deployment only when all conditions pass
default allow := false

allow if {
    missing_checks == set()
    count(critical_findings) == 0
    sast_passed
    sca_passed
}

# ── Missing checks ────────────────────────────────────────────────
missing_checks := required_checks - present_checks

# ── Critical findings across all checks ──────────────────────────
critical_findings := {f |
    a := input.attestations[_]
    f := a.result.findings[_]
    f.severity == "critical"
}

# ── SAST must pass ────────────────────────────────────────────────
sast_passed if {
    some a in input.attestations
    a.result.check_type == "sast"
    a.result.passed == true
}

# ── SCA must pass ─────────────────────────────────────────────────
sca_passed if {
    some a in input.attestations
    a.result.check_type == "sca"
    a.result.passed == true
}

# ── Deny reasons (read by gate as GateDecision.Reasons) ──────────
deny_reasons contains msg if {
    count(missing_checks) > 0
    msg := sprintf("Missing required checks: %v", [missing_checks])
}

deny_reasons contains msg if {
    count(critical_findings) > 0
    msg := sprintf("%d critical finding(s) found", [count(critical_findings)])
}

deny_reasons contains "SAST did not pass" if not sast_passed

deny_reasons contains "SCA did not pass" if not sca_passed

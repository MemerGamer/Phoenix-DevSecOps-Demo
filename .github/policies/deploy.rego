package deploy

import rego.v1

# ─────────────────────────────────────────────────────────────────
# Deploy policy for the Elixir Phoenix demo app
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
present_checks := {a.payload.check_type | a := input.chain[_]}

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
critical_findings := findings if {
    findings := {f |
        a := input.chain[_]
        f := a.payload.result.findings[_]
        f.severity == "critical"
    }
}

# ── SAST must pass ────────────────────────────────────────────────
sast_passed if {
    some a in input.chain
    a.payload.check_type == "sast"
    a.payload.result.passed == true
}

# ── SCA must pass ─────────────────────────────────────────────────
sca_passed if {
    some a in input.chain
    a.payload.check_type == "sca"
    a.payload.result.passed == true
}

# ── Decision object returned to the gate ─────────────────────────
decision := {
    "allow": allow,
    "missing_checks": missing_checks,
    "critical_findings": critical_findings,
    "sast_passed": sast_passed,
    "sca_passed": sca_passed,
    "reason": reason,
}

reason := "All checks passed. Deployment allowed." if allow

reason := concat("; ", messages) if {
    not allow
    messages := [m |
        v := violations[_]
        m := v
    ]
}

violations contains msg if {
    count(missing_checks) > 0
    msg := sprintf("Missing required checks: %v", [missing_checks])
}

violations contains msg if {
    count(critical_findings) > 0
    msg := sprintf("%d critical finding(s) found", [count(critical_findings)])
}

violations contains "SAST did not pass" if not sast_passed

violations contains "SCA did not pass" if not sca_passed

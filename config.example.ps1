# Example configuration for ado-workitem-quality.
# Copy this file to config.ps1 at the repo root and fill in the values.
# config.ps1 is gitignored: NEVER commit it, never paste its values into chat, docs or reviews.
# Keep this file pure ASCII (Windows PowerShell 5.1 parses BOM-less .ps1 files as Windows-1252).

# Azure DevOps organization and project (names, not URLs).
$env:ADO_ORG     = '<your-ado-organization>'
$env:ADO_PROJECT = '<your-ado-project>'

# Authentication: Git Credential Manager is tried FIRST (an Entra ID token from your own sign-in,
# which passes the organization's conditional access policies). The PAT below is only a
# FALLBACK, used when GCM is unavailable; leave it empty if GCM always works for you.
# Optional: $env:ADO_AUTH_MODE = 'Auto' (default) | 'Gcm' (never use the PAT) | 'Pat' (skip GCM).
# Personal Access Token. Minimum scope: Work Items (Read). Set an expiration date.
# The review pipeline only reads from ADO; it never needs write scope.
$env:ADO_PAT     = '<your-personal-access-token>'

# Power Automate "Workflows" webhook that posts to the Teams channel (monitor only).
$env:TEAMS_WEBHOOK_URL = '<your-teams-workflow-webhook-url>'

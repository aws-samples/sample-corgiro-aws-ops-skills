# Remediation References

The AWS doc link cited at the end of each remediation in the report. Render each as `<a href="<url>" target="_blank" rel="noopener">docs</a>` — these URLs are authored content, not resource data. If a finding has no row here, omit the link; never guess or construct a URL. Extend this table only with URLs checked against the live AWS documentation.

| Finding / remediation topic | AWS documentation |
| --- | --- |
| Root MFA; root access keys | https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html |
| Admin users/roles; overly permissive policies; wildcard principals; unused policies (least privilege) | https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html |
| Stale, unused, or unrotated access keys | https://docs.aws.amazon.com/IAM/latest/UserGuide/id-credentials-access-keys-update.html |
| Console user without MFA | https://docs.aws.amazon.com/IAM/latest/UserGuide/gs-identities-mfa.html |
| Cross-account trust without `sts:ExternalId` (confused deputy) | https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html |
| No or weak account password policy | https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_passwords_account-policy.html |
| No IAM Access Analyzer | https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html |
| Permissions boundary (context on admin findings) | https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html |
| Automation/CI key → OIDC federation | https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html |
| Keyless on EKS pods (IRSA) | https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html |
| Keyless for on-prem / non-AWS workloads (Roles Anywhere) | https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_non-aws.html |
| SES SMTP credential | https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html |
| Bedrock API key | https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html |
| CodeCommit Git credential → `git-remote-codecommit` | https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-git-remote-codecommit.html |

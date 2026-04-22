# COSTS — Free Tier compliance

Prices are US East (N. Virginia), USD, as of April 2026. Source:
<https://aws.amazon.com/free/> and the AWS pricing pages linked per row.

## What I'm using from the Free Tier

| Service | What I use | Free Tier allowance (first 12 months) | Expected monthly usage | Cost |
|---|---|---|---|---|
| EC2 | 1× t2.micro, running 24×7 | 750 h/mo of t2.micro *or* t3.micro | 720–744 h/mo | $0.00 |
| EBS | 8 GiB gp3 root volume, encrypted | 30 GiB gp3 (+ snapshots) | 8 GiB | $0.00 |
| EBS snapshots | 0 scheduled | 1 GiB | 0 | $0.00 |
| Data transfer out | ~100 KB/day (monitor + defence call curl) | 100 GB/mo | <1 MB/mo | $0.00 |
| SSM Agent / Session Manager / RunCommand | All deploys via SSM | Free | all usage | $0.00 |
| SSM Parameter Store (Standard) | 0 parameters (we use GitHub Vars/Secrets) | 10k params free | 0 | $0.00 |
| CloudWatch | Default basic metrics (5-min) | 10 custom metrics, 1M API requests | basic only | $0.00 |
| CloudTrail | Default management events | 1 trail of management events free | basic only | $0.00 |
| IAM + IAM OIDC provider | 1 OIDC provider, 2 roles, a handful of policies | Free (always) | — | $0.00 |
| VPC (default) + public IPv4 | 1 public IPv4 attached while instance is running | **$3.65/mo after Feb 2024** for a public IPv4 *unless it's attached to a running Free-Tier EC2* | 1 | **See below** |

**Total expected monthly bill: $0.00**, provided the instance stays running
continuously. A stopped instance with a detached public IPv4 accrues
$0.005/h per IP since AWS's Feb 2024 pricing change, which works out to
about $3.65/mo. Don't stop-and-leave-it.

## What I deliberately did NOT use

Each of these costs money on the Free Tier and has been substituted with a
free-or-cheaper equivalent:

| Paid service | Why it's tempting | What I did instead |
|---|---|---|
| Application Load Balancer | Nice for TLS + WAF | Direct IP:777 for this demo. Production would add ALB + ACM (free cert, ALB ~$16/mo). |
| ECR | "Native" image registry for ECS/EKS | GHCR — public, free, no egress cost. |
| AWS WAF | L7 rate limiting and rules | Omitted; called out as a residual risk in `SECURITY.md`. |
| GuardDuty | Threat detection | First 30 days free only. Called out as a residual risk. |
| CloudWatch Logs | Centralised app logs | journald on the host; a production deploy would ship to Logs (~$0.50/GB ingest). |
| Detailed EC2 monitoring | 1-minute metrics | Default basic 5-minute is free and sufficient at this scale. |
| NAT Gateway | Private subnet egress | Public subnet + SG egress allow-list — same security posture for this scope at $0 vs $33/mo. |
| AWS Config | Continuous compliance scanning | Checkov + tflint in CI, run locally. |

## How to prove it in the defence call

```bash
# From any AWS account viewer
aws ce get-cost-and-usage \
  --time-period Start=2026-04-01,End=2026-05-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE

# If anything shows non-zero, I broke the budget; the alert below catches it.
```

I'd also set a Cost Anomaly Alert in any real deployment:

```bash
aws budgets create-budget \
  --account-id <id> \
  --budget 'BudgetName=bluegrid-demo,BudgetLimit={Amount=1,Unit=USD},TimeUnit=MONTHLY,BudgetType=COST'
```

A $1 monthly budget with email notification is enough to catch a leak the
day it starts.

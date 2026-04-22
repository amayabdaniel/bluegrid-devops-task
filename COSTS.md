# Costs

Prices are us-east-1, USD, April 2026. Source: https://aws.amazon.com/free/ and the AWS pricing pages.

## What I use

| Service | Usage | Free tier (12 mo) | Expected | Cost |
|---|---|---|---|---|
| EC2 | 1x t2.micro 24x7 | 750 h/mo t2/t3.micro | 720-744 h | $0.00 |
| EBS | 8 GiB gp3, encrypted | 30 GiB gp3 | 8 GiB | $0.00 |
| EBS snapshots | 0 | 1 GiB | 0 | $0.00 |
| Data transfer out | ~100 KB/day | 100 GB/mo | <1 MB/mo | $0.00 |
| SSM Agent / Session Manager / RunCommand | All deploys | free | all | $0.00 |
| SSM Parameter Store (std) | 0 params | 10k params free | 0 | $0.00 |
| CloudWatch | basic 5-min | 10 metrics, 1M reqs | basic only | $0.00 |
| CloudTrail | management events | 1 trail free | basic | $0.00 |
| IAM + OIDC | 1 provider, 2 roles | free | - | $0.00 |
| VPC (default) + public IPv4 | 1 public IPv4 while running | see below | 1 | $0.00 |

Total expected monthly bill: $0.00, provided the instance stays running continuously. A stopped instance with a detached public IPv4 accrues $0.005/h per IP after Feb 2024 pricing. Don't stop-and-leave-it.

## Deliberately unused

| Service | Why it's tempting | What I did instead |
|---|---|---|
| Application Load Balancer | TLS, WAF | Direct IP:777. Production would add ALB + ACM (free cert) |
| ECR | Native AWS | GHCR (public, free, no egress cost) |
| AWS WAF | L7 rate limiting | Omitted, documented as residual risk |
| GuardDuty | Threat detection | First 30 days free only, documented as residual risk |
| CloudWatch Logs | Centralised logs | journald on host; production would ship (~$0.50/GB) |
| Detailed EC2 monitoring | 1-min metrics | Default 5-min is free |
| NAT Gateway | Private subnet egress | Public subnet + SG egress allowlist ($0 vs $33/mo) |
| AWS Config | Continuous compliance | Checkov + tflint in CI |

## How to prove it

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-04-01,End=2026-05-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE

# $1 monthly budget with email alert catches any leak:
aws budgets create-budget \
  --account-id <id> \
  --budget 'BudgetName=bluegrid-demo,BudgetLimit={Amount=1,Unit=USD},TimeUnit=MONTHLY,BudgetType=COST'
```

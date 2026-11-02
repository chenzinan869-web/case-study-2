# Innovatech hybrid cloud – technical implementation, PaaS where it makes sense (CS2-MA-NCA)

Hybrid environment: the on-premise network (workstations, Suricata IDS, Alloy agents, Ansible node) is connected through a firewall and an AWS Site-to-Site VPN to an AWS VPC with 2 AZs.

**PaaS / managed services (no servers to patch):** SOAR on ECS Fargate (+ ECR, Cloud Map, application autoscaling), RDS PostgreSQL Multi-AZ, Network Load Balancer, Route 53, Secrets Manager, CloudWatch Logs, S3.
**IaaS (on purpose):** Grafana (EC2 ASG), Loki + Prometheus (EC2), because AWS has no managed Loki and the monitoring stack must stay compatible with the on-prem Alloy agents. On-prem hosts stay on-prem (Suricata, Alloy).

| Diagram / assignment item | Where it is implemented |
|---|---|
| VPC, 2 AZs, subnets A/B/C (REQ-02, 03) | `terraform/network.tf` |
| VPN gateway, route tables, SGs, Route 53 (REQ-04) | `terraform/vpn.tf`, `network.tf`, `security.tf` |
| IaC + Ansible for on-prem and updates (REQ-05) | `terraform/`, `ansible/`, `ansible/patch.yml` |
| Grafana, Loki + Prometheus, S3 (REQ-06, 07) | `terraform/compute.tf`, `ansible/roles/monitoring_stack` |
| Alloy agents, Suricata logs (REQ-07, 08) | `ansible/roles/alloy`, `ansible/roles/suricata` |
| SOAR: PaaS container behind NLB (REQ-08, 09) | `terraform/ecs.tf`, `compute.tf` (NLB), `soar/` |
| More robust and scalable database | `terraform/database.tf` (Multi-AZ, backups, storage autoscaling) |
| Monitoring covers the SOAR itself | `/metrics` in `soar/app.py`, scrape job in `prometheus.yml.j2`, Cloud Map in `ecs.tf` |
| Scalability | Fargate autoscaling 2–6 tasks on CPU (`ecs.tf`) |
| GitHub Actions + self-hosted runner (REQ-10, 11, 12) | `.github/workflows/` (terraform, ansible, soar container, weekly patching) |

> The code was written but not run against a real AWS account. Expect to fix small things during the first `terraform plan` and first Ansible run.

## Prerequisites
- AWS account + IAM user for Terraform, AWS CLI configured on the Ansible node
- On-prem Ubuntu 24.04 machine = Ansible node + GitHub runner, **with Docker installed** (`sudo apt install -y docker.io` and `sudo usermod -aG docker <runner user>`), and a firewall with a public IP that supports IPsec
- GitHub repository containing this folder
- On the Ansible node: `sudo apt install -y ansible python3-boto3 unzip`, Terraform ≥ 1.10

## Step 1 – Bootstrap the Terraform state bucket (once)
```bash
aws s3api create-bucket --bucket innovatech-tfstate-<your-unique-suffix> \
  --region eu-central-1 --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api put-bucket-versioning --bucket innovatech-tfstate-<your-unique-suffix> \
  --versioning-configuration Status=Enabled
```
Put that bucket name in `terraform/versions.tf` (replace `CHANGE-ME`).

## Step 2 – SSH key for Ansible
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "ansible@ansible-node"
cat ~/.ssh/id_ed25519.pub       # goes in terraform.tfvars; also ssh-copy-id to the user "ansible" on every on-prem host
```

## Step 3 – Deploy the AWS infrastructure
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars      # firewall public IP, LAN CIDR, SSH public key
export TF_VAR_soar_webhook_token=$(openssl rand -hex 24); echo $TF_VAR_soar_webhook_token   # save it: Elastic needs it
# optional, for automatic host isolation:
# export TF_VAR_kibana_api_key=...   and set kibana_url in terraform.tfvars
terraform init
terraform apply
```
Takes about 15–20 minutes. The ECS service is created now, but its tasks cannot start until the image exists (next step).

## Step 4 – Build and push the SOAR container (first time by hand)
```bash
cd ../soar
REPO=$(terraform -chdir=../terraform output -raw ecr_repository_url)
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin ${REPO%%/*}
docker build -t $REPO:latest .
docker push $REPO:latest
aws ecs update-service --cluster innovatech --service soar --force-new-deployment
aws ecs wait services-stable --cluster innovatech --services soar
```
After this the workflow `soar.yml` does this automatically on every change in `soar/`.

## Step 5 – VPN on the on-prem firewall (REQ-04)
1. AWS Console → VPC → Site-to-Site VPN connections → `onprem-to-aws` → **Download configuration** (pick your firewall vendor). Or build it by hand from `terraform output vpn_tunnel1_address` and `terraform output -raw vpn_tunnel1_psk`: IKEv2, AES-256, SHA-256, DH group 14, local `192.168.10.0/24`, remote `10.20.0.0/16`. Configure **both** tunnels.
2. Check the tunnel is **UP** and `ping <loki_prometheus_ip>` works from the Ansible node (`terraform output loki_prometheus_ip`).
3. DNS: forward `innovatech.internal` from the on-prem DNS to the VPC resolver (`10.20.0.2`), or add `loki`, `prometheus` and `soar` `.innovatech.internal` to `/etc/hosts` on the Ansible node and the on-prem hosts.

## Step 6 – Configure on-prem hosts and the monitoring servers with Ansible
```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
nano group_vars/all.yml            # logs_bucket from `terraform output logs_bucket`
nano inventory/onprem.ini          # IPs and interface of the on-prem hosts
ansible-inventory --graph
ansible all -m ping
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

## Step 7 – Self-hosted runner and GitHub secrets (REQ-10, 11, 12)
1. GitHub repo → Settings → Actions → Runners → **New self-hosted runner** (Linux x64), follow the commands on the Ansible node, label `innovatech`, then `sudo ./svc.sh install && sudo ./svc.sh start`.
2. Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ONPREM_PUBLIC_IP`, `ANSIBLE_SSH_PUBLIC_KEY`, `SOAR_WEBHOOK_TOKEN`, and optional `KIBANA_URL`, `KIBANA_API_KEY`.
3. Settings → Environments → create `production` with yourself as required reviewer (manual approval before `terraform apply`).
4. Workflows:
   - `terraform.yml`: pull request = fmt, validate, plan; merge to `main` = approval, then apply
   - `soar.yml`: change in `soar/` = build image, push to ECR, rolling deployment with automatic rollback
   - `ansible.yml`: change in `ansible/` = syntax check, dry run, run
   - `patch.yml`: every Sunday 02:00 UTC = rolling patching of the EC2 and on-prem hosts (Fargate and RDS are patched by AWS)

## Step 8 – Connect Elastic to the SOAR (REQ-08, 09)
Kibana → Stack Management → Connectors → **Webhook**: POST `http://soar.innovatech.internal:8080/webhook`, headers `X-Webhook-Token: <token>` and `Content-Type: application/json`, body:
```json
{"rule": {"name": "{{rule.name}}", "severity": "{{context.rule.severity}}"},
 "host": {"name": "{{context.alerts.0.host.name}}"},
 "agent": {"id": "{{context.alerts.0.agent.id}}"}}
```
Attach it as an action to your detection rule. High/critical alerts isolate the host through Elastic Defend; other alerts are logged and stored.

## Step 9 – Tests
| Test | How | Expected |
|---|---|---|
| VPN | `ping <loki_prometheus_ip>` from the Ansible node | replies |
| Grafana | `http://<grafana private ip>:3000` (admin/admin, change it) | Loki and Prometheus data sources are green |
| Log shipping | `logger "test-from-ws01"`, Explore → Loki: `{job="syslog"} \|= "test-from-ws01"` | line appears |
| Suricata | `curl http://testmynids.org/uid/index.html` behind the IDS, query `{job="suricata"}` | alert events |
| SOAR health | `curl http://soar.innovatech.internal:8080/health` | `ok` |
| SOAR webhook | `curl -X POST http://soar.innovatech.internal:8080/webhook -H "X-Webhook-Token: $TF_VAR_soar_webhook_token" -H "Content-Type: application/json" -d '{"rule":{"name":"test","severity":"low"},"host":{"name":"ws01"}}'` | `{"action":"notify_only",...}` |
| Wrong token | same call with a wrong token | HTTP 401, and `soar_webhook_unauthorized_total` goes up |
| **SOAR is monitored** | Grafana → Explore → Prometheus: `up{job="soar"}` and `sum(rate(soar_alerts_total[5m])) by (action)` | one `up=1` per task; alert rate per action |
| More SOAR queries | `soar_action_failures_total`, `soar_db_errors_total`, `histogram_quantile(0.95, rate(soar_webhook_duration_seconds_bucket[5m]))` | failures, DB errors, p95 latency |
| SOAR logs | CloudWatch Logs → `/ecs/soar` | one line per alert |
| Task failover | `aws ecs stop-task --cluster innovatech --task $(aws ecs list-tasks --cluster innovatech --service-name soar --query 'taskArns[0]' --output text)` and repeat the webhook call | still works; ECS starts a replacement |
| Scaling | `aws ecs update-service --cluster innovatech --service soar --desired-count 4`, check `up{job="soar"}` | 4 targets appear in Prometheus |
| Bad deploy | push a broken image | circuit breaker rolls back, service keeps running |
| RDS failover | `aws rds reboot-db-instance --db-instance-identifier innovatech-postgres --force-failover` | webhook recovers within ~2 minutes |
| Patching | `ansible-playbook patch.yml --limit ws01` | upgraded, reboot only if needed |
| Drift | change something in the console, run `terraform plan` | drift shown |

## Step 10 – Prove that the environment is really hybrid (for your report)
| # | Proof | Where / command | Expected |
|---|---|---|---|
| 1 | Tunnel is up | `aws ec2 describe-vpn-connections --query 'VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status,StatusMessage]' --output table` | at least one tunnel `UP` |
| 2 | On-prem → cloud | on-prem host: `ping -c3 <loki_prometheus_ip>` and `ip route get <loki_prometheus_ip>` | replies, route via the firewall |
| 3 | Cloud → on-prem | AWS Console → Systems Manager → Session Manager → session on `loki-prometheus`, then `ping -c3 192.168.10.21` | replies, private IP, no internet |
| 4 | Encrypted | on the firewall: `tcpdump -ni <wan-interface> host <tunnel1_address>` while pinging | only ESP or UDP 4500 |
| 5 | Private only | from a device not on the VPN: `curl -m5 http://<loki ip>:3100/ready` | times out |
| 6 | Data on-prem → cloud | `logger "hybrid-proof"` on ws01, then Loki: `{job="syslog", host="ws01"} \|= "hybrid-proof"` | line appears |
| 7 | Alerts on-prem → PaaS SOAR → RDS | send the SOAR webhook test from an on-prem host, then check the table (see below) | new row in `alerts` |
| 8 | Management cloud ← on-prem | `ansible role_monitoring_stack -m ping` | `pong` |
| 9 | Tunnel failover | take tunnel 1 down on the firewall, repeat tests 2 and 6 | still works through tunnel 2 |
| 10 | Same names both sides | `dig +short soar.innovatech.internal` on-prem and in the SSM session | same private IP |

Check the database row for test 7 from the `loki-prometheus` instance (SSM session; it may reach RDS because it is in Subnet A):
```bash
sudo apt install -y postgresql-client jq
SECRET=<db_secret_arn from terraform output>
PW=$(aws secretsmanager get-secret-value --secret-id $SECRET --region eu-central-1 --query SecretString --output text | jq -r .password)
PGPASSWORD=$PW psql "host=db.innovatech.internal dbname=soar user=soar_admin sslmode=require" \
  -c "select received_at, rule, severity, host, action from alerts order by id desc limit 5;"
```

## Design choices for your document
- **PaaS where it makes sense:** the SOAR is a new application, so it runs on Fargate (no OS patching, autoscaling, rolling deployments, self-healing). RDS, NLB, Route 53, Secrets Manager and CloudWatch are managed too.
- **Why not everything PaaS:** AWS has no managed Loki; Managed Grafana/Prometheus would change the existing Alloy/Loki monitoring and need extra PrivateLink endpoints to keep traffic inside the VPN. The monitoring stack stays on EC2 and is patched with Ansible.
- **Monitoring covers the new services:** Alloy on-prem and on the monitoring server; the SOAR exposes its own metrics; Prometheus finds every Fargate task through Cloud Map DNS; the RDS and Fargate logs are in CloudWatch.
- **Secure communication:** IPsec tunnel, private subnets, security groups limited to the on-prem CIDR, secrets in Secrets Manager, no SSH to the SOAR (there are no servers).

## Known limits
- SOAR container logs are in CloudWatch Logs, not in Loki (a Grafana CloudWatch data source can show them).
- Grafana uses local SQLite, so the ASG is set to 1 desired instance (self-healing, not scaling). Production fix: Grafana on the RDS database.
- One NAT gateway and one Loki/Prometheus instance are single points of failure (cost trade-off).
- Traffic from on-prem to Loki, Prometheus and the SOAR is plain HTTP inside the IPsec tunnel; add TLS for production.
- Access keys in GitHub secrets; better is OIDC or an IAM role on the runner.

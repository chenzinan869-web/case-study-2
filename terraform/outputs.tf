output "vpn_tunnel1_address" { value = aws_vpn_connection.onprem.tunnel1_address }
output "vpn_tunnel1_psk" {
  value     = aws_vpn_connection.onprem.tunnel1_preshared_key
  sensitive = true
}
output "vpn_tunnel2_address" { value = aws_vpn_connection.onprem.tunnel2_address }
output "vpn_tunnel2_psk" {
  value     = aws_vpn_connection.onprem.tunnel2_preshared_key
  sensitive = true
}
output "logs_bucket" { value = aws_s3_bucket.logs.id }
output "db_secret_arn" { value = aws_db_instance.postgres.master_user_secret[0].secret_arn }
output "db_endpoint" { value = aws_db_instance.postgres.address }
output "soar_webhook_url" { value = "http://soar.${var.internal_domain}:8080/webhook" }
output "loki_prometheus_ip" { value = aws_instance.loki_prometheus.private_ip }
output "ecr_repository_url" { value = aws_ecr_repository.soar.repository_url }
output "ecs_cluster" { value = aws_ecs_cluster.main.name }
output "ecs_service" { value = aws_ecs_service.soar.name }
output "soar_metrics_dns" { value = "soar.svc.${var.internal_domain}" }

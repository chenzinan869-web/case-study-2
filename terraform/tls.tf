# Internal CA and a server certificate for the SOAR endpoint
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name = "Innovatech internal CA"
  }
}

resource "tls_private_key" "soar" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
resource "tls_cert_request" "soar" {
  private_key_pem = tls_private_key.soar.private_key_pem
  dns_names       = ["soar.${var.internal_domain}"]
  subject {
    common_name = "soar.${var.internal_domain}"
  }
}
resource "tls_locally_signed_cert" "soar" {
  cert_request_pem      = tls_cert_request.soar.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "soar" {
  private_key       = tls_private_key.soar.private_key_pem
  certificate_body  = tls_locally_signed_cert.soar.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem
}

# HTTPS listener on the NLB: TLS ends here, the container keeps listening on 8080
resource "aws_lb_listener" "soar_tls" {
  load_balancer_arn = aws_lb.soar.arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate.soar.arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.soar.arn
  }
}

# The CA certificate (public part) so clients can trust the endpoint
resource "aws_s3_object" "ca" {
  bucket  = aws_s3_bucket.config.id
  key     = "grafana/ca.pem"
  content = tls_self_signed_cert.ca.cert_pem
}

output "ca_certificate_pem" {
  value = tls_self_signed_cert.ca.cert_pem
}
output "config_bucket" {
  value = aws_s3_bucket.config.id
}
output "soar_https_url" {
  value = "https://soar.${var.internal_domain}/webhook"
}
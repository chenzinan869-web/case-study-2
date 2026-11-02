# Firewall + AWS Site-to-Site VPN (REQ-04)
resource "aws_vpn_gateway" "vgw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "innovatech-vgw" }
}
resource "aws_customer_gateway" "onprem" {
  bgp_asn    = 65000
  ip_address = var.onprem_public_ip
  type       = "ipsec.1"
  tags       = { Name = "onprem-firewall" }
}
resource "aws_vpn_connection" "onprem" {
  vpn_gateway_id      = aws_vpn_gateway.vgw.id
  customer_gateway_id = aws_customer_gateway.onprem.id
  type                = "ipsec.1"
  static_routes_only  = true
  tags                = { Name = "onprem-to-aws" }
}
resource "aws_vpn_connection_route" "onprem" {
  destination_cidr_block = var.onprem_cidr
  vpn_connection_id      = aws_vpn_connection.onprem.id
}

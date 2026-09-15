# Frontend security group attached to the Anyscale Envoy Gateway NLB.
#
# The AWS Load Balancer Controller attaches this security group to the
# internet-facing NLB fronting the Envoy Gateway (ports 80/443) and manages the
# backend node security-group rules. Its ID is surfaced via the
# gateway_nlb_security_group_id output and consumed by the Helm add-on install.
resource "aws_security_group" "gateway_nlb" {
  name_prefix = "${var.eks_cluster_name}-gw-nlb-"
  description = "Anyscale Envoy Gateway NLB frontend"
  vpc_id      = module.anyscale_vpc.vpc_id

  tags = merge(var.tags, {
    Name = "${var.eks_cluster_name}-gateway-nlb"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "gateway_nlb_https" {
  security_group_id = aws_security_group.gateway_nlb.id
  description       = "HTTPS from the internet to the Anyscale Envoy Gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "gateway_nlb_http" {
  security_group_id = aws_security_group.gateway_nlb.id
  description       = "HTTP from the internet to the Anyscale Envoy Gateway"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "gateway_nlb_all" {
  security_group_id = aws_security_group.gateway_nlb.id
  description       = "Allow all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

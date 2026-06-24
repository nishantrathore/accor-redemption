variable "cluster_name" { type = string }
variable "vpc_id"        { type = string }
variable "environment"   { type = string }

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster control-plane security group"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-cluster-sg" }
}

resource "aws_security_group_rule" "cluster_egress_all" {
  security_group_id = aws_security_group.cluster.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "EKS worker nodes security group"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-nodes-sg" }
}

resource "aws_security_group_rule" "nodes_self" {
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.nodes.id
  description              = "Allow nodes to communicate with each other"
}

resource "aws_security_group_rule" "nodes_from_cluster" {
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  description              = "Allow control plane to reach kubelet/nodeports"
}

resource "aws_security_group_rule" "cluster_from_nodes" {
  security_group_id        = aws_security_group.cluster.id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
  description              = "Allow nodes to reach API server"
}

resource "aws_security_group_rule" "nodes_egress_all" {
  security_group_id = aws_security_group.nodes.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

output "cluster_sg_id" { value = aws_security_group.cluster.id }
output "nodes_sg_id"   { value = aws_security_group.nodes.id }

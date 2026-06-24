variable "cluster_name"        { type = string }
variable "kubernetes_version"  { type = string }
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "cluster_role_arn"    { type = string }
variable "node_role_arn"       { type = string }
variable "cluster_sg_id"       { type = string }
variable "additional_sg_ids"   { type = list(string) }
variable "environment"         { type = string }

variable "baseline_node_config" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    capacity_type  = string
  })
}

variable "burst_node_config" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    capacity_type  = string
  })
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [var.cluster_sg_id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  tags = { Name = var.cluster_name }
}

resource "aws_kms_key" "eks" {
  description             = "EKS secrets encryption - ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_eks_node_group" "baseline" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-baseline"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.baseline_node_config.instance_types
  capacity_type   = var.baseline_node_config.capacity_type

  scaling_config {
    min_size     = var.baseline_node_config.min_size
    desired_size = var.baseline_node_config.desired_size
    max_size     = var.baseline_node_config.max_size
  }

  update_config { max_unavailable = 1 }

  launch_template {
    id      = aws_launch_template.baseline.id
    version = aws_launch_template.baseline.latest_version
  }

  tags = {
    "k8s.io/cluster-autoscaler/${var.cluster_name}"                  = "owned"
    "k8s.io/cluster-autoscaler/enabled"                              = "true"
    "k8s.io/cluster-autoscaler/node-template/label/workload-type"    = "baseline"
  }
}

resource "aws_launch_template" "baseline" {
  name_prefix   = "${var.cluster_name}-baseline-"
  image_id      = data.aws_ami.eks_node.id
  instance_type = var.baseline_node_config.instance_types[0]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  vpc_security_group_ids = concat([var.cluster_sg_id], var.additional_sg_ids)

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-baseline-node" }
  }
}

resource "aws_eks_node_group" "burst" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-burst"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.burst_node_config.instance_types
  capacity_type   = var.burst_node_config.capacity_type

  scaling_config {
    min_size     = var.burst_node_config.min_size
    desired_size = var.burst_node_config.desired_size
    max_size     = var.burst_node_config.max_size
  }

  update_config { max_unavailable_percentage = 33 }

  launch_template {
    id      = aws_launch_template.burst.id
    version = aws_launch_template.burst.latest_version
  }

  taint {
    key    = "workload-type"
    value  = "burst"
    effect = "NO_SCHEDULE"
  }

  tags = {
    "k8s.io/cluster-autoscaler/${var.cluster_name}"                        = "owned"
    "k8s.io/cluster-autoscaler/enabled"                                    = "true"
    "k8s.io/cluster-autoscaler/node-template/taint/workload-type"          = "burst:NoSchedule"
  }
}

resource "aws_launch_template" "burst" {
  name_prefix = "${var.cluster_name}-burst-"
  image_id    = data.aws_ami.eks_node.id

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  vpc_security_group_ids = concat([var.cluster_sg_id], var.additional_sg_ids)

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-burst-node" }
  }
}

data "aws_ami" "eks_node" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.kubernetes_version}-v*"]
  }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.baseline]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
}

output "cluster_name"           { value = aws_eks_cluster.this.name }
output "cluster_endpoint"       { value = aws_eks_cluster.this.endpoint }
output "cluster_ca_certificate" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "cluster_oidc_issuer"    { value = aws_eks_cluster.this.identity[0].oidc[0].issuer }

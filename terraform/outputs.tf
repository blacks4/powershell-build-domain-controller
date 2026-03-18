output "instance_id" {
  description = "ID of the domain controller EC2 instance."
  value       = aws_instance.dc.id
}

output "instance_private_ip" {
  description = "Static private IP assigned to the domain controller."
  value       = aws_instance.dc.private_ip
}

output "elastic_ip" {
  description = "Elastic IP assigned to the domain controller."
  value       = aws_eip.dc.public_ip
}

output "engineer_rdp_cidr" {
  description = "Engineer WAN CIDR currently allowed for RDP."
  value       = local.engineer_rdp_cidr
}

output "route53_record_fqdn" {
  description = "FQDN created in Route53, if enabled."
  value       = var.create_route53_record ? aws_route53_record.dc[0].fqdn : null
}

output "certificate_file" {
  description = "Local path to the extracted LDAPS certificate."
  value       = "${path.module}/cert.pem"
}

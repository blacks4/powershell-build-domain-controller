variable "vpc_id" {
  description = "VPC ID for the domain controller instance."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the domain controller instance will be deployed."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the domain controller."
  type        = string
  default     = "m5.xlarge"
}

variable "key_pair_name" {
  description = "Existing AWS EC2 key pair name to associate with the instance."
  type        = string
}

variable "vault_ip_cidr" {
  description = "CIDR allowed to reach LDAPS on TCP/636."
  type        = string
}

variable "server_name" {
  description = "Windows hostname for the domain controller."
  type        = string
}

variable "domain_name" {
  description = "AD DNS domain name to create."
  type        = string
}

variable "netbios_name" {
  description = "NetBIOS name for the AD domain."
  type        = string
}

variable "dsrm_password" {
  description = "DSRM password for the forest creation."
  type        = string
  sensitive   = true
}

variable "ca_common_name" {
  description = "Common name for the AD CS enterprise root CA."
  type        = string
}

variable "ami_id" {
  description = "Optional AMI ID override. Leave null to use the latest Windows Server 2022 base AMI."
  type        = string
  default     = null
}

variable "windows_server_version" {
  description = "Windows Server base AMI version to use when ami_id is not set."
  type        = string
  default     = "2022"

  validation {
    condition     = contains(["2022", "2025"], var.windows_server_version)
    error_message = "windows_server_version must be either 2022 or 2025."
  }
}

variable "additional_allowed_rdp_cidr_blocks" {
  description = "Optional additional CIDR blocks allowed to RDP to the instance, beyond the auto-detected current WAN IP."
  type        = list(string)
  default     = []
}

variable "create_route53_record" {
  description = "Whether to create a Route53 A record for the domain controller."
  type        = bool
  default     = false
}

variable "route53_zone_name" {
  description = "Hosted zone name for the optional Route53 record, such as example.com."
  type        = string
  default     = null
}

variable "route53_record_name" {
  description = "Optional record name to create. Defaults to <server_name>.<domain_name> when omitted."
  type        = string
  default     = null
}

variable "route53_private_zone" {
  description = "Whether the Route53 hosted zone is private."
  type        = bool
  default     = true
}

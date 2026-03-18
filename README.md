# Active Directory + LDAPS + Vault LDAP Integration Lab

This project provides a fully automated way to:

- Promote a Windows Server to a Domain Controller
- Install and configure Active Directory Certificate Services (AD CS)
- Enable LDAPS (port 636)
- Integrate with HashiCorp Vault LDAP Secrets Engine
- Manage static LDAP credentials with password rotation

---

## 🚀 Overview

This repo supports multiple workflows:

1. Manual Script Execution
   - RDP into a Windows Server
   - Run a single PowerShell script
   - Script handles reboots automatically

2. EC2 User Data Execution
   - Paste [`userdata/dc_build.txt`](/Users/stevetractenberg/github/powershell-build-domain-controller/userdata/dc_build.txt) into EC2 User Data at launch
   - User Data writes `C:\ADSetup\dc_script.ps1` and runs it automatically
   - Same multi-reboot workflow, logging, and final shutdown behavior

3. Terraform Deployment
   - Launches the EC2 instance, security group, Elastic IP, and optional Route53 record
   - Renders the user data automatically from [`terraform/dc_build.ps1.tftpl`](/Users/stevetractenberg/github/powershell-build-domain-controller/terraform/dc_build.ps1.tftpl)
   - Waits for LDAPS to come up and writes the DC certificate to `terraform/cert.pem`

---

## 🖥️ Requirements

### AWS / Infrastructure
- EC2 instance (recommended: t3.large minimum, m5.large preferred)
- Existing EC2 key pair
- Security Group allowing:
  - RDP (3389)
  - LDAPS (636)

### OS
- Windows Server 2022 / 2025

### Tools
- PowerShell (Administrator)
- OpenSSL (for cert validation)
- Vault CLI
- Terraform

---

## ⚙️ Setup Instructions

Pick one of the following:

1. Option A: Manual Script Execution (RDP + run script)
2. Option B: EC2 User Data Execution (hands-off bootstrap)
3. Option C: Terraform Deployment

### Option A - Manual Script Execution

#### 1. Launch EC2 Instance

- Choose Windows Server AMI
- Instance type:
  - t3.large (works, slower)
  - m5.large+ (recommended)

---

#### 2. RDP into Server

- Connect as Administrator
- Copy the script to the desktop (e.g. dc_script.ps1)
- Add variable values to lines 12-16

---

#### 3. Run Script

    .\dc_script.ps1

---

#### 4. Script Behavior

| Step | Action |
|------|--------|
| 0 | Rename server (reboot) |
| 1 | Install AD DS |
| 2 | Promote to Domain Controller (reboot) |
| 3 | Install AD CS |
| 4 | Enable LDAPS |
| 5 | ** Shutdown when complete ** |

---

### Option B - EC2 User Data Execution

#### 1. Launch EC2 Instance with User Data

- Choose Windows Server AMI
- Use the same instance sizing guidance as Option A
- In **Advanced details -> User data**, paste the contents of [`userdata/dc_build.txt`](/Users/stevetractenberg/github/powershell-build-domain-controller/userdata/dc_build.txt)

#### 2. Customize Config Before Launch

- Edit the `$Config` block inside User Data before launching:
  - `ServerName`
  - `DomainName`
  - `NetBIOSName`
  - `DSRMPassword`
  - `CACommonName`

#### 3. Bootstrapping Behavior

- On first boot, User Data creates `C:\ADSetup\dc_script.ps1`
- It runs the script with `-ExecutionPolicy Bypass`
- Scheduled task continuation handles post-reboot steps until completion
- Final state is the same as manual mode: logs written and instance shuts down

---

### Option C - Terraform Deployment

#### 1. Review Terraform Inputs

- Terraform lives under [`terraform/`](/Users/stevetractenberg/github/powershell-build-domain-controller/terraform)
- Copy [`terraform/terraform.tfvars.example`](/Users/stevetractenberg/github/powershell-build-domain-controller/terraform/terraform.tfvars.example) to `terraform/terraform.tfvars`
- Edit `terraform/terraform.tfvars` with your environment-specific values
- Required inputs:
  - `vpc_id`
  - `subnet_id`
  - `instance_type`
  - `key_pair_name`
  - `vault_ip_cidr`
  - `server_name`
  - `domain_name`
  - `netbios_name`
  - `dsrm_password`
  - `ca_common_name`
- Key optional inputs:
  - `windows_server_version` (`2022` or `2025`)
  - `additional_allowed_rdp_cidr_blocks`
  - `create_route53_record`
  - `route53_zone_name`
  - `route53_record_name`
  - `route53_private_zone`
  - `ami_id`

#### 2. Terraform Behavior

- Chooses the latest Amazon Windows Server base AMI for `2022` or `2025`, unless `ami_id` is set
- Creates one EC2 instance, one security group, and one Elastic IP
- Automatically allows RDP from the public WAN IP of the machine running Terraform
- Optionally adds extra RDP CIDRs from `additional_allowed_rdp_cidr_blocks`
- Optionally creates a public or private Route53 `A` record
- Retrieves the LDAPS certificate and writes it to `terraform/cert.pem`
- Leaves the instance running after configuration completes

#### 3. Run Terraform

```bash
cd terraform
terraform init
terraform apply
```

#### 4. After Terraform Finishes

- Use the Elastic IP or Route53 name to connect to the server
- The LDAPS certificate is available at `terraform/cert.pem`
- If you want to create Vault test users and the `vault_bind` account, run [`scripts/populate_ad.ps1`](/Users/stevetractenberg/github/powershell-build-domain-controller/scripts/populate_ad.ps1) on the domain controller

---

## 👥 AD Population Script

[`scripts/populate_ad.ps1`](/Users/stevetractenberg/github/powershell-build-domain-controller/scripts/populate_ad.ps1) is a post-build helper for creating a Vault-friendly OU layout and seed accounts.

It does the following:

- Creates `OU=vault` at the domain root if it does not already exist
- Creates or updates a service account named `vault_bind` inside that OU
- Generates a new password for `vault_bind` on each run and prints it to the screen
- Grants `vault_bind` full control over descendant user objects inside `OU=vault`
- Creates or updates four base users in that OU: `sally`, `bob`, `john`, and `jane`
- Prints the distinguished names for `vault_bind` and the four base users at the end

Run it directly on the domain controller in an elevated PowerShell session:

```powershell
cd C:\path\to\repo\scripts
.\populate_ad.ps1
```

At the end, capture:

- the generated `vault_bind` password
- the `vault_bind` distinguished name for Vault `binddn`
- the distinguished names of the base users if you want to create Vault static roles against them

---

## 📄 Logging

Logs are written to:

    C:\ADSetup\setup.log

### Key Features

- Start + end timestamps
- Step timing
- Full error capture
- Stack traces on failure

If something fails, the log file is all you need.

---

## ⏱️ Expected Runtime

| Instance Type | Time |
|---------------|------|
| t3.large | ~30–40 minutes |
| m5.large | ~15–25 minutes |

Observed Terraform build times on `m5.xlarge`:

| Windows Version | Time |
|----------------|------|
| Windows Server 2022 | ~9.5 minutes |
| Windows Server 2025 | ~25.5 minutes |

---

## 🔐 LDAPS Verification

    openssl s_client -connect dc1.domain.com:636 -showcerts </dev/null

Extract cert:

    openssl s_client -showcerts -connect dc1.domain.com:636 </dev/null | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > cert.pem

---

## 🔑 Vault LDAP Configuration

    vault write ldap/config \
      schema=ad \
      binddn="CN=vault_bind,OU=vault,DC=domain,DC=com" \
      bindpass='YOUR_PASSWORD' \
      url="ldaps://dc1.domain.com" \
      credential_type=password \
      userdn="DC=domain,DC=com" \
      userattr="sAMAccountName" \
      skip_static_role_import_rotation=true \
      password_policy=password-policy1 \ # optional
      certificate=@cert.pem

---

## 👤 Static Role Example

    vault write ldap/static-role/sally \
      dn="CN=sally,OU=vault,DC=domain,DC=com" \
      rotation_period="48h"

Retrieve credentials:

    vault read ldap/static-creds/sally

---

## 🔑 Password Policy (Optional)

    vault write sys/policies/password/password-policy1 policy='
    length = 16
    rule "charset" {
      charset = "abcdefghijklmnopqrstuvwxyz"
      min-chars = 2
    }
    rule "charset" {
      charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      min-chars = 2
    }
    rule "charset" {
      charset = "0123456789"
      min-chars = 2
    }
    rule "charset" {
      charset = "!@#$%^&*"
      min-chars = 2
    }
    '

---

## 🏁 Notes

- Use DN for static roles if search config is unreliable
- Logs are your single source of truth for troubleshooting

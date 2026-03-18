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

3. Future Enhancements
   - Terraform-based deployment (instance + Route53)

---

## 🖥️ Requirements

### AWS / Infrastructure
- EC2 instance (recommended: t3.large minimum, m5.large preferred)
- Static private IP (recommended)
- Security Group allowing:
  - RDP (3389)
  - LDAPS (636)

### OS
- Windows Server 2019 / 2022 / 2025

### Tools
- PowerShell (Administrator)
- OpenSSL (for cert validation)
- Vault CLI

---

## ⚙️ Setup Instructions

Pick one of the following:

1. Option A: Manual Script Execution (RDP + run script)
2. Option B: EC2 User Data Execution (hands-off bootstrap)

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

---

## 🔐 LDAPS Verification

    openssl s_client -connect dc1.domain.com:636 -showcerts </dev/null

Extract cert:

    openssl s_client -showcerts -connect dc1.domain.com:636 </dev/null | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > cert.pem

---

## 🔑 Vault LDAP Configuration

    vault write ldap/config \
      schema=ad \
      binddn="CN=vault_bind,CN=Users,DC=domain,DC=com" \
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

    vault write ldap/static-role/sam \
      dn="CN=sam,CN=Users,DC=domain,DC=com" \
      rotation_period="48h"

Retrieve credentials:

    vault read ldap/static-creds/sam

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

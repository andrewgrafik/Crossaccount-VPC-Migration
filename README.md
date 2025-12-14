VPC Cross-Account Migration Tool
=================================

> Automated script for migrating AWS VPC infrastructure across AWS accounts with complete network topology replication.

---

🎯 Purpose
----------

This tool automates the complex process of migrating VPC infrastructure from one AWS account to another, handling:
- VPC with custom CIDR blocks
- Subnets (public and private) with automatic CIDR recalculation
- Route tables with associations
- Internet Gateways
- NAT Gateways with Elastic IPs
- VPC Endpoints (Gateway and Interface types)
- Resource tags and naming

🔄 Migration Flow
-----------------

1. Authenticate source account and select VPC
2. Authenticate target account
3. Select target VPC CIDR (10.0.0.0/16, 172.16.0.0/16, 192.168.0.0/16, or custom)
4. Analyze source VPC components
5. Create target VPC with DNS settings
6. Create Internet Gateway (if exists)
7. Create subnets with recalculated CIDRs
8. Create NAT Gateways with Elastic IPs
9. Create route tables with routes and associations
10. Create VPC endpoints

⚙️ Prerequisites
----------------

- Bash 4.0+
- AWS CLI installed and configured
- IAM credentials for both source and target accounts

🔐 Required IAM Permissions
---------------------------

Source Account User

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNatGateways",
        "ec2:DescribeVpcEndpoints",
        "ec2:DescribeSecurityGroups",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

Target Account User

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet",
        "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:AllocateAddress",
        "ec2:CreateNatGateway",
        "ec2:CreateRouteTable",
        "ec2:CreateRoute",
        "ec2:AssociateRouteTable",
        "ec2:CreateVpcEndpoint",
        "ec2:CreateTags",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

🚀 Usage
--------

Download the script:
```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/vpc-migration/main/vpc-migration.sh
chmod +x vpc-migration.sh
```

Run the script:
```bash
bash vpc-migration.sh
```

Follow the interactive prompts:
- Enter source account AWS credentials
- Select source VPC
- Enter target account AWS credentials
- Select target VPC CIDR
- Review migration summary
- Confirm migration

📝 Interactive Steps
--------------------

The script will guide you through:

1. Source Account Configuration - AWS credentials and region
2. Source VPC Selection - Choose from available VPCs
3. Target Account Configuration - AWS credentials and region
4. Target CIDR Selection - Choose from RFC 1918 private ranges or custom
5. VPC Analysis - Review components to be migrated
6. Migration Summary - Confirm details
7. Automated Migration - Creates all resources in target account

🌐 CIDR Options
---------------

The script offers three standard RFC 1918 private IP ranges:

- 10.0.0.0/16 (Class A) - 65,536 IPs
- 172.16.0.0/16 (Class B) - 65,536 IPs
- 192.168.0.0/16 (Class C) - 65,536 IPs
- Custom CIDR - Specify your own

Subnet CIDRs are automatically recalculated to match the target VPC CIDR while preserving the network structure.

⚠️ Important Notes
------------------

CIDR Recalculation
- Subnet CIDRs are automatically adjusted to fit the target VPC CIDR
- Example: Source 10.1.1.0/24 → Target 172.16.1.0/24 (if target VPC is 172.16.0.0/16)
- Preserves subnet structure and availability zone placement

NAT Gateway Costs
- NAT Gateways incur hourly charges and data transfer costs
- Each NAT Gateway receives a new Elastic IP in the target account
- Consider consolidating NAT Gateways if cost is a concern

VPC Endpoints
- Gateway endpoints (S3, DynamoDB) are free
- Interface endpoints incur hourly charges
- Endpoint policies are not migrated (uses default policies)

Security Best Practices
- Credentials are only stored temporarily in AWS CLI profiles
- Profiles are cleared at the end of the script
- Always rotate credentials after migration
- Use IAM users with minimum required permissions

Limitations
- Does not migrate: Security groups, NACLs, VPC peering, Transit Gateway attachments
- NAT Gateways require ~2 minutes to become available
- Cross-region migration supported (specify different target region)
- No downtime for source VPC (read-only operations)

🔧 Troubleshooting
------------------

Bash Version Check
```bash
bash --version
```

Upgrade Bash (macOS)
```bash
brew install bash
```

Check AWS CLI
```bash
aws --version
```

Subnet CIDR Conflicts
If subnet creation fails due to CIDR conflicts, choose a different target VPC CIDR or adjust the custom CIDR to avoid overlaps.

NAT Gateway Timeout
NAT Gateways can take 2-5 minutes to become available. The script waits 60 seconds before creating routes.

📊 Example Output
-----------------

```
╔════════════════════════════════════════════════╗
║   VPC Cross-Account Migration Tool            ║
╚════════════════════════════════════════════════╝

Step 1: Source Account Credentials
✓ Source Account: 123456789012

Step 2: Select Source VPC
✓ Selected: vpc-abc123 (10.1.0.0/16)

Step 3: Target Account Credentials
✓ Target Account: 987654321098

Step 4: Select Target VPC CIDR
✓ Target VPC CIDR: 172.16.0.0/16

Step 5: Analyzing Source VPC Components
Found:
  - Subnets: 6
  - Route Tables: 3
  - Internet Gateway: Yes (igw-xyz789)
  - NAT Gateways: 2
  - VPC Endpoints: 3

Migration Summary:
─────────────────────────────────────────────────
Source VPC: vpc-abc123 (10.1.0.0/16)
Target CIDR: 172.16.0.0/16
Source Account: 123456789012
Target Account: 987654321098
Region: us-east-1 → us-east-1
─────────────────────────────────────────────────

Starting migration...

✓ VPC created: vpc-def456
✓ Internet Gateway created: igw-uvw123
✓ Subnets created
✓ NAT Gateways created
✓ Route tables created
✓ VPC endpoints created

╔════════════════════════════════════════════════╗
║      VPC Migration Completed Successfully!    ║
╚════════════════════════════════════════════════╝

Target VPC: vpc-def456
Target CIDR: 172.16.0.0/16
Subnets: 6
Route Tables: 3
Internet Gateway: igw-uvw123
NAT Gateways: 2
VPC Endpoints: 3
```

🤝 Contributing
---------------

Contributions are welcome! Please open an issue or submit a pull request.

📄 License
----------

MIT License - See LICENSE file for details

⚠️ Disclaimer
-------------

This tool is provided as-is. Always test in a non-production environment first. Verify all resources are created correctly before migrating workloads.

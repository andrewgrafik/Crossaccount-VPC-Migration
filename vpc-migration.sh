#!/usr/bin/env bash

# VPC Cross-Account Migration Script
# Migrates VPC, subnets, route tables, gateways, and VPC endpoints to target account

set -e

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: This script requires bash 4.0 or higher"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

configure_aws_profile() {
    local profile_name="$1"
    local access_key="$2"
    local secret_key="$3"
    local region="$4"
    
    aws configure set aws_access_key_id "$access_key" --profile "$profile_name"
    aws configure set aws_secret_access_key "$secret_key" --profile "$profile_name"
    aws configure set region "$region" --profile "$profile_name"
    aws configure set output json --profile "$profile_name"
}

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   VPC Cross-Account Migration Tool            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo

# Step 1: Configure Source Account
echo -e "${BLUE}Step 1: Source Account Credentials${NC}"
while true; do
    read -p "Source AWS Access Key: " SOURCE_ACCESS_KEY
    read -s -p "Source AWS Secret Key: " SOURCE_SECRET_KEY
    echo
    read -p "Source Region [us-east-1]: " SOURCE_REGION
    SOURCE_REGION=${SOURCE_REGION:-us-east-1}
    
    configure_aws_profile "source-account" "$SOURCE_ACCESS_KEY" "$SOURCE_SECRET_KEY" "$SOURCE_REGION"
    
    if SOURCE_ACCOUNT_ID=$(aws sts get-caller-identity --profile source-account --query Account --output text 2>/dev/null); then
        echo -e "${GREEN}✓ Source Account: $SOURCE_ACCOUNT_ID${NC}"
        break
    else
        echo -e "${RED}✗ Invalid credentials. Please try again.${NC}"
        echo
    fi
done
echo

# Step 2: Select Source VPC
echo -e "${BLUE}Step 2: Select Source VPC${NC}"
echo "Scanning VPCs in source account..."

VPCS=$(aws ec2 describe-vpcs --profile source-account --region $SOURCE_REGION \
    --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text)

if [ -z "$VPCS" ]; then
    echo -e "${RED}No VPCs found in source account${NC}"
    exit 1
fi

echo
echo "Available VPCs:"
echo "─────────────────────────────────────────────────"
i=1
declare -A VPC_MAP
while IFS=$'\t' read -r vpc_id cidr name; do
    name=${name:-"(no name)"}
    echo "$i) $vpc_id - $cidr - $name"
    VPC_MAP[$i]=$vpc_id
    ((i++))
done <<< "$VPCS"

echo
read -p "Select VPC number: " VPC_NUM
SOURCE_VPC_ID=${VPC_MAP[$VPC_NUM]}

if [ -z "$SOURCE_VPC_ID" ]; then
    echo -e "${RED}Invalid selection${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Selected: $SOURCE_VPC_ID${NC}"

# Get VPC details
SOURCE_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $SOURCE_VPC_ID --profile source-account --region $SOURCE_REGION --query 'Vpcs[0].CidrBlock' --output text)
echo "Source VPC CIDR: $SOURCE_VPC_CIDR"
echo

# Step 3: Configure Target Account
echo -e "${BLUE}Step 3: Target Account Credentials${NC}"
while true; do
    read -p "Target AWS Access Key: " TARGET_ACCESS_KEY
    read -s -p "Target AWS Secret Key: " TARGET_SECRET_KEY
    echo
    read -p "Target Region [$SOURCE_REGION]: " TARGET_REGION
    TARGET_REGION=${TARGET_REGION:-$SOURCE_REGION}
    
    configure_aws_profile "target-account" "$TARGET_ACCESS_KEY" "$TARGET_SECRET_KEY" "$TARGET_REGION"
    
    if TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --profile target-account --query Account --output text 2>/dev/null); then
        echo -e "${GREEN}✓ Target Account: $TARGET_ACCOUNT_ID${NC}"
        break
    else
        echo -e "${RED}✗ Invalid credentials. Please try again.${NC}"
        echo
    fi
done
echo

# Step 4: Select Target CIDR
echo -e "${BLUE}Step 4: Select Target VPC CIDR${NC}"
echo "Recommended CIDR options (RFC 1918 private ranges):"
echo "─────────────────────────────────────────────────"
echo "1) 10.0.0.0/16    (65,536 IPs - Class A)"
echo "2) 172.16.0.0/16  (65,536 IPs - Class B)"
echo "3) 192.168.0.0/16 (65,536 IPs - Class C)"
echo "4) Custom CIDR"
echo

read -p "Select CIDR option [1]: " CIDR_OPTION
CIDR_OPTION=${CIDR_OPTION:-1}

case $CIDR_OPTION in
    1) TARGET_VPC_CIDR="10.0.0.0/16" ;;
    2) TARGET_VPC_CIDR="172.16.0.0/16" ;;
    3) TARGET_VPC_CIDR="192.168.0.0/16" ;;
    4) read -p "Enter custom CIDR: " TARGET_VPC_CIDR ;;
    *) TARGET_VPC_CIDR="10.0.0.0/16" ;;
esac

echo -e "${GREEN}✓ Target VPC CIDR: $TARGET_VPC_CIDR${NC}"
echo

# Step 5: Analyze Source VPC
echo -e "${BLUE}Step 5: Analyzing Source VPC Components${NC}"

# Subnets
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" \
    --profile source-account --region $SOURCE_REGION \
    --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' --output text)
SUBNET_COUNT=$(echo "$SUBNETS" | wc -l | xargs)

# Route Tables
ROUTE_TABLES=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" \
    --profile source-account --region $SOURCE_REGION \
    --query 'RouteTables[*].RouteTableId' --output text)
RT_COUNT=$(echo "$ROUTE_TABLES" | wc -w)

# Internet Gateway
IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$SOURCE_VPC_ID" \
    --profile source-account --region $SOURCE_REGION \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")

# NAT Gateways
NAT_GWS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$SOURCE_VPC_ID" "Name=state,Values=available" \
    --profile source-account --region $SOURCE_REGION \
    --query 'NatGateways[*].[NatGatewayId,SubnetId]' --output text)
NAT_COUNT=$(echo "$NAT_GWS" | grep -c . || echo 0)

# VPC Endpoints
VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" \
    --profile source-account --region $SOURCE_REGION \
    --query 'VpcEndpoints[*].[VpcEndpointId,ServiceName,VpcEndpointType]' --output text)
ENDPOINT_COUNT=$(echo "$VPC_ENDPOINTS" | grep -c . || echo 0)

# NACLs
NACLS=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" "Name=default,Values=false" \
    --profile source-account --region $SOURCE_REGION \
    --query 'NetworkAcls[*].NetworkAclId' --output text)
NACL_COUNT=$(echo "$NACLS" | wc -w)

# VPC Peering
PEERINGS=$(aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$SOURCE_VPC_ID" "Name=status-code,Values=active" \
    --profile source-account --region $SOURCE_REGION \
    --query 'VpcPeeringConnections[*].[VpcPeeringConnectionId,AccepterVpcInfo.VpcId,AccepterVpcInfo.OwnerId]' --output text 2>/dev/null || echo "")
PEERING_COUNT=$(echo "$PEERINGS" | grep -c . || echo 0)

# Transit Gateway Attachments
TGW_ATTACHMENTS=$(aws ec2 describe-transit-gateway-vpc-attachments \
    --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" "Name=state,Values=available" \
    --profile source-account --region $SOURCE_REGION \
    --query 'TransitGatewayVpcAttachments[*].[TransitGatewayAttachmentId,TransitGatewayId]' --output text 2>/dev/null || echo "")
TGW_COUNT=$(echo "$TGW_ATTACHMENTS" | grep -c . || echo 0)

echo "Found:"
echo "  - Subnets: $SUBNET_COUNT"
echo "  - Route Tables: $RT_COUNT"
echo "  - Internet Gateway: $([ -n "$IGW" ] && echo "Yes ($IGW)" || echo "No")"
echo "  - NAT Gateways: $NAT_COUNT"
echo "  - VPC Endpoints: $ENDPOINT_COUNT"
echo "  - NACLs: $NACL_COUNT"
echo "  - VPC Peerings: $PEERING_COUNT"
echo "  - Transit Gateway Attachments: $TGW_COUNT"
echo

# Step 6: Migration Summary
echo -e "${YELLOW}Migration Summary:${NC}"
echo "─────────────────────────────────────────────────"
echo "Source VPC: $SOURCE_VPC_ID ($SOURCE_VPC_CIDR)"
echo "Target CIDR: $TARGET_VPC_CIDR"
echo "Source Account: $SOURCE_ACCOUNT_ID"
echo "Target Account: $TARGET_ACCOUNT_ID"
echo "Region: $SOURCE_REGION → $TARGET_REGION"
echo "─────────────────────────────────────────────────"
echo
read -p "Proceed with migration? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Migration cancelled"
    exit 0
fi

echo
echo -e "${GREEN}Starting migration...${NC}"
echo

# Step 7: Create Target VPC
echo "Creating target VPC..."
TARGET_VPC_ID=$(aws ec2 create-vpc --cidr-block $TARGET_VPC_CIDR \
    --profile target-account --region $TARGET_REGION \
    --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $TARGET_VPC_ID --enable-dns-hostnames \
    --profile target-account --region $TARGET_REGION

aws ec2 modify-vpc-attribute --vpc-id $TARGET_VPC_ID --enable-dns-support \
    --profile target-account --region $TARGET_REGION

echo -e "${GREEN}✓ VPC created: $TARGET_VPC_ID${NC}"

# Tag VPC
SOURCE_VPC_NAME=$(aws ec2 describe-vpcs --vpc-ids $SOURCE_VPC_ID --profile source-account --region $SOURCE_REGION \
    --query 'Vpcs[0].Tags[?Key==`Name`].Value|[0]' --output text 2>/dev/null || echo "")
if [ -n "$SOURCE_VPC_NAME" ] && [ "$SOURCE_VPC_NAME" != "None" ]; then
    aws ec2 create-tags --resources $TARGET_VPC_ID --tags "Key=Name,Value=$SOURCE_VPC_NAME-migrated" \
        --profile target-account --region $TARGET_REGION
fi

# Step 8: Create Internet Gateway if exists
if [ -n "$IGW" ] && [ "$IGW" != "None" ]; then
    echo "Creating Internet Gateway..."
    TARGET_IGW=$(aws ec2 create-internet-gateway --profile target-account --region $TARGET_REGION \
        --query 'InternetGateway.InternetGatewayId' --output text)
    
    aws ec2 attach-internet-gateway --vpc-id $TARGET_VPC_ID --internet-gateway-id $TARGET_IGW \
        --profile target-account --region $TARGET_REGION
    
    echo -e "${GREEN}✓ Internet Gateway created: $TARGET_IGW${NC}"
fi

# Step 9: Create Subnets
echo "Creating subnets..."
declare -A SUBNET_MAP

while IFS=$'\t' read -r subnet_id cidr az public name; do
    name=${name:-"subnet"}
    
    # Calculate new CIDR based on target VPC CIDR
    SUBNET_SUFFIX=$(echo $cidr | cut -d'.' -f3-)
    TARGET_CIDR_PREFIX=$(echo $TARGET_VPC_CIDR | cut -d'.' -f1-2)
    NEW_CIDR="${TARGET_CIDR_PREFIX}.${SUBNET_SUFFIX}"
    
    TARGET_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $TARGET_VPC_ID --cidr-block $NEW_CIDR --availability-zone $az \
        --profile target-account --region $TARGET_REGION \
        --query 'Subnet.SubnetId' --output text)
    
    if [ "$public" = "True" ]; then
        aws ec2 modify-subnet-attribute --subnet-id $TARGET_SUBNET_ID --map-public-ip-on-launch \
            --profile target-account --region $TARGET_REGION
    fi
    
    aws ec2 create-tags --resources $TARGET_SUBNET_ID --tags "Key=Name,Value=$name-migrated" \
        --profile target-account --region $TARGET_REGION
    
    SUBNET_MAP[$subnet_id]=$TARGET_SUBNET_ID
    echo "  ✓ $subnet_id → $TARGET_SUBNET_ID ($NEW_CIDR)"
done <<< "$SUBNETS"

echo -e "${GREEN}✓ Subnets created${NC}"

# Step 10: Create NAT Gateways
if [ $NAT_COUNT -gt 0 ]; then
    echo "Creating NAT Gateways..."
    declare -A NAT_MAP
    
    while IFS=$'\t' read -r nat_id subnet_id; do
        TARGET_SUBNET=${SUBNET_MAP[$subnet_id]}
        
        EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --profile target-account --region $TARGET_REGION \
            --query 'AllocationId' --output text)
        
        TARGET_NAT=$(aws ec2 create-nat-gateway --subnet-id $TARGET_SUBNET --allocation-id $EIP_ALLOC \
            --profile target-account --region $TARGET_REGION \
            --query 'NatGateway.NatGatewayId' --output text)
        
        NAT_MAP[$nat_id]=$TARGET_NAT
        echo "  ✓ $nat_id → $TARGET_NAT"
    done <<< "$NAT_GWS"
    
    echo "Waiting for NAT Gateways to be available..."
    sleep 60
    echo -e "${GREEN}✓ NAT Gateways created${NC}"
fi

# Step 11: Create Route Tables
echo "Creating route tables..."
declare -A RT_MAP

for rt_id in $ROUTE_TABLES; do
    # Check if main route table
    IS_MAIN=$(aws ec2 describe-route-tables --route-table-ids $rt_id \
        --profile source-account --region $SOURCE_REGION \
        --query 'RouteTables[0].Associations[?Main==`true`]|[0].Main' --output text)
    
    if [ "$IS_MAIN" = "True" ]; then
        # Use VPC's main route table
        TARGET_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$TARGET_VPC_ID" "Name=association.main,Values=true" \
            --profile target-account --region $TARGET_REGION \
            --query 'RouteTables[0].RouteTableId' --output text)
    else
        TARGET_RT=$(aws ec2 create-route-table --vpc-id $TARGET_VPC_ID \
            --profile target-account --region $TARGET_REGION \
            --query 'RouteTable.RouteTableId' --output text)
    fi
    
    RT_MAP[$rt_id]=$TARGET_RT
    
    # Copy routes
    ROUTES=$(aws ec2 describe-route-tables --route-table-ids $rt_id \
        --profile source-account --region $SOURCE_REGION \
        --query 'RouteTables[0].Routes[?GatewayId!=`local`].[DestinationCidrBlock,GatewayId,NatGatewayId]' --output text)
    
    while IFS=$'\t' read -r dest gw nat; do
        [ -z "$dest" ] && continue
        
        if [[ "$gw" == igw-* ]]; then
            aws ec2 create-route --route-table-id $TARGET_RT --destination-cidr-block $dest --gateway-id $TARGET_IGW \
                --profile target-account --region $TARGET_REGION 2>/dev/null || true
        elif [[ "$nat" == nat-* ]]; then
            TARGET_NAT_GW=${NAT_MAP[$nat]}
            [ -n "$TARGET_NAT_GW" ] && aws ec2 create-route --route-table-id $TARGET_RT --destination-cidr-block $dest --nat-gateway-id $TARGET_NAT_GW \
                --profile target-account --region $TARGET_REGION 2>/dev/null || true
        fi
    done <<< "$ROUTES"
    
    # Copy subnet associations
    ASSOCS=$(aws ec2 describe-route-tables --route-table-ids $rt_id \
        --profile source-account --region $SOURCE_REGION \
        --query 'RouteTables[0].Associations[?SubnetId!=`null`].SubnetId' --output text)
    
    for subnet in $ASSOCS; do
        TARGET_SUBNET=${SUBNET_MAP[$subnet]}
        [ -n "$TARGET_SUBNET" ] && aws ec2 associate-route-table --route-table-id $TARGET_RT --subnet-id $TARGET_SUBNET \
            --profile target-account --region $TARGET_REGION >/dev/null 2>&1 || true
    done
    
    echo "  ✓ $rt_id → $TARGET_RT"
done

echo -e "${GREEN}✓ Route tables created${NC}"

# Step 12: Create VPC Endpoints
if [ $ENDPOINT_COUNT -gt 0 ]; then
    echo "Creating VPC endpoints..."
    
    while IFS=$'\t' read -r ep_id service_name ep_type; do
        [ -z "$service_name" ] && continue
        
        if [ "$ep_type" = "Gateway" ]; then
            RT_IDS=$(echo "${RT_MAP[@]}" | tr ' ' ',')
            aws ec2 create-vpc-endpoint --vpc-id $TARGET_VPC_ID --service-name $service_name \
                --route-table-ids ${RT_MAP[@]} \
                --profile target-account --region $TARGET_REGION >/dev/null 2>&1 || true
        else
            SUBNET_IDS=$(echo "${SUBNET_MAP[@]}" | tr ' ' ' ')
            aws ec2 create-vpc-endpoint --vpc-id $TARGET_VPC_ID --service-name $service_name \
                --vpc-endpoint-type Interface --subnet-ids ${SUBNET_MAP[@]} \
                --profile target-account --region $TARGET_REGION >/dev/null 2>&1 || true
        fi
        
        echo "  ✓ $service_name ($ep_type)"
    done <<< "$VPC_ENDPOINTS"
    
    echo -e "${GREEN}✓ VPC endpoints created${NC}"
fi

# Step 13: Create NACLs
if [ $NACL_COUNT -gt 0 ]; then
    echo "Creating Network ACLs..."
    declare -A NACL_MAP
    
    for nacl_id in $NACLS; do
        TARGET_NACL=$(aws ec2 create-network-acl --vpc-id $TARGET_VPC_ID \
            --profile target-account --region $TARGET_REGION \
            --query 'NetworkAcl.NetworkAclId' --output text)
        
        NACL_MAP[$nacl_id]=$TARGET_NACL
        
        # Copy inbound rules
        INBOUND=$(aws ec2 describe-network-acls --network-acl-ids $nacl_id \
            --profile source-account --region $SOURCE_REGION \
            --query 'NetworkAcls[0].Entries[?Egress==`false`].[RuleNumber,Protocol,RuleAction,CidrBlock,PortRange.From,PortRange.To]' --output text)
        
        while IFS=$'\t' read -r rule_num protocol action cidr from_port to_port; do
            [ -z "$rule_num" ] || [ "$rule_num" = "32767" ] && continue
            [ "$protocol" = "-1" ] && protocol="all"
            
            if [ -n "$from_port" ] && [ -n "$to_port" ]; then
                aws ec2 create-network-acl-entry --network-acl-id $TARGET_NACL --rule-number $rule_num \
                    --protocol $protocol --rule-action $action --cidr-block $cidr \
                    --port-range From=$from_port,To=$to_port \
                    --profile target-account --region $TARGET_REGION 2>/dev/null || true
            else
                aws ec2 create-network-acl-entry --network-acl-id $TARGET_NACL --rule-number $rule_num \
                    --protocol $protocol --rule-action $action --cidr-block $cidr \
                    --profile target-account --region $TARGET_REGION 2>/dev/null || true
            fi
        done <<< "$INBOUND"
        
        # Copy outbound rules
        OUTBOUND=$(aws ec2 describe-network-acls --network-acl-ids $nacl_id \
            --profile source-account --region $SOURCE_REGION \
            --query 'NetworkAcls[0].Entries[?Egress==`true`].[RuleNumber,Protocol,RuleAction,CidrBlock,PortRange.From,PortRange.To]' --output text)
        
        while IFS=$'\t' read -r rule_num protocol action cidr from_port to_port; do
            [ -z "$rule_num" ] || [ "$rule_num" = "32767" ] && continue
            [ "$protocol" = "-1" ] && protocol="all"
            
            if [ -n "$from_port" ] && [ -n "$to_port" ]; then
                aws ec2 create-network-acl-entry --network-acl-id $TARGET_NACL --rule-number $rule_num \
                    --protocol $protocol --rule-action $action --cidr-block $cidr --egress \
                    --port-range From=$from_port,To=$to_port \
                    --profile target-account --region $TARGET_REGION 2>/dev/null || true
            else
                aws ec2 create-network-acl-entry --network-acl-id $TARGET_NACL --rule-number $rule_num \
                    --protocol $protocol --rule-action $action --cidr-block $cidr --egress \
                    --profile target-account --region $TARGET_REGION 2>/dev/null || true
            fi
        done <<< "$OUTBOUND"
        
        # Associate with subnets
        NACL_SUBNETS=$(aws ec2 describe-network-acls --network-acl-ids $nacl_id \
            --profile source-account --region $SOURCE_REGION \
            --query 'NetworkAcls[0].Associations[*].SubnetId' --output text)
        
        for subnet in $NACL_SUBNETS; do
            TARGET_SUBNET=${SUBNET_MAP[$subnet]}
            [ -n "$TARGET_SUBNET" ] && aws ec2 replace-network-acl-association \
                --association-id $(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$TARGET_SUBNET" \
                    --profile target-account --region $TARGET_REGION \
                    --query 'NetworkAcls[0].Associations[?SubnetId==`'$TARGET_SUBNET'`].NetworkAclAssociationId' --output text) \
                --network-acl-id $TARGET_NACL \
                --profile target-account --region $TARGET_REGION 2>/dev/null || true
        done
        
        echo "  ✓ $nacl_id → $TARGET_NACL"
    done
    
    echo -e "${GREEN}✓ NACLs created${NC}"
fi

# Step 14: VPC Peering (informational only)
if [ $PEERING_COUNT -gt 0 ]; then
    echo -e "${YELLOW}Note: VPC Peering connections detected${NC}"
    echo "VPC peering must be manually recreated after migration:"
    while IFS=$'\t' read -r pcx_id peer_vpc peer_account; do
        [ -z "$pcx_id" ] && continue
        echo "  - $pcx_id → Peer VPC: $peer_vpc (Account: $peer_account)"
    done <<< "$PEERINGS"
    echo
fi

# Step 15: Transit Gateway (informational only)
if [ $TGW_COUNT -gt 0 ]; then
    echo -e "${YELLOW}Note: Transit Gateway attachments detected${NC}"
    echo "Transit Gateway attachments must be manually recreated:"
    while IFS=$'\t' read -r attach_id tgw_id; do
        [ -z "$attach_id" ] && continue
        echo "  - Attachment: $attach_id → TGW: $tgw_id"
    done <<< "$TGW_ATTACHMENTS"
    echo
fi

echo
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      VPC Migration Completed Successfully!    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo
echo "Target VPC: $TARGET_VPC_ID"
echo "Target CIDR: $TARGET_VPC_CIDR"
echo "Subnets: $SUBNET_COUNT"
echo "Route Tables: $RT_COUNT"
[ -n "$TARGET_IGW" ] && echo "Internet Gateway: $TARGET_IGW"
[ $NAT_COUNT -gt 0 ] && echo "NAT Gateways: $NAT_COUNT"
[ $ENDPOINT_COUNT -gt 0 ] && echo "VPC Endpoints: $ENDPOINT_COUNT"
[ $NACL_COUNT -gt 0 ] && echo "NACLs: $NACL_COUNT"
echo
echo -e "${YELLOW}IMPORTANT: Rotate the AWS credentials used in this migration${NC}"
echo

# Cleanup
aws configure --profile source-account set aws_access_key_id "" 2>/dev/null || true
aws configure --profile target-account set aws_access_key_id "" 2>/dev/null || true

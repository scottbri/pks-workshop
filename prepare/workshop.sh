#!/usr/bin/env bash

### This section for General Configuration
PROJECT_ID="$3"
GCLOUD_REGION="us-east1"
GCLOUD_ZONE="$GCLOUD_REGION-b"

### This section for GCP Prep and Configuration
MY_PKS="$2-pks"
PKS_SERVICE_ACCOUNT="$MY_PKS-service-account"
PKS_IAM_EMAIL="${PKS_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"
NETWORK="$MY_PKS-network"
NETWORK_SUBNET_INFRA="$MY_PKS-subnet-infrastructure"
NETWORK_SUBNET_RUNTIME="$MY_PKS-subnet-runtime"
NETWORK_SUBNET_SERVICES="$MY_PKS-subnet-services"

FW_RULE_ALLOW_SSH="$MY_PKS-allow-ssh"
FW_RULE_ALLOW_HTTP="$MY_PKS-allow-http"
FW_RULE_ALLOW_HTTP_8080="$MY_PKS-allow-http-8080"
FW_RULE_ALLOW_HTTPS="$MY_PKS-allow-https"
FW_RULE_ALLOW_PAS_ALL="$MY_PKS-allow-pas-all"
FW_RULE_ALLOW_CF_TCP="$MY_PKS-allow-cf-tcp"
FW_RULE_ALLOW_SSH_PROXY="$MY_PKS-allow-ssh-proxy"

INSTANCE_NAT="$MY_PKS-nat-gw"
ADDRESS_NAT="$MY_PKS-nat-ip"
ROUTE_INSTANCE_NAT="$MY_PKS-nat-route"

INSTANCE_OPSMAN="$MY_PKS-opsman"
ADDRESS_OPSMAN="$MY_PKS-om-ip"

### This section for K8s Master/Worker Configuration
ADDRESS_PKS_LB="$MY_PKS-lb"
ADDRESS_PKS_CLUSTER="$MY_PKS-cluster"

MASTER_SERVICE_ACCOUNT="$MY_PKS-master"
MASTER_IAM_EMAIL="$MASTER_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com"

WORKER_SERVICE_ACCOUNT="$MY_PKS-worker"
WORKER_IAM_EMAIL="$WORKER_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com"

FW_RULE_ALLOW_PKS_LB="$MY_PKS-api"

# Authenticate with gcloud unless already logged in
GCLOUD_CURRENT_AUTHENTICATED="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"

if [ -z $GCLOUD_CURRENT_AUTHENTICATED ]; then
  gcloud auth login
else
  echo "Currently logged in with: $GCLOUD_CURRENT_AUTHENTICATED"
  echo "To logout execute:"
  echo "gcloud auth revoke $GCLOUD_CURRENT_AUTHENTICATED"
fi

case $1 in
  setup-gcp)
    gcloud iam service-accounts create $PKS_SERVICE_ACCOUNT --display-name=$PKS_SERVICE_ACCOUNT
    gcloud iam service-accounts keys create $PKS_SERVICE_ACCOUNT.key.json --iam-account=$PKS_IAM_EMAIL

    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/iam.serviceAccountUser
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/iam.serviceAccountTokenCreator
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.instanceAdmin.v1
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.networkAdmin
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.storageAdmin
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/storage.admin

    gcloud compute networks create "$NETWORK" --subnet-mode=custom
    gcloud compute networks subnets create "$NETWORK_SUBNET_INFRA"    --network="$NETWORK" --range=192.168.101.0/26 --region="$GCLOUD_REGION"
    gcloud compute networks subnets create "$NETWORK_SUBNET_RUNTIME"  --network="$NETWORK" --range=192.168.16.0/22  --region="$GCLOUD_REGION"
    gcloud compute networks subnets create "$NETWORK_SUBNET_SERVICES" --network="$NETWORK" --range=192.168.20.0/22  --region="$GCLOUD_REGION"

    # Create NAT Instance for limiting exposed endpoints
    gcloud compute addresses create $ADDRESS_NAT --region $GCLOUD_REGION
    gcloud compute instances create "$INSTANCE_NAT" \
      --project "$PROJECT_ID" \
      --zone "$GCLOUD_ZONE" \
      --network-interface address=$ADDRESS_NAT,private-network-ip=192.168.101.2,network="$NETWORK",subnet="$NETWORK_SUBNET_INFRA" \
        --tags "nat-traverse","$MY_PKS-nat-instance" \
      --machine-type "n1-standard-4" \
        --metadata-from-file startup-script="startup-scripts/nat-gw-startup.sh" \
        --image "ubuntu-1404-trusty-v20181203" \
        --image-project "ubuntu-os-cloud" \
        --boot-disk-size "10" \
        --boot-disk-type "pd-standard" \
        --can-ip-forward

    # Create Routes
    gcloud compute routes create $ROUTE_INSTANCE_NAT --destination-range=0.0.0.0/0 --priority=800 --tags $MY_PKS --next-hop-instance=$INSTANCE_NAT --network=$NETWORK

    # Allow Internal && Director communication over SSH and CLI req'd ports
    gcloud compute firewall-rules create $FW_RULE_ALLOW_SSH       --network=$NETWORK --allow=tcp:22         --source-ranges=0.0.0.0/0   --target-tags="allow-ssh"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_HTTP      --network=$NETWORK --allow=tcp:80         --source-ranges=0.0.0.0/0   --target-tags="allow-http","router"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_HTTPS     --network=$NETWORK --allow=tcp:443        --source-ranges=0.0.0.0/0   --target-tags="allow-https","router"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_HTTP_8080 --network=$NETWORK --allow=tcp:8080       --source-ranges=0.0.0.0/0   --target-tags="router"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_PAS_ALL   --network=$NETWORK --allow=tcp,udp,icmp   --source-tags="$MY_PKS","$MY_PKS-opsman","nat-traverse" --target-tags="$MY_PKS","$MY_PKS-opsman","nat-traverse"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_CF_TCP    --network=$NETWORK --allow=tcp:1024-65535 --source-ranges=0.0.0.0/0  --target-tags="$MY_PKS-cf-tcp"
    gcloud compute firewall-rules create $FW_RULE_ALLOW_SSH_PROXY --network=$NETWORK --allow=tcp:2222       --source-ranges=0.0.0.0/0  --target-tags="$MY_PKS-ssh-proxy","diego-brain"

    # Opsman Creation
    gcloud compute addresses create $ADDRESS_OPSMAN --region $GCLOUD_REGION
    gcloud compute instances create "$INSTANCE_OPSMAN" \
      --project $PROJECT_ID --zone $GCLOUD_ZONE \
      --network-interface address="$ADDRESS_OPSMAN",private-network-ip=192.168.101.5,network=$NETWORK,subnet=$NETWORK_SUBNET_INFRA \
      --tags "$MY_PKS-opsman","allow-https","allow-ssh" \
      --machine-type "n1-standard-2" \
        --image "opsman-pcf-gcp-2-3" \
        --boot-disk-size "100" --boot-disk-type "pd-ssd" \
        --service-account=$PKS_IAM_EMAIL \
        --scopes=default,compute-rw,cloud-platform

    ;;

  setup-pks)
    gcloud compute addresses create $ADDRESS_PKS_LB --region $GCLOUD_REGION
    gcloud compute addresses create $ADDRESS_PKS_CLUSTER --region $GCLOUD_REGION

    gcloud iam service-accounts create $MASTER_SERVICE_ACCOUNT --display-name=$MASTER_SERVICE_ACCOUNT
    gcloud iam service-accounts keys create $MASTER_SERVICE_ACCOUNT.key.json --iam-account=$MASTER_IAM_EMAIL

    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.instanceAdmin.v1
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.networkAdmin
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.securityAdmin
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.storageAdmin
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.viewer
    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/iam.serviceAccountUser

    gcloud iam service-accounts create $WORKER_SERVICE_ACCOUNT --display-name=$WORKER_SERVICE_ACCOUNT
    gcloud iam service-accounts keys create $WORKER_SERVICE_ACCOUNT.key.json --iam-account=$WORKER_IAM_EMAIL

    gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$WORKER_IAM_EMAIL --role=roles/compute.viewer

    gcloud compute firewall-rules create $FW_RULE_ALLOW_PKS_LB --network=$NETWORK --priority=800 --direction=ingress --allow=tcp:8443,tcp:9021 --source-ranges=0.0.0.0/0   --target-tags="$FW_RULE_ALLOW_PKS_LB"
    ;;

  destroy-gcp)

    gcloud iam service-accounts delete $PKS_IAM_EMAIL --quiet

    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/iam.serviceAccountUser
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/iam.serviceAccountTokenCreator
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.instanceAdmin.v1
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.networkAdmin
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/compute.storageAdmin
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$PKS_IAM_EMAIL --role=roles/storage.admin

    gcloud compute routes delete $ROUTE_INSTANCE_NAT --quiet

    #Keep these around till workshop completes
    #gcloud compute addresses delete $ADDRESS_OPSMAN --quiet
    gcloud compute addresses delete $ADDRESS_NAT --quiet

    gcloud compute instances delete $INSTANCE_OPSMAN --quiet
    gcloud compute instances delete $INSTANCE_NAT --quiet

    gcloud compute firewall-rules delete $FW_RULE_ALLOW_SSH --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_HTTP --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_HTTP_8080 --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_HTTPS --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_PAS_ALL --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_CF_TCP --quiet
    gcloud compute firewall-rules delete $FW_RULE_ALLOW_SSH_PROXY --quiet

    gcloud compute networks subnets delete $NETWORK_SUBNET_RUNTIME --quiet
    gcloud compute networks subnets delete $NETWORK_SUBNET_INFRA --quiet
    gcloud compute networks subnets delete $NETWORK_SUBNET_SERVICES --quiet

    gcloud compute networks delete $NETWORK --quiet

    ;;
  destroy-pks)

    #gcloud compute addresses delete $ADDRESS_PKS_LB --quiet
    #gcloud compute addresses delete $ADDRESS_PKS_CLUSTER --quiet

    gcloud iam service-accounts delete $MASTER_IAM_EMAIL --quiet
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.instanceAdmin.v1
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.networkAdmin
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.securityAdmin
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.storageAdmin
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/compute.viewer
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$MASTER_IAM_EMAIL --role=roles/iam.serviceAccountUser

    gcloud iam service-accounts delete $WORKER_IAM_EMAIL --quiet
    gcloud projects remove-iam-policy-binding $PROJECT_ID --member=serviceAccount:$WORKER_IAM_EMAIL --role=roles/compute.viewer

    gcloud compute firewall-rules delete $FW_RULE_ALLOW_PKS_LB --quiet
    ;;
  *)
    echo "Huh"
    ;;
esac


# Created BOSH Commandline Credentials on each Opsman.  User can now:
# Activate permissioned Service Account with appropriate keys
# gcloud auth activate-service-account --key-file=$USER-pks-service-account.key.json
#
# SSH onto Opsman
# gcloud compute ssh --project $PROJECT_ID  --zone $ZONE "$USER-pks-psman"
#
# eval BOSH env_vars
# eval $(cat bosh-creds)
#
# bosh vms || bosh instances --ps || bosh --help
#
# Create users for Interal UAA
# Target PKS API
# MY_USER=userX; uaac target https://api.$MY_USER.pks.mcnichol.rocks:8443 --ca-cert $(echo $BOSH_CA_CERT)
#
# Get PKS UAA Secret from Opsman > PKS Tile >  Credentials Tab > UAA Management Admin Client  > Link to Creds  > Secret
# uaac token client get admin -s $UAA_MGMT_ADMIN_CLIENT_SECRET
#
# Grant PKS Access
# uaac user add $USERNAME --email $EMAIL -p $PASSWORD
#
# Add Scope to User
# uaac member add (pks.clusters.admin | pks.clusters.manage)
#
# ## Ueage ./this-script.sh userX
#for POST_FIX in {a..m}; do
#  THIS_USER="$1$POST_FIX-admin"
#
#  echo "Adding user: $THIS_USER with Scope: pks.clusters.admin"
#  uaac user add "$THIS_USER" --emails $THIS_USER@email.com -p password
#  uaac member add pks.clusters.admin $THIS_USER
#done
#
#for POST_FIX in {a..m}; do
#  THIS_USER="$1$POST_FIX-manage"
#
#  echo "Adding user: $THIS_USER with Scope: pks.clusters.manage"
#  uaac user add "$THIS_USER" --emails $THIS_USER@email.com -p password
#  uaac member add pks.clusters.manage $THIS_USER
#done
#
# make user2-pks firewall rule allowing 8443 for master access
# Do not give anyone credentials....they will break your heart

# Destroying Compute VMs with GCLOUD
# Remove first row showing NAME
# scorched earth
# for vm in $(gcloud compute instances list | awk '{print $1}'); do
#   gcloud compute instances delete $vm --quiet
# done

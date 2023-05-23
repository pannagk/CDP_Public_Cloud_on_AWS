#!/bin/bash

source ./setup_params.sh

bold=$(tput bold)
underline=$(tput smul)
normal=$(tput sgr0)

PWD=$(pwd)

echo "${bold}=========================================================="
echo "----------Welcome to CDP Environment Registration---------"
echo "${bold}=========================================================="
printf "\n\n"

sleep 3

##-------------------------------------------------##
##                  Create IAM Policy              ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating IAM Policy.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

aws iam create-policy --policy-name ${prefix}-policy --policy-document file://${PWD}/aws_policy.json --description "IAM Policy for CDP Credential" --tags Key=flag,Value=PSE_CLDR

iam_policy_arn=$(aws iam list-policies --query "Policies[?PolicyName == '${prefix}-policy'].Arn"  --output text)

##-------------------------------------------------##
##    Create IAM Role and attach the IAM Policy    ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating IAM Role and attaching the previously created policy to this role.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

COMMAND="aws iam create-role --role-name ${prefix}-role \
--assume-role-policy-document file://${PWD}/aws_role_trusted_entity.json"

echo $COMMAND

printf "\n\n"

aws iam create-role --role-name ${prefix}-role \
--assume-role-policy-document file://${PWD}/aws_role_trusted_entity.json

COMMAND="aws iam attach-role-policy \
--role-name ${prefix}-role \
--policy-arn ${iam_policy_arn}"

echo $COMMAND

printf "\n\n"

aws iam attach-role-policy \
--role-name ${prefix}-role \
--policy-arn ${iam_policy_arn}

iam_role_arn=$(aws iam get-role --role-name ${prefix}-role | jq -r .Role.Arn)

printf "IAM_ROLE_ARN=${iam_role_arn}"


##---------------------------------------------------
##              Configure CDP CLI
##---------------------------------------------------

printf "\n---------------------------------------------------------------------------------------------\n"
echo "Configuring CDP CLI"
echo "---------------------------------------------------------------------------------------------"
printf "${underline}${bold} Authenticating to CDP through CLI.\n\n${normal}"

cdp configure set cdp_access_key_id ${cdp_access_key_id}
cdp configure set cdp_private_key ${cdp_private_key}

##-------------------------------------------------##
##    Create CDP AWS Credential                    ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating CDP Credential.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

cdp_aws_cred=${prefix}-cdp-cred-aws
cdp_cred_description="CDP Credential for AWS - ${prefix}"

COMMAND="cdp environments create-aws-credential \
--credential-name ${cdp_aws_cred} \
--role-arn ${iam_role_arn}  \
--description ${cdp_cred_description}"

cdp environments create-aws-credential \
--credential-name ${cdp_aws_cred} \
--role-arn ${iam_role_arn}  \
--description ${cdp_cred_description}

##-------------------------------------------------##
##    Deploy Cloudformation Template               ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Deploying the Cloudformation template.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

aws cloudformation create-stack --stack-name ${prefix}-cdp-cfn-stack --template-body file://${PWD}/cloud-formation-setup.json --parameters \
ParameterKey=BackupLocationBase,ParameterValue=${prefix}-bucket/my-backups \
ParameterKey=LogsLocationBase,ParameterValue=${prefix}-bucket/my-logs \
ParameterKey=StorageLocationBase,ParameterValue=${prefix}-bucket/my-data \
ParameterKey=prefix,ParameterValue=${prefix} \
--capabilities CAPABILITY_NAMED_IAM \
--tags Key=flag,Value=PSE_CLDR

while true
sleep 10
do
    cloud_formation_stack_stasus=$(aws cloudformation describe-stacks --stack-name ${prefix}-cdp-cfn-stack | jq -r '.Stacks[0].StackStatus')
    echo "$(date): The AWS CloudFormation Stack status:- ${bold}${cloud_formation_stack_stasus}${normal}"
    printf "\n---------------------------------------------------------------------------------------------\n"
    if [ "$env_status" = "CREATE_IN_PROGRESS" ]
    then
        sleep 30
    elif [ "$cloud_formation_stack_stasus" = "CREATE_COMPLETE" ]
    then
          echo "$(date): The AWS CloudFormation Stack is created."
          break
    fi
done

##-------------------------------------------------##
##          Create SSH Key Pair                    ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating SSH Key Pair.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

keyPairName="${prefix}-keyPair"
aws ec2 create-key-pair --key-name ${keyPairName} --query 'KeyMaterial' --output text > ${keyPairName}.pem

##-------------------------------------------------##
##          Create CDP Environment                 ##
##-------------------------------------------------##

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating CDP Environment.\n${normal}"
echo "---------------------------------------------------------------------------------------------"

cdp_env_name="${prefix}-aws-env"

logs_location="s3a://${prefix}-bucket/my-logs"
LogInstanceProfile="${prefix}-log-access-instance-profile"
LogInstanceProfile_arn=$(aws iam get-instance-profile --instance-profile-name ${LogInstanceProfile} | jq -r .InstanceProfile.Arn)
backup_location="s3a://${prefix}-bucket/my-backups"

log_storage_param="storageLocationBase=${logs_location},instanceProfile=${LogInstanceProfile_arn},backupStorageLocationBase=${backup_location}"


cdp environments create-aws-environment \
--environment-name "${cdp_env_name}" \
--credential-name "${cdp_aws_cred}" \
--region "${aws_region}" \
--security-access cidr=0.0.0.0/0 \
--endpoint-access-gateway-scheme PUBLIC \
--tags key="Flag",value="PSE_CLDR" \
--enable-tunnel \
--authentication publicKeyId="${keyPairName}" \
--log-storage "${log_storage_param}" \
--network-cidr 10.10.0.0/16 \
--create-private-subnets \
--no-create-service-endpoints \
--free-ipa instanceCountByGroup=2


while true
sleep 10
do
    env_status=$(cdp environments describe-environment --environment-name ${cdp_env_name} | jq -r .environment.status)
    echo "$(date): The CDP environment status:- ${bold}${env_status}${normal}"
    printf "\n---------------------------------------------------------------------------------------------\n"
    if [ "$env_status" = "FREEIPA_CREATION_IN_PROGRESS" ]
    then
        sleep 180
    elif [ "$env_status" = "AVAILABLE" ]
    then
        freeipa_status=$(cdp environments get-freeipa-status --environment-name ${cdp_env_name} | jq -r .status)
        if [ "$freeipa_status" = "AVAILABLE" ]
        then
          echo "$(date): FREEIPA creation is complete"
          break
        else
          echo "$(date): Environment creation is in progress."
          sleep 180
        fi
    fi
done

##------------------------------------------------------------------------
##              Set Freeipa Mappings to the CDP Env once created
##------------------------------------------------------------------------

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Setting FreeIPA mappings. \n${normal}"
echo "---------------------------------------------------------------------------------------------"

datalake_admin_role=cdp-pvk-uno-cdp-env-datalake-admin-role
datalake_admin_role_arn=$(aws iam get-role --role-name ${datalake_admin_role} | jq -r .Role.Arn)

ranger_audit_role=cdp-pvk-uno-cdp-env-ranger-audit-role
ranger_audit_role_arn=$(aws iam get-role --role-name ${ranger_audit_role} | jq -r .Role.Arn)

cdp environments set-id-broker-mappings \
--environment-name "${cdp_env_name}" \
--data-access-role "${datalake_admin_role_arn}" \
--ranger-audit-role "${ranger_audit_role_arn}" \
--set-empty-mappings

##------------------------------------------------------------------------------------------------------
##              Create the CDP Data Lake
##------------------------------------------------------------------------------------------------------

echo "---------------------------------------------------------------------------------------------"
printf "${bold}Creating the CDP Data Lake. \n${normal}"
echo "---------------------------------------------------------------------------------------------"

cdp_datalake_name="${cdp_env_name}-datalake"

DataAccessInstanceProfile="${prefix}-cdp-env-data-access-instance-profile"
DataAccessInstanceProfile_arn=$(aws iam get-instance-profile --instance-profile-name ${DataAccessInstanceProfile} | jq -r .InstanceProfile.Arn)

storageBucketLocation="s3a://${prefix}-bucket/my-data"

cloud_prov_config="instanceProfile=${DataAccessInstanceProfile_arn},storageBucketLocation=${storageBucketLocation}"

cdp datalake create-aws-datalake \
--datalake-name "${cdp_datalake_name}" \
--environment-name "${cdp_env_name}" \
--cloud-provider-configuration "${cloud_prov_config}" \
--scale "LIGHT_DUTY" \
--runtime "${cdp_runtime}" \
--no-enable-ranger-raz

#!/bin/bash

user=$(whoami)

#Enter a prefix to identify the resources in aws and on cdp. By default it is set to cdp-env-<your username>
prefix=cdp-env-${user} 

# AWS Profile Details
aws_profile_name=AWS_PROFILE_NAME
aws_region=AWS_REGION_NAME

cdp_runtime="7.2.16"

#CDP 
cdp_access_key_id="Enter the CDP access key id here"
cdp_private_key="Enter the CDP private key here"

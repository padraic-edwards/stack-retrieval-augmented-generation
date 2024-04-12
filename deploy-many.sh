#!/bin/bash

set -x

# PROJECT_ID="546993cb-c1ba-49cd-a975-187a2b924c21"
# CONFIG_IDS=("b79d03d5-edfe-4cd4-8787-7d70738c6529" "853c369d-3dbd-41e4-8e79-006d2c3408b2" "736fd03d-190a-4bcd-a1a5-18334d868f20" "3d76faf5-663e-4a7a-bb1d-3c98a9fa6628" "70667b97-6bb5-425b-8e6a-47c931740604")
# STACK_CONFIG_ID="53ef9a25-3aad-4167-b548-41b19c57cad4"

function parse_params() {
  PROJECT_NAME=$1
  STACK_NAME=$2
  CONFIG_PATTERN=$3
  [[ -z "$PROJECT_NAME" && -z "$PROJECT_ID" || -z "$STACK_NAME" && -z "$STACK_CONFIG_ID"  ]] && \
    die "Usage: $(basename "${BASH_SOURCE[0]}") project_name stack_name [config_name_pattern]"
  
  if [[ -z $DRY_RUN ]]; then
    CLI_CMD=ibmcloud
  else
    CLI_CMD=echo
  fi
}

function get_config_ids() {

  if [[ -z "$PROJECT_ID" ]]; then  
    PROJECT_ID=$( ibmcloud project list --all-pages --output json | jq -r --arg project_name "$PROJECT_NAME" '.projects[]? | select(.definition.name == $project_name) | .id' )
  fi
  [[ -z "$PROJECT_ID" ]] && die "ERROR!!! Project $PROJECT_NAME is not found"

  if [[ -z "$STACK_CONFIG_ID" ]]; then
    STACK_CONFIG_ID=$(ibmcloud project configs --project-id $PROJECT_ID --output json | jq -r --arg conf "$STACK_NAME" '.configs[]? | select(.definition.name==$conf) | .id ')
  fi
  [[ -z "$STACK_CONFIG_ID" ]] && die "ERROR!!! Stack Configuration $STACK_NAME is not found in project $PROJECT_NAME"


  if [[ -z "$CONFIG_IDS" ]]; then
    CONFIG_IDS=($(ibmcloud project configs --project-id $PROJECT_ID --output json | jq -r --arg pattern "$CONFIG_PATTERN" '[.configs[]? | select((.definition.name | test($pattern)) and (.deployment_model != "stack"))] | sort_by(.definition.name)[] | .id'))
  fi
  [[ -z "$CONFIG_IDS" ]] && die "ERROR!!! No configurations found matching '$CONFIG_PATTERN' in project $PROJECT_NAME"
}

function set_stack_inputs() {
  $CLI_CMD project config-update --project-id $PROJECT_ID --id $STACK_CONFIG_ID --definition @.def.json
}

function validate_config() {
  echo "=========> Starting validation for $(ibmcloud project config --project-id $PROJECT_ID --id $CONFIG_ID --output json| jq -r '.definition.name')"
  $CLI_CMD project config-validate --project-id $PROJECT_ID --id $CONFIG_ID --output json > /tmp/validation.json
}

function wait_for_validation() {
  # Loop until the state is set to validated
  while true; do

    # Get the current state of the configuration
    STATE=$(ibmcloud project config --project-id $PROJECT_ID --id $CONFIG_ID --output json | jq -r '.state')
    if [[ ! -z $DRY_RUN ]]; then
      STATE=validated
    fi

    if [[ "$STATE" == "validated" ]]; then
      break
    fi

    if [[ "$STATE" != "validating" ]]; then
      echo "Error: Unexpected state $STATE"
      exit 1
    fi

    sleep 10 
  done
}

function approve_config() {
  $CLI_CMD project config-approve --project-id $PROJECT_ID --id $CONFIG_ID --comment "I approve through CLI"
}

function deploy_config() {
  $CLI_CMD project config-deploy --project-id $PROJECT_ID --id $CONFIG_ID
}

function wait_for_deployment() {
  while true; do
    # Retrieve the configuration
    RESPONSE=$(ibmcloud project config --project-id $PROJECT_ID --id $CONFIG_ID --output json)

    # Check the state of the configuration under approved_version
    STATE=$(echo "$RESPONSE" | jq -r ".approved_version.state")
    if [[ ! -z $DRY_RUN ]]; then
      STATE=deployed
    fi


    # If the state is "deployed" or "deploying_failed", exit the loop
    if [[ "$STATE" == "deployed" || "$STATE" == "deploying_failed" ]]; then
      break
    fi

    # If the state is not "deploying", print an error message and exit
    if [[ "$STATE" != "deploying" ]]; then
      echo "Error: Unexpected state $STATE"
      exit 1
    fi

    # Sleep for a few seconds before checking the state again
    sleep 10
  done
}

function die() 
{
  local message=$1
  local exit_code=${2-1}
  echo >&2 -e "$message"
  exit $exit_code
}

parse_params "$@"
get_config_ids
set_stack_inputs

# 6. Loop through the configuration IDs and execute the functions
for CONFIG_ID in "${CONFIG_IDS[@]}"
do
  validate_config
  wait_for_validation
  approve_config
  deploy_config
  wait_for_deployment
done
error() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
    if [[ -n "$message" ]] ; then
        >&2 echo -e "\e[41mError on or near line ${parent_lineno}: ${message}; exiting with status ${code}\e[0m"
    else
        >&2 echo -e "\e[41mError on or near line ${parent_lineno}; exiting with status ${code}\e[0m"
    fi
    echo ""

    clean_up_variables

    exit "${code}"
}

exit_if_error() {
  local exit_code=$1
  shift
  [[ $exit_code ]] &&               # do nothing if no error code passed
    ((exit_code != 0)) && {         # do nothing if error code is 0
      printf 'ERROR: %s\n' "$@" >&2 # we can use better logging here
      exit "$exit_code"             # we could also check to make sure
                                    # error code is numeric when passed
    }
}

function display_login_instructions {
    echo ""
    echo "To login the rover to azure:"
    echo " rover login [tenant_name.onmicrosoft.com or tenant_guid (optional)] [subscription_id_to_target(optional)]"
    echo ""
    echo " rover logout"
    echo ""
    echo "To display the current azure session"
    echo " rover login "
    echo ""
}

function display_instructions {
    echo ""
    echo "You can deploy a landingzone with the rover by running:"
    echo "  rover [landingzone_folder_name] [plan|apply|destroy]"
    echo ""
    echo "List of the landingzones loaded in the rover:"

    if [ -d "/tf/caf/landingzones" ]; then
        for i in $(ls -d /tf/caf/landingzones/landingzone*); do echo ${i%%/}; done
        echo ""
    fi

    if [ -d "/tf/caf/landingzones/public" ]; then
        for i in $(ls -d /tf/caf/landingzones/public/landingzones/landingzone*); do echo ${i%%/}; done
            echo ""
    fi

    # The followinf folder is used when developing the launchpads from the rover.
    if [ -d "/tf/caf/launchpads" ]; then
        for i in $(ls -d /tf/caf/launchpads/launchpad*); do echo ${i%%/}; done
            echo ""
    fi
}

function display_launchpad_instructions {
    echo ""
    echo "You can bootstrap the launchpad from the rover by running:"
    echo " launchpad [launchpad_foler_name] [plan|apply|destroy]"
    echo ""
    echo "List of the launchpads available:"
    
    if [ -d "/tf/launchpads" ]; then
        for i in $(ls -d /tf/launchpads/launchpad*); do echo ${i%%/}; done
            echo ""
    fi
}


function verify_parameters {
    echo "@calling verify_parameters"

    # Must provide an action when the tf_command is set
    if [ -z "${tf_action}" ] && [ ! -z "${tf_command}" ]; then
        display_instructions
        error ${LINENO} "landingzone and action must be set" 11
    fi
}

# The rover stores the Azure sessions in a local rover/.azure subfolder
# This function verifies the rover has an opened azure session
function verify_azure_session {
    echo "@calling verify_azure_session"

    if [ "${landingzone_name}" == "login" ]; then
        echo ""
        echo "Checking existing Azure session"
        session=$(az account show 2>/dev/null || true)

        # Cleaup any service principal session
        unset ARM_TENANT_ID
        unset ARM_SUBSCRIPTION_ID
        unset ARM_CLIENT_ID
        unset ARM_CLIENT_SECRET

        if [ ! -z "${tf_action}" ]; then
            echo "Login to azure with tenant ${tf_action}"
            ret=$(az login --tenant ${tf_action} >/dev/null >&1)
        else
            ret=$(az login >/dev/null >&1)
        fi

        # the second parameter would be the subscription id to target
        if [ "${tf_command}" != "login" ] && [ ! -z "${tf_command}" ]; then
            echo "Set default subscription to ${tf_command}"
            az account set -s ${tf_command}
        fi
        
        az account show
        exit
    fi

    if [ "${landingzone_name}" == "logout" ]; then
            echo "Closing Azure session"
            az logout || true

            # Cleaup any service principal session
            unset ARM_TENANT_ID
            unset ARM_SUBSCRIPTION_ID
            unset ARM_CLIENT_ID
            unset ARM_CLIENT_SECRET

            echo "Azure session closed"
            exit
    fi

    echo "Checking existing Azure session"
    session=$(az account show -o json 2>/dev/null || true)
    if [ "$session" == '' ]; then
            display_login_instructions
            error ${LINENO} "you must login to an Azure subscription first or 'rover login' again" 2
    fi

}

# Verifies the landingzone exist in the rover
function verify_landingzone {
    echo "@calling verifiy_landingzone"

    if [ -z "${landingzone_name}" ] && [ -z "${tf_action}" ] && [ -z "${tf_command}" ]; then
            get_remote_state_details

        if [ -z ${TF_VAR_lowerlevel_storage_account_name} ]; then 
            display_launchpad_instructions
        else
            display_instructions
        fi
    else
            echo "Verify the landingzone folder exist in the rover"
            readlink -f "${landingzone_name}"
            if [ $? -ne 0 ]; then
                    display_instructions
                    error ${LINENO} "landingzone does not exist" 12
            fi
    fi
}

function initialize_state {
    echo "@calling initialize_state"

    echo "Installing launchpad from ${landingzone_name}"
    cd ${landingzone_name}

    sudo rm -f -- ${landingzone_name}/backend.azurerm.tf
    rm -f -- "${TF_DATA_DIR}/terraform.tfstate"

    get_logged_user_object_id

    export TF_VAR_tf_name=${TF_VAR_tf_name:="$(basename $(pwd)).tfstate"}
    export TF_VAR_tf_plan=${TF_VAR_tf_plan:="$(basename $(pwd)).tfplan"}
    export STDERR_FILE="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/$(basename $(pwd))_stderr.txt"

    mkdir -p "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}"
    
    terraform init \
        -get-plugins=true \
        -upgrade=true

    RETURN_CODE=$? && echo "Line ${LINENO} - Terraform init return code ${RETURN_CODE}"
    
    case "${tf_action}" in 
        "plan")
            echo "calling plan"
            plan
            ;;
        "apply")
            echo "calling plan and apply"
            plan
            apply
            # Create sandpit workspace
            id=$(az storage account list --query "[?tags.tfstate=='level0' && tags.workspace=='level0'].{id:id}" -o json | jq -r .[0].id)
            workspace_create "sandpit"
            workspace_create ${TF_VAR_workspace}
            upload_tfstate
            ;;
        "validate")
            echo "calling validate"
            validate
            ;;
        "destroy")
            echo "Shall we call destroy here?"
            exit
            ;;
        *)
            other
            ;;
    esac

    cd "${current_path}"
}

function deploy_from_remote_state {
    echo "@calling deploy_from_remote_state"

    echo 'Connecting to the launchpad'
    cd ${landingzone_name}

    if [ -f "backend.azurerm" ]; then
        sudo cp backend.azurerm backend.azurerm.tf
    fi

    get_logged_user_object_id

    get_launchpad_coordinates

    deploy_landingzone
    
    cd "${current_path}"
}

function destroy_from_remote_state {
    echo "@calling destroy_from_remote_state"

    echo "Destroying from remote state"
    echo 'Connecting to the launchpad'
    cd ${landingzone_name}

    get_logged_user_object_id

    get_launchpad_coordinates

    # get_remote_state_details

    export TF_VAR_tf_name=${TF_VAR_tf_name:="$(basename $(pwd)).tfstate"}
    export TF_VAR_tf_plan=${TF_VAR_tf_plan:="$(basename $(pwd)).tfplan"}
    export STDERR_FILE="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/$(basename $(pwd))_stderr.txt"

    mkdir -p "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}"

    stg_name=$(az storage account show --ids ${id} -o json | jq -r .name)

    fileExists=$(az storage blob exists \
        --name ${TF_VAR_tf_name} \
        --container-name ${TF_VAR_workspace} \
        --auth-mode 'login' \
        --account-name ${stg_name} -o json | jq .exists)
    
    if [ "${fileExists}" == "true" ]; then
        if [ ${TF_VAR_workspace} == "level0" ]; then
            az storage blob download \
                --name ${TF_VAR_tf_name} \
                --file "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}" \
                --container-name ${TF_VAR_workspace} \
                --auth-mode "login" \
                --account-name ${stg_name} \
                --no-progress
            
            RETURN_CODE=$?
            if [ $RETURN_CODE != 0 ]; then
                error ${LINENO} "Error downloading the blob storage" $RETURN_CODE
            fi

            destroy
        else
            destroy "remote"
        fi
    else
        echo "landing zone already deleted"
    fi

    cd "${current_path}"
}

function upload_tfstate {
    echo "@calling upload_tfstate"

    echo "Moving launchpad to the cloud"

    stg=$(az storage account show --ids ${id} -o json)

    export storage_account_name=$(echo ${stg} | jq -r .name) && echo " - storage_account_name: ${storage_account_name}"
    export resource_group=$(echo ${stg} | jq -r .resourceGroup) && echo " - resource_group: ${resource_group}"
    export access_key=$(az storage account keys list --account-name ${storage_account_name} --resource-group ${resource_group} -o json | jq -r .[0].value) && echo " - storage_key: retrieved"

    az storage blob upload -f "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}" \
            -c ${TF_VAR_workspace} \
            -n ${TF_VAR_tf_name} \
            --auth-mode key \
            --account-key ${access_key} \
            --account-name ${storage_account_name} \
            --no-progress

    RETURN_CODE=$?
    if [ $RETURN_CODE != 0 ]; then
        error ${LINENO} "Error uploading the blob storage" $RETURN_CODE
    fi

    rm -f "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"

    display_instructions
}

function list_deployed_landingzones {
    echo "@calling list_deployed_landingzones"
    
    stg=$(az storage account show --ids ${id} -o json)

    export storage_account_name=$(echo ${stg} | jq -r .name) && echo " - storage_account_name: ${storage_account_name}"
    export resource_group=$(echo ${stg} | jq -r .resourceGroup) && echo " - resource_group: ${resource_group}"
    export access_key=$(az storage account keys list --account-name ${storage_account_name} --resource-group ${resource_group} -o json | jq -r .[0].value) && echo " - storage_key: retrieved"

    echo ""
    echo "Landing zones deployed:"
    echo ""

    az storage blob list \
            -c ${TF_VAR_workspace} \
            --account-key ${access_key} \
            --account-name ${storage_account_name} -o json |  \
    jq -r '["lnanding zone", "size in Kb", "last modification"], (.[] | [.name, .properties.contentLength / 1024, .properties.lastModified]) | @csv' | \
    awk 'BEGIN{ FS=OFS="," }NR>1{ $2=sprintf("%.2f",$2) }1'  | \
    column -t -s ','

    echo ""
}

function get_remote_state_details {
    echo "@calling get_remote_state_details"

    echo ""

        # Set the security context under the devops app
    export keyvault=$(az keyvault list --query "[?tags.tfstate=='level0' && tags.workspace=='level0']" -o json | jq -r .[0].name) && echo " - keyvault_name: ${keyvault}"
    

        # Don't get there for launchpad destroy
    if [ "${caf_action}" == "launchpad" ]; then
        echo ""
        echo "Impersonating with the launchpad service principal to deliver the landingzone"
        
        export LAUNCHPAD_NAME=$(az keyvault secret show -n launchpad-name --vault-name ${keyvault} -o json | jq -r .value) && echo " - Name: ${LAUNCHPAD_NAME}"
        
        # If the logged in user does not have access to the launchpad
        if [ "${LAUNCHPAD_NAME}" == "" ]; then
            error 326 "Not authorized to manage landingzones. User must be member of the security group to access the launchpad and deploy a landing zone" 102
        fi
    
        export ARM_CLIENT_ID=$(az keyvault secret show -n launchpad-application-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - client id: ${ARM_CLIENT_ID}"
        export TF_VAR_rover_pilot_client_id=$(az keyvault secret show -n launchpad-service-principal-client-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - rover client id: ${TF_VAR_rover_pilot_client_id}"
        export ARM_CLIENT_SECRET=$(az keyvault secret show -n launchpad-service-principal-client-secret --vault-name ${keyvault} -o json | jq -r .value)
        export ARM_TENANT_ID=$(az keyvault secret show -n launchpad-tenant-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - tenant id: ${ARM_TENANT_ID}"
        export ARM_SUBSCRIPTION_ID=$(az keyvault secret show -n launchpad-subscription-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - subscription id: ${ARM_SUBSCRIPTION_ID}"

        az login --service-principal -u ${ARM_CLIENT_ID} -p ${ARM_CLIENT_SECRET} --tenant ${ARM_TENANT_ID} 
        az account set -s ${ARM_SUBSCRIPTION_ID}
    fi  

    get_launchpad_coordinates

    echo ""

}

function login_as_launchpad {
    echo "@calling login_as_launchpad"

    export keyvault=$(az keyvault list --query "[?tags.tfstate=='level0' && tags.workspace=='level0']" -o json | jq -r .[0].name) && echo " - keyvault_name: ${keyvault}"
    
    export LAUNCHPAD_NAME=$(az keyvault secret show -n launchpad-name --vault-name ${keyvault} -o json | jq -r .value) && echo " - Name: ${LAUNCHPAD_NAME}"
        
    # If the logged in user does not have access to the launchpad
    if [ "${LAUNCHPAD_NAME}" == "" ]; then
        error 326 "Not authorized to manage landingzones. User must be member of the security group to access the launchpad and deploy a landing zone" 102
    fi

    export ARM_CLIENT_ID=$(az keyvault secret show -n launchpad-application-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - client id: ${ARM_CLIENT_ID}"
    export TF_VAR_rover_pilot_client_id=$(az keyvault secret show -n launchpad-service-principal-client-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - rover client id: ${TF_VAR_rover_pilot_client_id}"
    export ARM_CLIENT_SECRET=$(az keyvault secret show -n launchpad-service-principal-client-secret --vault-name ${keyvault} -o json | jq -r .value)
    export ARM_TENANT_ID=$(az keyvault secret show -n launchpad-tenant-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - tenant id: ${ARM_TENANT_ID}"
    export ARM_SUBSCRIPTION_ID=$(az keyvault secret show -n launchpad-subscription-id --vault-name ${keyvault} -o json | jq -r .value) && echo " - subscription id: ${ARM_SUBSCRIPTION_ID}"

    if [ "${caf_launchpad}" == "launchpad_opensource" ]; then

        echo ""
        echo "Impersonating with the launchpad service principal to deploy the landingzone"
        
        az login --service-principal -u ${ARM_CLIENT_ID} -p ${ARM_CLIENT_SECRET} --tenant ${ARM_TENANT_ID} 
        az account set -s ${ARM_SUBSCRIPTION_ID}

    fi
}

function get_launchpad_coordinates {
    echo "@calling get_launchpad_coordinates"

    echo ""
    echo "Getting launchpad coordinates:"
    
    export keyvault=$(az keyvault list --query "[?tags.tfstate=='level0' && tags.workspace=='level0']" -o json | jq -r .[0].name)
    
    stg=$(az storage account show --ids ${id} -o json)

    export TF_VAR_lowerlevel_storage_account_name=$(echo ${stg} | jq -r .name) && echo " - storage_account_name: ${TF_VAR_lowerlevel_storage_account_name}"
    export TF_VAR_lowerlevel_resource_group_name=$(echo ${stg} | jq -r .resourceGroup) && echo " - resource_group: ${TF_VAR_lowerlevel_resource_group_name}"
    export TF_VAR_lowerlevel_container_name=$(az keyvault secret show -n launchpad-blob-container --vault-name ${keyvault} -o json | jq -r .value) && echo " - container: ${TF_VAR_lowerlevel_container_name}"
    
    # If the logged in user does not have access to the launchpad
    if [ "${TF_VAR_lowerlevel_container_name}" == "" ]; then
        error 351 "Not authorized to manage landingzones. User must be member of the security group to access the launchpad and deploy a landing zone" 101
    fi

    export TF_VAR_lowerlevel_key=$(az keyvault secret show -n launchpad-blob-name --vault-name ${keyvault} -o json | jq -r .value) && echo " - tfstate file: ${TF_VAR_lowerlevel_key}"  

}

function plan {
    echo "@calling plan"

    echo "running terraform plan with ${tf_command}"
    echo " -TF_VAR_workspace: ${TF_VAR_workspace}"

    pwd
    mkdir -p "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}"
    

    rm -f $STDERR_FILE

    terraform plan ${tf_command} \
            -refresh=true \
            -state="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}" \
            -out="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_plan}" 2>$STDERR_FILE | tee ${tf_output_file}
    
    RETURN_CODE=$? && echo "Terraform plan return code: ${RETURN_CODE}"

    if [ -s $STDERR_FILE ]; then
        if [ ${tf_output_file+x} ]; then cat $STDERR_FILE >> ${tf_output_file}; fi
        echo "Terraform returned errors:"
        cat $STDERR_FILE
        RETURN_CODE=2000
    fi

    if [ $RETURN_CODE != 0 ]; then
        error ${LINENO} "Error running terraform plan" $RETURN_CODE
    fi
}

function apply {
    echo "@calling apply"

    echo 'running terraform apply'
    rm -f $STDERR_FILE

    terraform apply \
            -state="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}" \
            "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_plan}" 2>$STDERR_FILE | tee ${tf_output_file}

    RETURN_CODE=$? && echo "Terraform apply return code: ${RETURN_CODE}"

    if [ -s $STDERR_FILE ]; then
        if [ ${tf_output_file+x} ]; then cat $STDERR_FILE >> ${tf_output_file}; fi
        echo "Terraform returned errors:"
        cat $STDERR_FILE
        RETURN_CODE=2001
    fi

    if [ $RETURN_CODE != 0 ]; then
        error ${LINENO} "Error running terraform apply" $RETURN_CODE
    fi
    
}

function validate {
    echo "@calling validate"

    echo 'running terraform validate'
    terraform validate

    RETURN_CODE=$? && echo "Terraform validate return code: ${RETURN_CODE}"

    if [ -s $STDERR_FILE ]; then
        if [ ${tf_output_file+x} ]; then cat $STDERR_FILE >> ${tf_output_file}; fi
        echo "Terraform returned errors:"
        cat $STDERR_FILE
        RETURN_CODE=2002
    fi

    if [ $RETURN_CODE != 0 ]; then
        error ${LINENO} "Error running terraform validate" $RETURN_CODE
    fi

}

function destroy {
    echo "@calling destroy $1"

    cd ${landingzone_name}

    export TF_VAR_tf_name=${TF_VAR_tf_name:="$(basename $(pwd)).tfstate"}

    echo "Calling function destroy"
    echo " -TF_VAR_workspace: ${TF_VAR_workspace}"
    echo " -TF_VAR_tf_name: ${TF_VAR_tf_name}"

    get_logged_user_object_id

    rm -f "${TF_DATA_DIR}/terraform.tfstate"
    sudo rm -f ${landingzone_name}/backend.azurerm.tf

    if [ "$1" == "remote" ]; then

        if [ -e backend.azurerm ]; then
            sudo cp -f backend.azurerm backend.azurerm.tf
        fi

        export ARM_ACCESS_KEY=$(az storage account keys list --account-name ${TF_VAR_lowerlevel_storage_account_name} --resource-group ${TF_VAR_lowerlevel_resource_group_name} -o json | jq -r .[0].value)

        echo 'running terraform destroy remote'
        terraform init \
            -reconfigure=true \
            -backend=true \
            -get-plugins=true \
            -upgrade=true \
            -backend-config storage_account_name=${TF_VAR_lowerlevel_storage_account_name} \
            -backend-config container_name=${TF_VAR_workspace} \
            -backend-config access_key=${ARM_ACCESS_KEY} \
            -backend-config key=${TF_VAR_tf_name}

        RETURN_CODE=$? && echo "Line ${LINENO} - Terraform init return code ${RETURN_CODE}"

        terraform destroy ${tf_command}

        RETURN_CODE=$?
        if [ $RETURN_CODE != 0 ]; then
            error ${LINENO} "Error running terraform destroy" $RETURN_CODE
        fi

    else
        echo 'running terraform destroy with local tfstate'
        # Destroy is performed with the logged in user who last ran the launchap .. apply from the rover. Only this user has permission in the kv access policy
        if [ ${user_type} == "user" ]; then
            unset ARM_TENANT_ID
            unset ARM_SUBSCRIPTION_ID
            unset ARM_CLIENT_ID
            unset ARM_CLIENT_SECRET
        fi

        terraform init \
            -reconfigure=true \
            -get-plugins=true \
            -upgrade=true

        RETURN_CODE=$? && echo "Line ${LINENO} - Terraform init return code ${RETURN_CODE}"

        echo "using tfstate from ${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"
        mkdir -p "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}"

        terraform destroy ${tf_command} \
                -state="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"

        RETURN_CODE=$?
        if [ $RETURN_CODE != 0 ]; then
            error ${LINENO} "Error running terraform destroy" $RETURN_CODE
        fi
    fi


    echo "Removing ${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"
    rm -f "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"

    # Delete tfstate
    echo "Delete state file on storage account:"
    stg_name=$(az storage account show --ids ${id} -o json | jq -r .name) && echo " -stg_name: ${stg_name}"
    
    fileExists=$(az storage blob exists \
            --name ${TF_VAR_tf_name} \
            --container-name ${TF_VAR_workspace} \
            --auth-mode login \
            --account-name ${stg_name} -o json | jq .exists)
    
    if [ "${fileExists}" == "true" ]; then
        az storage blob delete \
            --name ${TF_VAR_tf_name} \
            --container-name ${TF_VAR_workspace} \
            --auth-mode login \
            --account-name ${stg_name}
    fi

}

function other {
    echo "@calling other"

    echo "running terraform ${tf_action} -state="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"  ${tf_command}"
    
    rm -f $STDERR_FILE

    terraform ${tf_action} \
        -state="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}" \
        ${tf_command} 2>$STDERR_FILE | tee ${tf_output_file}

    RETURN_CODE=$? && echo "Terraform ${tf_action} return code: ${RETURN_CODE}"

    if [ -s $STDERR_FILE ]; then
        if [ ${tf_output_file+x} ]; then cat $STDERR_FILE >> ${tf_output_file}; fi
        echo "Terraform returned errors:"
        cat $STDERR_FILE
        RETURN_CODE=2003
    fi

    if [ $RETURN_CODE != 0 ]; then
        error ${LINENO} "Error running terraform ${tf_action}" $RETURN_CODE
    fi
}

function deploy_landingzone {
    echo "@calling deploy_landingzone"

    echo "Deploying '${landingzone_name}'"

    cd ${landingzone_name}
    
    export TF_VAR_tf_name=${TF_VAR_tf_name:="$(basename $(pwd)).tfstate"}
    export TF_VAR_tf_plan=${TF_VAR_tf_plan:="$(basename $(pwd)).tfplan"}
    export STDERR_FILE="${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/$(basename $(pwd))_stderr.txt"

    mkdir -p "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}"

    get_remote_state_details
    export ARM_ACCESS_KEY=$(az storage account keys list --account-name ${TF_VAR_lowerlevel_storage_account_name} --resource-group ${TF_VAR_lowerlevel_resource_group_name} -o json | jq -r .[0].value)


    terraform init \
            -reconfigure \
            -backend=true \
            -get-plugins=true \
            -upgrade=true \
            -backend-config storage_account_name=${TF_VAR_lowerlevel_storage_account_name} \
            -backend-config container_name=${TF_VAR_workspace} \
            -backend-config access_key=${ARM_ACCESS_KEY} \
            -backend-config key=${TF_VAR_tf_name}
    
    RETURN_CODE=$? && echo "Terraform init return code ${RETURN_CODE}"

    case "${tf_action}" in 
        "plan")
            echo "calling plan"
            plan
            ;;
        "apply")
            echo "calling plan and apply"
            plan
            apply
            ;;
        "validate")
            echo "calling validate"
            validate
            ;;
        "destroy")
            echo "calling destroy"
            destroy
            ;;
        *)
            other
            ;;
    esac

    rm -f "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_plan}"
    rm -f "${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}/${TF_VAR_tf_name}"

    cd "${current_path}"
}


##### workspace functions

function workspace_list {
    echo "@calling workspace_list"

    echo " Calling workspace_list function"
    stg=$(az storage account show --ids ${id} -o json)

    export storage_account_name=$(echo ${stg} | jq -r .name)

    echo " Listing workspaces:"
    echo  ""
    az storage container list \
            --auth-mode "login" \
            --account-name ${storage_account_name} -o json |  \
    jq -r '["workspace", "last modification", "lease ststus"], (.[] | [.name, .properties.lastModified, .properties.leaseStatus]) | @csv' | \
    column -t -s ','

    echo ""
}

function workspace_create {
    echo "@calling workspace_create"

    echo " Calling workspace_create function"
    stg=$(az storage account show --ids ${id} -o json)

    export storage_account_name=$(echo ${stg} | jq -r .name)

    echo " Create $1 workspace"
    echo  ""
    az storage container create \
            --name $1 \
            --auth-mode login \
            --account-name ${storage_account_name}

    mkdir -p ${TF_DATA_DIR}/tfstates/${TF_VAR_workspace}

    echo ""
}


function clean_up_variables {
    echo "@calling clean_up_variables"

    echo "cleanup variables"
    unset TF_VAR_lowerlevel_storage_account_name
    unset TF_VAR_lowerlevel_resource_group_name
    unset TF_VAR_lowerlevel_key
    unset LAUNCHPAD_NAME
    unset ARM_TENANT_ID
    unset ARM_SUBSCRIPTION_ID
    unset ARM_CLIENT_ID
    unset TF_VAR_rover_pilot_application_id
    unset ARM_CLIENT_SECRET
    unset TF_VAR_logged_user_objectId
    unset keyvault
}


function get_logged_user_object_id {
    echo "@calling_get_logged_user_object_id"

    export user_type=$(az account show --query user.type -o tsv)
    if [ ${user_type} == "user" ]; then

        unset ARM_TENANT_ID
        unset ARM_SUBSCRIPTION_ID
        unset ARM_CLIENT_ID
        unset ARM_CLIENT_SECRET

        export TF_VAR_logged_user_objectId=$(az ad signed-in-user show --query objectId -o tsv)
        export logged_user_upn=$(az ad signed-in-user show --query userPrincipalName -o tsv)
        echo " - logged in objectId: ${TF_VAR_logged_user_objectId} (${logged_user_upn})"

        echo "Initializing state with user: $(az ad signed-in-user show --query userPrincipalName -o tsv)"
    else
        export clientId=$(az account show --query user.name -o tsv)

        case "${clientId}" in 
            "systemAssignedIdentity")
                echo " - logged in Azure with System Assigned Identity"
                ;;
            "userAssignedIdentity")
                echo " - logged in Azure wiht User Assigned Identity: ($(az account show | jq -r .user.assignedIdentityInfo))"
                ;;
            *)
                # When connected with a service account the name contains the objectId
                export TF_VAR_logged_user_objectId=$(az ad sp show --id ${clientId} --query objectId -o tsv)
                echo " - logged in Azure AD application:  ${TF_VAR_logged_user_objectId} ($(az ad sp show --id ${clientId} --query displayName -o tsv))"
                ;;
        esac

    fi
}
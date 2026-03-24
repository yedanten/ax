#!/bin/bash

# providers/bitlaunch-functions.sh

_bl_get_config_value() {
    jq -r ".$1" ~/.axiom/axiom.json
}

_bl_ensure_cli_installed() {
    # Check if blcli is installed
    if ! command -v blcli &> /dev/null; then
        echo -e "${BYellow}blcli is not installed. Installing now...${Color_Off}"
    else
        # Check if blcli is the correct version
        installed_version=$(blcli version 2>/dev/null | awk '{print $3}')
        if [[ "$(printf '%s\n' "$installed_version" "$BlcliVersion" | sort -V | head -n 1)" == "$BlcliVersion" ]]; then
            return 0 # Correct version is installed
        fi
        echo -e "${BYellow}blcli is outdated. Updating now...${Color_Off}"
    fi
    
    echo "Installing/updating blcli to version $BlcliVersion..."
    output=$(pip3 install bitlaunch-cli --upgrade 2>&1)
    if echo "$output" | grep -q "externally-managed-environment"; then
        echo "Detected an externally managed environment. Retrying with --break-system-packages..."
        pip3 install bitlaunch-cli --upgrade --break-system-packages
    else
        echo "blcli updated successfully."
    fi
}

bitlaunch_list_instances() {
    _bl_ensure_cli_installed
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    local OUTPUT=$(blcli server list --token "$TOKEN")
    if [[ "$OUTPUT" == "Error"* ]]; then
        echo -e "${BRed}Failed to list instances: $OUTPUT${Color_Off}"
        return 1
    fi
    echo "$OUTPUT"
}

bitlaunch_get_ip() {
    local instance_name=$1
    local instances=$(bitlaunch_list_instances)
    if [[ $? -ne 0 ]]; then return 1; fi
    echo "$instances" | jq -r --arg name "$instance_name" '.[] | select(.name == $name) | .ipv4'
}

bitlaunch_delete_instance() {
    local instance_name=$1
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    echo "Getting instance ID for '$instance_name'..."
    local instances=$(bitlaunch_list_instances)
    if [[ $? -ne 0 ]]; then return 1; fi
    local INSTANCE_ID=$(echo "$instances" | jq -r --arg name "$instance_name" '.[] | select(.name == $name) | .id')

    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "null" ]; then
        echo -e "${BRed}Could not find instance named '$instance_name'.${Color_Off}"
        return 1
    fi
    echo "Deleting instance '$instance_name' (ID: $INSTANCE_ID)..."
    local DELETE_OUTPUT=$(blcli server destroy "$INSTANCE_ID" --token "$TOKEN")

    if [[ "$DELETE_OUTPUT" != "Deleted server" ]]; then
        echo -e "${BRed}Failed to delete instance '$instance_name': $DELETE_OUTPUT${Color_Off}"
        return 1
    fi
    echo "Instance '$instance_name' deleted successfully."
}

bitlaunch_create_instance() {
    local instance_name=$1
    _bl_ensure_cli_installed

    local image=$(_bl_get_config_value "default_image")
    local region=$(_bl_get_config_value "default_region")
    local size=$(_bl_get_config_value "default_size")
    local ssh_key_name=$(_bl_get_config_value "sshkey")
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")

    if [ -z "$image" ] || [ -z "$region" ] || [ -z "$size" ] || [ -z "$ssh_key_name" ]; then
        echo -e "${BRed}Error: Missing required configuration (image, region, size, or sshkey). Please run 'axiom-account-setup' first.${Color_Off}"
        return 1
    fi

    local ssh_key_path="$HOME/.ssh/${ssh_key_name}.pub"
    if [ ! -f "$ssh_key_path" ]; then
        echo -e "${BRed}Error: SSH public key not found at '$ssh_key_path'.${Color_Off}"
        return 1
    fi
    local ssh_key_content=$(cat "$ssh_key_path")

    echo "Creating instance with the following parameters:"
    echo "  - Hostname: $instance_name"
    echo "  - Image: $image"
    echo "  - Size: $size"
    echo "  - Region: $region"
    echo "  - SSH Key: $ssh_key_name"

    echo "Creating instance, please wait..."
    CREATE_OUTPUT=$(blcli server create \
        --host "bitlaunch" \
        --name "$instance_name" \
        --region "$region" \
        --size "$size" \
        --image "$image" \
        --sshkey "$ssh_key_content" \
        --token "$TOKEN")

    if [[ "$CREATE_OUTPUT" == "Error"* ]]; then
        echo -e "${BRed}Failed to create instance: $CREATE_OUTPUT${Color_Off}"
        return 1
    fi

    if ! echo "$CREATE_OUTPUT" | jq . > /dev/null 2>&1; then
        echo -e "${BRed}Failed to create instance, unexpected output: $CREATE_OUTPUT${Color_Off}"
        return 1
    fi

    IP_ADDRESS=$(echo "$CREATE_OUTPUT" | jq -r '.ipv4')
    local server_id=$(echo "$CREATE_OUTPUT" | jq -r '.id')
    
    if [ -z "$IP_ADDRESS" ] || [ "$IP_ADDRESS" == "null" ]; then
        echo "Instance is creating (ID: $server_id), waiting for IP address..."
        local wait_seconds=180
        local interval=10
        while [ $wait_seconds -gt 0 ]; do
            local server_info=$(blcli server get "$server_id" --token "$TOKEN")
             if [[ "$server_info" == "Error"* ]]; then
                echo -e "\n${BRed}Failed to get instance status: $server_info${Color_Off}"
                break
            fi
            IP_ADDRESS=$(echo "$server_info" | jq -r '.ipv4')
            local server_status=$(echo "$server_info" | jq -r '.status')
            if [ -n "$IP_ADDRESS" ] && [ "$IP_ADDRESS" != "null" ]; then
                echo "Successfully obtained IP address: $IP_ADDRESS"
                break
            fi
            echo -n "($server_status)."
            sleep $interval
            wait_seconds=$((wait_seconds - interval))
        done
    fi
    
    if [ -z "$IP_ADDRESS" ] || [ "$IP_ADDRESS" == "null" ]; then
        echo -e "\n${BRed}Error: Failed to get instance IP address within the timeout period.${Color_Off}"
        return 1
    fi
    
    echo -e "${BGreen}Instance '$instance_name' created successfully! IP: $IP_ADDRESS${Color_Off}"
    echo "Waiting for SSH service to be ready (90 seconds)..."
    sleep 90

    echo "Starting provisioning..."
    PROVISIONERS_PATH="$HOME/.axiom/images/pkr.hcl/provisioners"
    REMOTE_PATH="/tmp/provisioners"

    ssh-keyscan -H "$IP_ADDRESS" >> ~/.ssh/known_hosts 2>/dev/null
    
    echo "Uploading provisioner scripts to $IP_ADDRESS..."
    scp -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=30 -r "$PROVISIONERS_PATH" "root@$IP_ADDRESS:$REMOTE_PATH"

    if [ $? -ne 0 ]; then
        echo -e "${BRed}Error: Failed to upload provisioner scripts using SSH key. Please ensure your public key is added to your BitLaunch account and the server is reachable.${Color_Off}"
        return 1
    fi

    echo "Executing provisioner scripts remotely..."
    ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=no "root@$IP_ADDRESS" "bash -c '
        cd $REMOTE_PATH && chmod +x *.sh
        ./00-axiom-dependencies.sh && ./01-golang.sh && ./02-tools.sh && ./03-recon-profiles.sh && ./04-wordlists.sh && ./99-cleanup.sh
        echo \"Provisioning complete!\"
    '"

    if [ $? -eq 0 ]; then
        echo -e "${BGreen}Instance '$instance_name' provisioned successfully!${Color_Off}"
    else
        echo -e "${BRed}Instance '$instance_name' provisioning failed.${Color_Off}"
    fi
}

bitlaunch_get_image_id() {
    echo "$1"
}

bitlaunch_instances() {
    bitlaunch_list_instances
}

bitlaunch_query_instances() {
    all_instances="$(bitlaunch_instances)"
    if [[ $? -ne 0 ]]; then return 1; fi
    selected=""

    if ! echo "$all_instances" | jq -e '. | type == "array"' > /dev/null 2>&1; then
        return 1
    fi

    for var in "$@"; do
        if [[ "$var" == "\\*" ]]; then
            var="*"
        fi

        if [[ "$var" == *"*"* ]]; then
            var=$(echo "$var" | sed 's/\*/.*/g')
            matches=$(echo "$all_instances" | jq -r '.[].name' | grep -E "^${var}$")
        else
            matches=$(echo "$all_instances" | jq -r '.[].name' | grep -w -E "^${var}$")
        fi

        if [[ -n "$matches" ]]; then
            selected="$selected $matches"
        fi
    done

    if [[ -z "$selected" ]]; then
        return 1
    fi

    selected=$(echo "$selected" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo -n "${selected}" | xargs
}

bitlaunch_instance_ip() {
    local instance_name=$1
    bitlaunch_instances | jq -r --arg name "$instance_name" '.[] | select(.name == $name) | .ipv4'
}

bitlaunch_select_region() {
    echo "select_region not yet implemented for BitLaunch. Please set 'default_region' in your account profile."
}

bitlaunch_list_regions() {
    _bl_ensure_cli_installed
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    local OUTPUT=$(blcli create-options bitlaunch --token "$TOKEN")
    if [[ "$OUTPUT" == "Error"* ]]; then
        echo -e "${BRed}Failed to list regions: $OUTPUT${Color_Off}"
        return 1
    fi
    echo "$OUTPUT" | jq -r '.region[] | .name + " (" + .subregions[].slug + ")"'
}

bitlaunch_list_images() {
    _bl_ensure_cli_installed
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    local OUTPUT=$(blcli create-options bitlaunch --token "$TOKEN")
    if [[ "$OUTPUT" == "Error"* ]]; then
        echo -e "${BRed}Failed to list images: $OUTPUT${Color_Off}"
        return 1
    fi
    echo "$OUTPUT" | jq -r '.image[] .versions[] | "\(.id)\t\(.description)"'
}

bitlaunch_list_sizes() {
    _bl_ensure_cli_installed
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    local OUTPUT=$(blcli create-options bitlaunch --token "$TOKEN")
     if [[ "$OUTPUT" == "Error"* ]]; then
        echo -e "${BRed}Failed to list sizes: $OUTPUT${Color_Off}"
        return 1
    fi
    echo "$OUTPUT" | jq -r '.size[] | "\(.id)\t\(.slug) | \(.cpuCount) CPU | \(.memoryMB)MB RAM | \(.diskGB)GB SSD"'
}

bitlaunch_poweron() {
    local instance_name=$1
    local TOKEN=$(_bl_get_config_value "bitlaunch_key")
    echo "Getting instance ID for '$instance_name'..."
    local instances=$(bitlaunch_list_instances)
    if [[ $? -ne 0 ]]; then return 1; fi
    local INSTANCE_ID=$(echo "$instances" | jq -r --arg name "$instance_name" '.[] | select(.name == $name) | .id')

    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "null" ]; then
        echo -e "${BRed}Could not find instance named '$instance_name'.${Color_Off}"
        return 1
    fi
    echo "Rebooting instance '$instance_name' (ID: $INSTANCE_ID)..."
    local REBOOT_OUTPUT=$(blcli server restart "$INSTANCE_ID" --token "$TOKEN")
    
    if [[ "$REBOOT_OUTPUT" != "Restarted server" ]]; then
        echo -e "${BRed}Failed to reboot instance '$instance_name': $REBOOT_OUTPUT${Color_Off}"
        return 1
    fi
    echo "Instance '$instance_name' rebooted successfully."
}

bitlaunch_poweroff() {
    echo "Power-off is not supported by BitLaunch. Use 'axiom-rm $1' to delete the instance instead."
}

bitlaunch_snapshot() {
    echo "Snapshots are not supported by BitLaunch."
}
